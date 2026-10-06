import Foundation
import CommonCrypto
import Security

/// The reasons a password cannot be stored or hashed.
public enum PasswordError: Error, LocalizedError, Equatable {
    case tooShort(minimum: Int)
    case whitespaceOnly
    case randomFailed
    case derivationFailed

    /// The sentence shown to the user for this problem.
    public var errorDescription: String? {
        switch self {
        case .tooShort(let minimum): return "The password must be at least \(minimum) characters long."
        case .whitespaceOnly: return "The password can't be only spaces."
        case .randomFailed: return "The system could not produce secure random bytes for the password."
        case .derivationFailed: return "The password could not be hashed."
        }
    }
}

/// Creates and checks the stored password fingerprint (PBKDF2 with SHA-256 and a random salt).
public enum PasswordHasher {
    /// The shortest password that validateNew accepts.
    public static let minimumLength = 6
    /// The only algorithm name this hasher writes or accepts.
    public static let algorithmName = "pbkdf2-sha256"
    private static let saltLength = 16
    private static let hashLength = 32

    /// Runs PBKDF2-HMAC-SHA256 over the password's UTF-8 bytes and returns the requested number of output bytes, or nil when the derivation fails.
    private static func derive(password: String, salt: [UInt8], iterations: Int, length: Int) -> [UInt8]? {
        guard iterations > 0, iterations <= Int(UInt32.max), !salt.isEmpty, length > 0 else { return nil }
        var derived = [UInt8](repeating: 0, count: length)
        // withCString always gives a valid pointer, even for an empty password, which a plain empty array would not.
        let status = password.withCString { passwordPointer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, password.utf8.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count
            )
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    /// Builds a new PasswordHash with a fresh random 16-byte salt and a 32-byte derived key.
    public static func make(password: String, iterations: Int = 210_000) throws -> PasswordHash {
        var salt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw PasswordError.randomFailed }
        guard let derived = derive(password: password, salt: salt, iterations: iterations, length: hashLength) else { throw PasswordError.derivationFailed }
        return PasswordHash(algorithm: algorithmName, iterations: iterations, salt: Data(salt).base64EncodedString(), hash: Data(derived).base64EncodedString())
    }

    /// Checks a password against a stored hash; returns false for a wrong password, an unknown algorithm, bad Base64 or unusable stored values.
    public static func verify(password: String, against stored: PasswordHash) -> Bool {
        guard stored.algorithm == algorithmName else { return false }
        guard let salt = Data(base64Encoded: stored.salt), let expected = Data(base64Encoded: stored.hash) else { return false }
        guard !salt.isEmpty, !expected.isEmpty else { return false }
        // Derive exactly as many bytes as were stored, so the comparison covers the whole stored hash.
        guard let derived = derive(password: password, salt: [UInt8](salt), iterations: stored.iterations, length: expected.count) else { return false }
        return constantTimeEqual(derived, [UInt8](expected))
    }

    /// Compares two byte lists in a way that takes the same time wherever they differ, so timing does not reveal how many leading bytes matched.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// Throws when a new password is shorter than the minimum or is only whitespace. The length rule runs first, so an empty password reports tooShort.
    public static func validateNew(_ password: String) throws {
        if password.count < minimumLength { throw PasswordError.tooShort(minimum: minimumLength) }
        if password.allSatisfy({ $0.isWhitespace }) { throw PasswordError.whitespaceOnly }
    }
}

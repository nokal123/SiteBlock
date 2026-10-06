import CommonCrypto
import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § PasswordHasher and 01-overview-and-data.md § PasswordHash.
// The known-answer hashes below were computed with Python's hashlib.pbkdf2_hmac('sha256', ...) (an implementation
// independent of SiteBlock); the first three are the widely published PBKDF2-HMAC-SHA256 vectors for "password"/"salt".

private let testIterations = 1000

// Derives 32 bytes with PBKDF2-HMAC-SHA256 straight from CommonCrypto, with the parameters the design states.
private func referencePBKDF2(password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
    let passwordBytes = Array(password.utf8).map { Int8(bitPattern: $0) }
    var derived = [UInt8](repeating: 0, count: 32)
    let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
    precondition(status == 0, "CommonCrypto failed in the test helper")
    return derived
}

private func makeHash(_ password: String, iterations: Int = testIterations) throws -> PasswordHash {
    try PasswordHasher.make(password: password, iterations: iterations)
}

// Returns the error validateNew throws, or nil when the password is accepted.
private func weakness(_ password: String) -> PasswordError? {
    do { try PasswordHasher.validateNew(password); return nil } catch { return error as? PasswordError }
}

// A stored hash with the same algorithm, salt and iterations as `hash` but different hash bytes.
private func replacingHashBytes(_ hash: PasswordHash, with bytes: [UInt8]) -> PasswordHash {
    PasswordHash(algorithm: hash.algorithm, iterations: hash.iterations, salt: hash.salt, hash: Data(bytes).base64EncodedString())
}

// A published or independently computed hash: (password, salt in Base64, iterations, derived key in Base64).
private let knownAnswers: [(String, String, Int, String)] = [
    ("password", "c2FsdA==", 1, "Eg+2z/z4syxD5yJSVsT4N6hlSMkszDVICAWYfLcL4Xs="),
    ("password", "c2FsdA==", 2, "rk0Mla9rRtMtCt/5KPBt0CowP47zwlHf1uLYWpVHTEM="),
    ("password", "c2FsdA==", 4096, "xeR41ZKIyEGqUw22hFxMjZYok6ABzk4RpJY4c6qYE0o="),
    ("p\u{E4}ssw\u{F6}rd\u{2713}", "AAECAwQFBgcICQoLDA0ODw==", 1000, "loUSDTN87zbVJjmpX40Mrxyb0C5l9E+OnEyZHUCeup8="),
    ("  padded  ", "EBESExQVFhcYGRobHB0eHw==", 1000, "FGbeZX0YD+IVbwySH26CjDLTzcj4sbtH2ZOKogvaGrk="),
    ("abc\u{0}defg", "MDEyMzQ1Njc4OWFiY2RlZg==", 1000, "axzncnEcLV6F66QGZMbXOX+tGzxNcHqXbVReF1B55O8="),
]

@Suite struct PasswordHasherTests {
    // MARK: make

    @Test func makeRecordsTheAlgorithmTheIterationsASixteenByteSaltAndAThirtyTwoByteHash() throws {
        let hash = try makeHash("hunter22")
        #expect(hash.algorithm == "pbkdf2-sha256")
        #expect(hash.iterations == testIterations)
        #expect(Data(base64Encoded: hash.salt)?.count == 16)
        #expect(Data(base64Encoded: hash.hash)?.count == 32)
    }

    // 01-overview-and-data.md § PasswordHash: iterations is 210000 in production. (Two real-strength derivations, about 0.2 s.)
    @Test func makeDefaultsToTwoHundredTenThousandIterations() throws {
        let hash = try PasswordHasher.make(password: "hunter22")
        #expect(hash.iterations == 210_000)
        #expect(PasswordHasher.verify(password: "hunter22", against: hash))
        #expect(!PasswordHasher.verify(password: "hunter23", against: hash))
    }

    @Test func makeHonorsTheIterationCountItIsGiven() throws {
        for iterations in [1, 2, 999, 1000, 4097] { #expect(try makeHash("hunter22", iterations: iterations).iterations == iterations) }
    }

    // The stored bytes must be the real PBKDF2-HMAC-SHA256 of the UTF-8 password with the stored salt and iterations.
    @Test(arguments: ["hunter22", "p\u{E4}ssw\u{F6}rd\u{2713}", "  padded  ", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}", "e\u{301}xxxx", "abc\u{0}defg", String(repeating: "x", count: 5000)])
    func makeStoresTheRealPBKDF2OfTheUTF8PasswordAndTheStoredSalt(password: String) throws {
        let hash = try makeHash(password)
        let salt = [UInt8](try #require(Data(base64Encoded: hash.salt)))
        let stored = [UInt8](try #require(Data(base64Encoded: hash.hash)))
        #expect(stored == referencePBKDF2(password: password, salt: salt, iterations: testIterations))
    }

    @Test func makeGivesDifferentSaltsAndHashesForTheSamePassword() throws {
        let first = try makeHash("hunter22")
        let second = try makeHash("hunter22")
        #expect(first.salt != second.salt)
        #expect(first.hash != second.hash)
        #expect(PasswordHasher.verify(password: "hunter22", against: first))
        #expect(PasswordHasher.verify(password: "hunter22", against: second))
    }

    @Test func makeSaltsAreRandomAcrossManyCalls() throws {
        var salts = Set<String>()
        for _ in 0..<40 { salts.insert(try makeHash("hunter22", iterations: 1).salt) }
        #expect(salts.count == 40)
        #expect(!salts.contains(Data(repeating: 0, count: 16).base64EncodedString()))
    }

    // MARK: verify

    @Test func verifyAcceptsTheRightPasswordAndRejectsWrongOnes() throws {
        let hash = try makeHash("hunter22")
        #expect(PasswordHasher.verify(password: "hunter22", against: hash))
        for wrong in ["hunter23", "Hunter22", "HUNTER22", "hunter2", "hunter222", "hunter22 ", " hunter22", "", "hunter", "22hunter", "hunter\u{0}22"] {
            #expect(!PasswordHasher.verify(password: wrong, against: hash), "accepted \(wrong.debugDescription)")
        }
    }

    @Test(arguments: knownAnswers)
    func verifyMatchesKnownAnswerVectors(password: String, salt: String, iterations: Int, hash: String) {
        let stored = PasswordHash(algorithm: "pbkdf2-sha256", iterations: iterations, salt: salt, hash: hash)
        #expect(PasswordHasher.verify(password: password, against: stored))
        #expect(!PasswordHasher.verify(password: password + "x", against: stored))
        let moreIterations = PasswordHash(algorithm: "pbkdf2-sha256", iterations: iterations + 1, salt: salt, hash: hash)
        #expect(!PasswordHasher.verify(password: password, against: moreIterations))
    }

    // A PRF mix-up (SHA-1 or SHA-512 instead of SHA-256) or a wrong key length would still pass a make-then-verify round
    // trip, so this fixes the answer from outside: the published vector for "password"/"salt"/1 iteration.
    @Test func verifyUsesHmacSha256NotAnotherHashFunction() {
        let stored = PasswordHash(algorithm: "pbkdf2-sha256", iterations: 1, salt: "c2FsdA==", hash: "Eg+2z/z4syxD5yJSVsT4N6hlSMkszDVICAWYfLcL4Xs=")
        #expect(Data(base64Encoded: stored.hash)?.map { String(format: "%02x", $0) }.joined() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(PasswordHasher.verify(password: "password", against: stored))
    }

    // MARK: unicode, spaces, and byte handling

    @Test(arguments: ["p\u{E4}ssw\u{F6}rd\u{2713}", "\u{43F}\u{430}\u{440}\u{43E}\u{43B}\u{44C}\u{1F511}123", "\u{5BC6}\u{7801}\u{5BC6}\u{7801}\u{5BC6}\u{7801}", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}", "a\u{200B}b\u{200B}c\u{200B}d", "\u{202E}drowssap"])
    func verifyRoundTripsUnicodePasswords(password: String) throws {
        let hash = try makeHash(password)
        #expect(PasswordHasher.verify(password: password, against: hash))
        #expect(!PasswordHasher.verify(password: password + "x", against: hash))
    }

    @Test func verifyKeepsLeadingAndTrailingSpacesAsPartOfThePassword() throws {
        let padded = try makeHash(" secret ")
        #expect(PasswordHasher.verify(password: " secret ", against: padded))
        for other in ["secret", " secret", "secret ", "  secret  "] { #expect(!PasswordHasher.verify(password: other, against: padded), "accepted \(other.debugDescription)") }
        let bare = try makeHash("secret")
        #expect(!PasswordHasher.verify(password: " secret ", against: bare))
        #expect(!PasswordHasher.verify(password: "secret ", against: bare))
    }

    // The design: "hashed as their UTF-8 bytes with no Unicode normalization". Swift considers "\u{E9}" and "e\u{301}"
    // equal as strings, but they are different bytes, so they must be different passwords. The hash below is the
    // published answer for the decomposed form.
    @Test func verifyDoesNotNormalizeUnicode() {
        let decomposedHash = PasswordHash(algorithm: "pbkdf2-sha256", iterations: 1000, salt: "MDEyMzQ1Njc4OWFiY2RlZg==", hash: "xi1vnSqp9WCUs0ZreJp7QOmeAvV8dT8clFtp07rSrr0=")
        #expect(PasswordHasher.verify(password: "e\u{301}xxxx", against: decomposedHash))
        #expect(!PasswordHasher.verify(password: "\u{E9}xxxx", against: decomposedHash))
        let composedHash = PasswordHash(algorithm: "pbkdf2-sha256", iterations: 1000, salt: "MDEyMzQ1Njc4OWFiY2RlZg==", hash: "93swqJMdbK66ZHJNJ5ArzOMAn4l4F4nR9wHYKkHW7yg=")
        #expect(PasswordHasher.verify(password: "\u{E9}xxxx", against: composedHash))
        #expect(!PasswordHasher.verify(password: "e\u{301}xxxx", against: composedHash))
    }

    // A password handled as a C string would stop at the first NUL byte, making "abc\0defg" and "abc\0xyzq" the same password.
    @Test func verifyTreatsAnEmbeddedNulByteAsPartOfThePassword() throws {
        let hash = try makeHash("abc\u{0}defg")
        #expect(PasswordHasher.verify(password: "abc\u{0}defg", against: hash))
        #expect(!PasswordHasher.verify(password: "abc\u{0}xyzq", against: hash))
        #expect(!PasswordHasher.verify(password: "abc", against: hash))
        #expect(!PasswordHasher.verify(password: "abc\u{0}", against: hash))
        let plain = try makeHash("abc")
        #expect(!PasswordHasher.verify(password: "abc\u{0}defg", against: plain))
    }

    @Test func verifyAcceptsAVeryLongPasswordAndRejectsOneThatDiffersOnlyAtTheEnd() throws {
        let long = String(repeating: "correct horse ", count: 1000)
        let hash = try makeHash(long)
        #expect(PasswordHasher.verify(password: long, against: hash))
        #expect(!PasswordHasher.verify(password: long + "!", against: hash))
        #expect(!PasswordHasher.verify(password: String(long.dropLast()), against: hash))
    }

    @Test func verifyOfAnEmptyPasswordIsFalseAndDoesNotCrash() throws {
        #expect(!PasswordHasher.verify(password: "", against: try makeHash("hunter22")))
    }

    // MARK: tampered or malformed stored hashes

    @Test func verifyFailsWhenTheIterationCountIsChanged() throws {
        let hash = try makeHash("hunter22")
        for delta in [-1, 1, 1000] {
            let tampered = PasswordHash(algorithm: hash.algorithm, iterations: hash.iterations + delta, salt: hash.salt, hash: hash.hash)
            #expect(!PasswordHasher.verify(password: "hunter22", against: tampered), "iterations + \(delta)")
        }
    }

    // A stored count that can never be valid must give false, not a crash. (Negative numbers cannot convert to the
    // unsigned count CommonCrypto takes, which is an easy way to trap.)
    @Test(arguments: [0, -1, -1000, Int.min])
    func verifyFailsAndDoesNotCrashOnAnImpossibleIterationCount(iterations: Int) throws {
        let hash = try makeHash("hunter22")
        let tampered = PasswordHash(algorithm: hash.algorithm, iterations: iterations, salt: hash.salt, hash: hash.hash)
        #expect(!PasswordHasher.verify(password: "hunter22", against: tampered))
    }

    @Test(arguments: ["pbkdf2-sha1", "pbkdf2-sha512", "bcrypt", "", "sha256", "pbkdf2", "pbkdf2-sha256 ", "pbkdf2-sha256\u{0}"])
    func verifyFailsForAnUnknownAlgorithmEvenWithTheRightBytes(algorithm: String) throws {
        let hash = try makeHash("hunter22")
        let tampered = PasswordHash(algorithm: algorithm, iterations: hash.iterations, salt: hash.salt, hash: hash.hash)
        #expect(!PasswordHasher.verify(password: "hunter22", against: tampered))
    }

    @Test(arguments: ["!!!not base64!!!", "abc", "====", "@@@@", "YWJj\u{0}", "   "])
    func verifyFailsForASaltThatIsNotBase64(salt: String) throws {
        let hash = try makeHash("hunter22")
        let tampered = PasswordHash(algorithm: hash.algorithm, iterations: hash.iterations, salt: salt, hash: hash.hash)
        #expect(!PasswordHasher.verify(password: "hunter22", against: tampered))
    }

    @Test(arguments: ["!!!not base64!!!", "abc", "====", "@@@@", "   "])
    func verifyFailsForAHashThatIsNotBase64(storedHash: String) throws {
        let hash = try makeHash("hunter22")
        let tampered = PasswordHash(algorithm: hash.algorithm, iterations: hash.iterations, salt: hash.salt, hash: storedHash)
        #expect(!PasswordHasher.verify(password: "hunter22", against: tampered))
    }

    @Test func verifyFailsWhenTheSaltIsReplacedOrEmptyOrTruncated() throws {
        let hash = try makeHash("hunter22")
        let saltBytes = [UInt8](try #require(Data(base64Encoded: hash.salt)))
        for salt in ["", Data(saltBytes.prefix(8)).base64EncodedString(), Data(saltBytes + [0]).base64EncodedString(), Data(repeating: 0, count: 16).base64EncodedString()] {
            let tampered = PasswordHash(algorithm: hash.algorithm, iterations: hash.iterations, salt: salt, hash: hash.hash)
            #expect(!PasswordHasher.verify(password: "hunter22", against: tampered))
        }
    }

    // A comparison that stops at the shorter of the two byte strings would accept an empty or truncated stored hash, because
    // every byte it looks at matches. The stored hash must equal all 32 derived bytes.
    @Test(arguments: [0, 1, 8, 16, 31])
    func verifyFailsWhenTheStoredHashIsATruncatedPrefixOfTheRealOne(length: Int) throws {
        let hash = try makeHash("hunter22")
        let real = [UInt8](try #require(Data(base64Encoded: hash.hash)))
        #expect(!PasswordHasher.verify(password: "hunter22", against: replacingHashBytes(hash, with: Array(real.prefix(length)))))
    }

    @Test func verifyFailsWhenTheStoredHashHasExtraBytesAppended() throws {
        let hash = try makeHash("hunter22")
        let real = [UInt8](try #require(Data(base64Encoded: hash.hash)))
        #expect(!PasswordHasher.verify(password: "hunter22", against: replacingHashBytes(hash, with: real + [0])))
        #expect(!PasswordHasher.verify(password: "hunter22", against: replacingHashBytes(hash, with: real + real)))
    }

    @Test(arguments: [0, 15, 31])
    func verifyFailsWhenAnySingleStoredHashByteIsFlipped(position: Int) throws {
        let hash = try makeHash("hunter22")
        var bytes = [UInt8](try #require(Data(base64Encoded: hash.hash)))
        try #require(bytes.indices.contains(position), "the stored hash has only \(bytes.count) bytes")
        bytes[position] ^= 0x01
        #expect(!PasswordHasher.verify(password: "hunter22", against: replacingHashBytes(hash, with: bytes)))
    }

    // MARK: validateNew

    @Test(arguments: ["abcdef", "abcdefg", "123456", "a b c d", "  ab  ", "      a", "\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}", "pass\tword"])
    func validateNewAcceptsPasswordsOfSixOrMoreCharacters(password: String) {
        #expect(weakness(password) == nil)
    }

    @Test(arguments: ["abcde", "a", "12345", "abc", "\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}", "ab cd"])
    func validateNewRejectsPasswordsOfFewerThanSixCharactersAsTooShort(password: String) {
        #expect(weakness(password) == .tooShort(minimum: 6), "\(password.debugDescription) has \(password.count) characters")
    }

    // Six or more spaces pass the length rule, so the only rule left to fail is "not only spaces".
    @Test(arguments: ["      ", "       ", String(repeating: " ", count: 40)])
    func validateNewRejectsPasswordsMadeOnlyOfSpacesAsWhitespaceOnly(password: String) {
        #expect(weakness(password) == .whitespaceOnly)
    }

    // Both rules apply to these (shorter than six and only spaces); the design does not say which error wins.
    @Test(arguments: ["", " ", "   ", "     "])
    func validateNewRejectsShortAndEmptySpacePasswords(password: String) {
        let error = weakness(password)
        #expect(error == .whitespaceOnly || error == .tooShort(minimum: 6))
    }

    @Test func minimumLengthIsSix() {
        #expect(PasswordHasher.minimumLength == 6)
    }
}

import CryptoKit
import Foundation

/// What GitHub's `version.json` says about the newest published build.
public struct UpdateInfo: Codable, Equatable, Sendable {
    /// The version text, always `1.0.<build>`.
    public let version: String
    /// The build number: the count of commits the package was built from.
    public let build: Int
    /// The full 40-character commit hash the package was built from.
    public let commit: String
    /// The file name of the package in the same release. Always `SiteBlock.zip`.
    public let asset: String
    /// The SHA-256 checksum of the package as 64 lowercase hex characters.
    public let sha256: String

    /// Creates the info from its five fields. It does not check them; `UpdateCheck.parse` does.
    public init(version: String, build: Int, commit: String, asset: String, sha256: String) {
        self.version = version
        self.build = build
        self.commit = commit
        self.asset = asset
        self.sha256 = sha256
    }
}

/// The pure rules of the update check: where the newest version is published, whether a published file is usable, whether it is newer than the installed build, and whether a download matches its checksum. Nothing here touches the network, so the app does the fetching and this code does the judging.
public enum UpdateCheck {
    /// Where the newest build's `version.json` is published. This is a constant: nothing outside the code can point the app at another server.
    public static let versionURL = URL(string: "https://github.com/nokal123/SiteBlock/releases/latest/download/version.json")!
    /// Where the newest package is published, under a name that never changes.
    public static let packageURL = URL(string: "https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip")!

    /// The only package file name `version.json` may name.
    private static let packageName = "SiteBlock.zip"

    /// Reads a `version.json` file. Returns nil unless it is valid JSON with all five fields and every rule holds: the build is above 0, the version is `1.0.` followed by that build, the asset is `SiteBlock.zip`, the checksum is exactly 64 lowercase hex characters, and the commit is exactly 40. Extra fields are ignored. Anything else means "no usable update info" and never crashes.
    public static func parse(_ data: Data) -> UpdateInfo? {
        guard let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else { return nil }
        guard info.build > 0, info.version == "1.0.\(info.build)", info.asset == packageName else { return nil }
        guard isLowercaseHex(info.sha256, length: 64), isLowercaseHex(info.commit, length: 40) else { return nil }
        return info
    }

    /// True when the published build is newer than the installed one. An installed build of 0 (built without git) counts every published build as newer, because a published build is always above 0.
    public static func isNewer(_ info: UpdateInfo, than installedBuild: Int) -> Bool {
        info.build > installedBuild
    }

    /// True when the SHA-256 of the file at `url` equals `expected`; upper and lower case letters are treated alike. A file that cannot be read does not match. The file is read in chunks, so a large file does not have to fit in memory.
    public static func matchesChecksum(fileAt url: URL, expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        // `read(upToCount:)` returns nil (not empty data) at the end of the file, so nil ends the loop; only a thrown read error means the file could not be read. Writing `try?` here would fold the two together and fail every file.
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return false
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == expected.lowercased()
    }

    /// True when the text is exactly `length` characters, each a digit or a lowercase letter a to f. It looks at the raw UTF-8 bytes, so look-alike characters from other scripts never pass.
    private static func isLowercaseHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

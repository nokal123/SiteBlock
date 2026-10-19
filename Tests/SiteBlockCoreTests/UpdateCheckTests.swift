import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § UpdateCheck (the two links, the rules `parse` applies, the newer-build rule) and
// 05-testing-and-operations.md § Unit Tests (UpdateCheckTests). Checksums are SHA-256 values computed outside the code under test with `shasum -a 256` and
// Python's hashlib. All JSON here is real text decoded by the real `parse`.

// A set of field values that satisfies every rule; each rejection test replaces exactly one of them.
private let goodCommit = "6d66e0bfd5f46eeec3b5ce483b809e1216dca669"
private let goodSha = "5922e8a290a73b0605644f5303d786540024661d09a99602a121802560122d9a"
// SHA-256 of nothing and of the three bytes "abc" (from `shasum -a 256`).
private let emptySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private let abcSha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

// Turns a Swift string into JSON text for a string value (quotes and escapes included).
private func jsonString(_ text: String) -> String {
    String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
}

// Builds a version.json text from raw JSON fragments. `overrides` replaces a field's fragment, or removes the field when the value is nil; `extra` adds more fields.
private func versionJSON(_ overrides: [String: String?] = [:], extra: [String: String] = [:]) -> String {
    var fields: [String: String] = ["version": jsonString("1.0.48"), "build": "48", "commit": jsonString(goodCommit), "asset": jsonString("SiteBlock.zip"), "sha256": jsonString(goodSha)]
    for (key, value) in overrides { fields[key] = value }
    for (key, value) in extra { fields[key] = value }
    let body = fields.sorted { $0.key < $1.key }.map { "\(jsonString($0.key)): \($0.value)" }.joined(separator: ", ")
    return "{\(body)}"
}

// One broken file and a label that names what is wrong with it.
struct BrokenFile: CustomTestStringConvertible, Sendable {
    let label: String
    let text: String
    var testDescription: String { label }
}

private func broken(_ label: String, _ overrides: [String: String?]) -> BrokenFile {
    BrokenFile(label: label, text: versionJSON(overrides))
}

// Every case changes one field and leaves the other four valid, so a pass can only come from that one field's rule.
private let brokenFields: [BrokenFile] = {
    var cases: [BrokenFile] = []
    // build must be above 0 (the version is kept consistent with the build so only the build rule can reject).
    cases.append(broken("build 0", ["build": "0", "version": jsonString("1.0.0")]))
    cases.append(broken("build -1", ["build": "-1", "version": jsonString("1.0.-1")]))
    cases.append(broken("build -48", ["build": "-48", "version": jsonString("1.0.-48")]))
    // version must be "1.0." followed by the build.
    for (label, version) in [("another build number", "1.0.47"), ("another minor part", "1.1.48"), ("another major part", "2.0.48"), ("extra part", "1.0.48.0"), ("trailing space", "1.0.48 "), ("leading space", " 1.0.48"), ("v prefix", "v1.0.48"), ("leading zero", "1.0.048"), ("suffix", "1.0.48-beta"), ("no build", "1.0."), ("empty", "")] {
        cases.append(broken("version: \(label)", ["version": jsonString(version)]))
    }
    // asset must be exactly SiteBlock.zip.
    for (label, asset) in [("lowercase", "siteblock.zip"), ("uppercase extension", "SiteBlock.ZIP"), ("trailing space", "SiteBlock.zip "), ("another name", "Other.zip"), ("parent folder", "../SiteBlock.zip"), ("full address", "https://evil.example/SiteBlock.zip"), ("empty", "")] {
        cases.append(broken("asset: \(label)", ["asset": jsonString(asset)]))
    }
    // sha256 must be 64 lowercase hexadecimal characters.
    let hex63 = String(goodSha.dropLast())
    let sha: [(String, String)] = [("63 characters", hex63), ("65 characters", goodSha + "0"), ("uppercase", goodSha.uppercased()), ("one uppercase letter", "A" + goodSha.dropFirst()), ("non-hex last character", hex63 + "g"), ("empty", ""), ("64 characters with a space", hex63 + " "), ("63 hex and a newline", hex63 + "\n"), ("64 characters with a Cyrillic a", hex63 + "\u{0430}"), ("64 characters with a full-width a", hex63 + "\u{FF41}"), ("64 bytes but 63 characters", String(goodSha.dropLast(2)) + "\u{0430}")]
    for (label, value) in sha { cases.append(broken("sha256: \(label)", ["sha256": jsonString(value)])) }
    // commit must be 40 lowercase hexadecimal characters.
    let commit: [(String, String)] = [("39 characters", String(goodCommit.dropLast())), ("41 characters", goodCommit + "0"), ("uppercase", goodCommit.uppercased()), ("non-hex character", String(goodCommit.dropLast()) + "z"), ("empty", ""), ("a 64-character value", goodSha), ("40 characters with a full-width a", String(goodCommit.dropLast()) + "\u{FF41}"), ("a short hash", String(goodCommit.prefix(7)))]
    for (label, value) in commit { cases.append(broken("commit: \(label)", ["commit": jsonString(value)])) }
    // Each of the five fields missing.
    for key in ["version", "build", "commit", "asset", "sha256"] { cases.append(broken("missing \(key)", [key: nil])) }
    // Each of the five fields with the wrong JSON type.
    cases.append(broken("version as a number", ["version": "48"]))
    cases.append(broken("build as a string", ["build": jsonString("48")]))
    cases.append(broken("build as a fraction", ["build": "48.5"]))
    cases.append(broken("build as null", ["build": "null"]))
    cases.append(broken("build beyond the Int range", ["build": "9223372036854775808", "version": jsonString("1.0.9223372036854775808")]))
    cases.append(broken("commit as a number", ["commit": "123"]))
    cases.append(broken("asset as null", ["asset": "null"]))
    cases.append(broken("asset as a list", ["asset": "[\"SiteBlock.zip\"]"]))
    cases.append(broken("sha256 as a boolean", ["sha256": "true"]))
    cases.append(broken("sha256 as an object", ["sha256": "{\"value\": \(jsonString(goodSha))}"]))
    return cases
}()

@Suite("UpdateCheck constants and parse") struct UpdateCheckParseTests {
    // 02 § UpdateCheck: the two links are written into the code and are exactly these addresses.
    @Test func theTwoLinksAreTheDocumentedGitHubAddresses() {
        #expect(UpdateCheck.versionURL.absoluteString == "https://github.com/nokal123/SiteBlock/releases/latest/download/version.json")
        #expect(UpdateCheck.packageURL.absoluteString == "https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip")
    }

    // 02 § UpdateCheck, parse: a valid file comes back with all five values unchanged.
    @Test func parseAcceptsAValidFileAndKeepsAllFiveValues() throws {
        let info = try #require(UpdateCheck.parse(Data(versionJSON().utf8)))
        #expect(info == UpdateInfo(version: "1.0.48", build: 48, commit: goodCommit, asset: "SiteBlock.zip", sha256: goodSha))
    }

    // 04 § Packaging for Another Mac: the exact text layout package.sh writes (two-space indent, one field per line, trailing newline) must be accepted.
    @Test func parseAcceptsTheLayoutThatPackageShWrites() throws {
        let text = "{\n  \"version\": \"1.0.7\",\n  \"build\": 7,\n  \"commit\": \"\(goodCommit)\",\n  \"asset\": \"SiteBlock.zip\",\n  \"sha256\": \"\(goodSha)\"\n}\n"
        let info = try #require(UpdateCheck.parse(Data(text.utf8)))
        #expect(info.build == 7 && info.version == "1.0.7")
    }

    // 02 § UpdateCheck: "Extra fields in the JSON are ignored."
    @Test(arguments: [["note": "\"hello\""], ["size": "1258850"], ["nested": "{\"a\": [1, 2, {\"b\": null}]}"], ["version2": "\"9.9.9\""], ["asset2": "\"Evil.zip\""]])
    func parseAcceptsExtraFields(extra: [String: String]) throws {
        let info = try #require(UpdateCheck.parse(Data(versionJSON(extra: extra).utf8)))
        #expect(info.build == 48 && info.asset == "SiteBlock.zip" && info.sha256 == goodSha && info.commit == goodCommit)
    }

    // 04 § Packaging: a package built without git has a commit of 40 zeros. Zeros are valid lowercase hexadecimal, and only the build of 0 makes such a file unusable (next test).
    @Test func parseAcceptsAllZeroCommitAndChecksumDigits() throws {
        let zeros40 = String(repeating: "0", count: 40)
        let zeros64 = String(repeating: "0", count: 64)
        let info = try #require(UpdateCheck.parse(Data(versionJSON(["commit": jsonString(zeros40), "sha256": jsonString(zeros64)]).utf8)))
        #expect(info.commit == zeros40 && info.sha256 == zeros64)
    }

    // 02 § UpdateCheck: any build above 0 is fine as long as the version text agrees, including the largest Int.
    @Test(arguments: [1, 9, 10, 100, 2_000_000, Int.max])
    func parseAcceptsAnyPositiveBuildWhoseVersionAgrees(build: Int) throws {
        let info = try #require(UpdateCheck.parse(Data(versionJSON(["build": String(build), "version": jsonString("1.0.\(build)")]).utf8)))
        #expect(info.build == build && info.version == "1.0.\(build)")
    }

    // 02 § UpdateCheck: "parse rejects each broken field on its own, with every other field valid".
    @Test(arguments: brokenFields)
    func parseRejectsABrokenFile(file: BrokenFile) {
        #expect(UpdateCheck.parse(Data(file.text.utf8)) == nil, "accepted: \(file.text)")
    }

    // Control for the table above: the same builder with no override is accepted, so the table's rejections come from the changed field and not from the builder.
    @Test func theBuilderWithNoChangeProducesAnAcceptedFile() {
        #expect(UpdateCheck.parse(Data(versionJSON().utf8)) != nil)
    }

    // 02 § UpdateCheck: "text that is not JSON, empty data" and the unit-test list's JSON array and `{}` all give nil without crashing.
    @Test(arguments: ["not json at all", "", "[]", "{}", "null", "\"1.0.48\"", "48", "{", "{\"version\": \"1.0.48\", \"build\": 48", "<html><body>404 Not Found</body></html>", "[\(versionJSON())]", "\u{FEFF}"])
    func parseReturnsNilForTextThatIsNotAVersionFile(text: String) {
        #expect(UpdateCheck.parse(Data(text.utf8)) == nil)
    }

    // Bytes that are not even valid UTF-8 (what a half-downloaded or binary response could look like) also give nil.
    @Test func parseReturnsNilForBinaryGarbageAndForEmptyData() {
        #expect(UpdateCheck.parse(Data()) == nil)
        #expect(UpdateCheck.parse(Data([0xFF, 0xFE, 0x00, 0x7B, 0x80, 0x81])) == nil)
        #expect(UpdateCheck.parse(Data(repeating: 0, count: 64)) == nil)
    }
}

@Suite("UpdateCheck isNewer") struct UpdateCheckIsNewerTests {
    private func info(build: Int) -> UpdateInfo {
        UpdateInfo(version: "1.0.\(build)", build: build, commit: goodCommit, asset: "SiteBlock.zip", sha256: goodSha)
    }

    // 02 § UpdateCheck: true only for a higher published build; equal and lower are false; an installed build of 0 counts every published build as newer.
    @Test(arguments: [(49, 48, true), (48, 48, false), (47, 48, false), (1, 0, true), (48, 0, true), (Int.max, 0, true), (2, 1, true), (1, 1, false), (10, 9, true), (9, 10, false), (100, 99, true)])
    func isNewerFollowsTheBuildNumbers(published: Int, installed: Int, expected: Bool) {
        #expect(UpdateCheck.isNewer(info(build: published), than: installed) == expected, "published \(published), installed \(installed)")
    }

    // 02 § UpdateCheck: the comparison is numeric, not on the text of the version (build 9 is older than build 10 even though "9" sorts after "10").
    @Test func isNewerComparesNumbersNotText() {
        #expect(UpdateCheck.isNewer(info(build: 10), than: 9))
        #expect(!UpdateCheck.isNewer(info(build: 9), than: 10))
    }
}

// Asserts that the file at `url` matches `expected`; reports the failure at the caller's line.
private func expectMatch(_ url: URL, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(UpdateCheck.matchesChecksum(fileAt: url, expected: expected), sourceLocation: sourceLocation)
}

@Suite("UpdateCheck matchesChecksum") struct UpdateCheckChecksumTests {
    // A fresh temporary folder for one test, deleted when the test ends.
    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    private func write(_ bytes: [UInt8], in folder: URL, name: String = "file.bin") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // 05 § UnitTests: an empty file matches the well-known SHA-256 of nothing.
    @Test func anEmptyFileMatchesTheEmptyInputChecksum() throws {
        try withFolder { folder in
            let url = try write([], in: folder)
            expectMatch(url, emptySha)
            #expect(!UpdateCheck.matchesChecksum(fileAt: url, expected: abcSha))
        }
    }

    // 05 § UnitTests: a file holding the three bytes "abc" matches ba7816bf....
    @Test func aFileHoldingAbcMatchesItsChecksum() throws {
        try withFolder { folder in
            let url = try write(Array("abc".utf8), in: folder)
            expectMatch(url, abcSha)
        }
    }

    // 05 § UnitTests: one byte changed gives a different checksum (shasum: "abd" is a52d159f...), so the old value no longer matches while the new file's own value does.
    @Test func oneChangedByteNoLongerMatches() throws {
        try withFolder { folder in
            let url = try write(Array("abd".utf8), in: folder)
            #expect(!UpdateCheck.matchesChecksum(fileAt: url, expected: abcSha))
            expectMatch(url, "a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9")
        }
    }

    // 05 § UnitTests: "the expected value in uppercase still matches". Mixed case too.
    @Test func theExpectedValueMayBeInUppercaseOrMixedCase() throws {
        try withFolder { folder in
            let url = try write(Array("abc".utf8), in: folder)
            expectMatch(url, abcSha.uppercased())
            expectMatch(url, "BA7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015AD")
        }
    }

    // 05 § UnitTests: "an expected value that is not the file's checksum, including an empty one, does not match."
    @Test(arguments: ["", "0", emptySha, String(repeating: "0", count: 64), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015a", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad0", "ba7816bf"])
    func aWrongOrEmptyExpectedValueDoesNotMatch(expected: String) throws {
        try withFolder { folder in
            let url = try write(Array("abc".utf8), in: folder)
            #expect(!UpdateCheck.matchesChecksum(fileAt: url, expected: expected))
        }
    }

    // 02 § UpdateCheck: the file is read in chunks; sizes around the one-megabyte chunk edge and a multi-chunk file must give the same checksum as a one-shot hash. Expected values come from Python's hashlib over bytes (i % 251).
    @Test(arguments: [(1_048_575, "8b55c6a2d3444092a316985030e00c1e6f8608eaf912c896dee7c374d440ed11"), (1_048_576, "631b84027d6b9e52b539c4e8373622d23032dfadc64d60af87339c9037e4f769"), (1_048_577, "5769f52bc3eef28afa39c6fc68cadb7d0bd69812ae3a3d71452f519ec3c7aa56"), (3_145_728, "a1feacf0d812ba4d0b0e463ed45bbd583cea1de55c54693116754b30b5794745")])
    func largeFilesMatchTheirIndependentlyComputedChecksum(size: Int, expected: String) throws {
        try withFolder { folder in
            let bytes = (0..<size).map { UInt8($0 % 251) }
            let url = try write(bytes, in: folder)
            expectMatch(url, expected)
            // One flipped byte in the last position (past every chunk edge) must break the match.
            var changed = bytes
            changed[size - 1] ^= 0x01
            let other = try write(changed, in: folder, name: "changed.bin")
            #expect(!UpdateCheck.matchesChecksum(fileAt: other, expected: expected))
        }
    }

    // A file that does not exist, or a folder, cannot match any checksum (the design gives no case where an unreadable download passes).
    @Test func aMissingFileOrAFolderNeverMatches() throws {
        try withFolder { folder in
            #expect(!UpdateCheck.matchesChecksum(fileAt: folder.appendingPathComponent("nothing-here.zip"), expected: emptySha))
            #expect(!UpdateCheck.matchesChecksum(fileAt: folder, expected: emptySha))
        }
    }
}

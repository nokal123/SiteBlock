import Foundation
import Testing

// A scan of the two source files that measure countdown time: neither may read the wall clock.
// Design: 01-overview-and-data.md § Data Model (Countdown: "A countdown stores time remaining rather than a finish time, because a finish time would be compared against the wall clock, which the user can change") and § Threat Model (clock changes); 03-daemon-cli-app.md § DaemonRuntime "Tick" step 1 (elapsed time comes from `ContinuousClock`, which "cannot be changed by the user").
// The scan is a guard against one specific way of breaking that rule. It cannot prove the clock is right (the timing tests do that); it makes sure nobody swaps in `Date` without a test failing.
@Suite("Source scan: no wall clock")
struct SourceScanTests {
    // The folder that holds Package.swift, found by walking up from this test file.
    static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) { return directory }
            directory.deleteLastPathComponent()
        }
        throw TestFailure("no Package.swift found above \(#filePath)")
    }

    // The patterns that mean "reads the wall clock": `Date()` (or any `Date(` initializer), `Date.now`, `timeIntervalSince...` (for example `timeIntervalSince1970` or `timeIntervalSinceNow`), the Objective-C `NSDate`, and the C-level wall clock calls.
    static let forbidden: [(name: String, pattern: String)] = [
        ("Date()", #"\bDate\s*\("#),
        ("Date.now", #"\bDate\s*\.\s*now\b"#),
        ("timeIntervalSince", #"timeIntervalSince"#),
        ("NSDate", #"\bNSDate\b"#),
        ("CFAbsoluteTimeGetCurrent", #"CFAbsoluteTimeGetCurrent"#),
        ("gettimeofday", #"\bgettimeofday\b"#),
    ]

    // The source text with every comment replaced by blanks (line breaks kept), so a comment that merely mentions `Date()` is not reported. String literals are skipped over while scanning, so a `//` inside a string does not start a comment.
    static func withoutComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        var index = 0
        var blockDepth = 0
        while index < characters.count {
            let current = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if blockDepth > 0 {
                if current == "*", next == "/" { blockDepth -= 1; index += 2; continue }
                if current == "/", next == "*" { blockDepth += 1; index += 2; continue }
                if current == "\n" { result.append("\n") }
                index += 1
                continue
            }
            if current == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if current == "/", next == "*" { blockDepth = 1; index += 2; continue }
            if current == "\"" {
                // Copy a string literal as it is, honouring backslash escapes.
                result.append(current)
                index += 1
                while index < characters.count {
                    let inside = characters[index]
                    result.append(inside)
                    index += 1
                    if inside == "\\", index < characters.count { result.append(characters[index]); index += 1; continue }
                    if inside == "\"" || inside == "\n" { break }
                }
                continue
            }
            result.append(current)
            index += 1
        }
        return result
    }

    // The names of the forbidden patterns that appear in the code part of the source (comments ignored).
    static func wallClockUses(in source: String) -> [String] {
        let code = withoutComments(source)
        return forbidden.filter { code.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.name)
    }

    // The scanner itself must see what it is meant to see: each forbidden form in code is reported, and the same text inside a comment is not.
    @Test(arguments: [
        "let now = Date()",
        "let now = Date ( )",
        "let now = Date.now",
        "let t = date.timeIntervalSince1970",
        "let t = Date(timeIntervalSinceNow: 5)",
        "let t = a.timeIntervalSince(b)",
        "let d = NSDate()",
        "let t = CFAbsoluteTimeGetCurrent()",
    ])
    func theScannerReportsEveryWallClockFormWrittenInCode(code: String) {
        #expect(!Self.wallClockUses(in: code).isEmpty, "not reported: \(code)")
        #expect(!Self.wallClockUses(in: code + "\n").isEmpty)
        #expect(!Self.wallClockUses(in: "/* x */ " + code).isEmpty)
    }

    @Test(arguments: [
        "// let now = Date()",
        "/// never use Date.now or timeIntervalSince here",
        "/* Date() */ let x = 1",
        "/* outer /* Date.now */ still comment Date() */ let x = 1",
        "let x = ContinuousClock.now // Date() would be wrong",
        "let update = candidate(1)\nlet s = \"a // b\" ; let y = ContinuousClock.now",
        "let x = Calendar.current.dateInterval",
    ])
    func theScannerIgnoresWallClockNamesInsideComments(code: String) {
        #expect(Self.wallClockUses(in: code).isEmpty, "wrongly reported: \(code) -> \(Self.wallClockUses(in: code))")
    }

    // A `//` inside a string literal is not a comment: a use after it on the same line is still found.
    @Test func theScannerDoesNotTreatTextInsideAStringLiteralAsAComment() {
        #expect(!Self.wallClockUses(in: "let s = \"http://x\"; let n = Date()").isEmpty)
    }

    // 01 § Data Model and 03 § DaemonRuntime "Tick": the daemon runtime and the engine never read the wall clock, so moving the system clock cannot move a countdown. Both files must also exist and have code in them, so a rename cannot make this scan vacuous.
    @Test(arguments: ["Sources/siteblockd/DaemonRuntime.swift", "Sources/SiteBlockCore/Engine.swift"])
    func theCountdownSourceFilesNeverReadTheWallClock(relativePath: String) throws {
        let url = try Self.repositoryRoot().appendingPathComponent(relativePath)
        let source = try #require(try? String(contentsOf: url, encoding: .utf8), "\(url.path) cannot be read")
        let code = Self.withoutComments(source)
        #expect(code.contains("func ") || code.contains("class "), "\(relativePath) has no code the scan could look at")
        let found = Self.wallClockUses(in: source)
        #expect(found.isEmpty, "\(relativePath) reads the wall clock: \(found)")
    }
}

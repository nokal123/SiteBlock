import Foundation
import SiteBlockCore
import Testing

// Real runs of scripts/release-check.sh and scripts/package.sh as child processes, plus checks of the hand-kept release number and of .github/workflows/package.yml.
// Expected values come from Design Plans/04-infrastructure.md § Version Numbers, § Packaging for Another Mac and § Automatic Package Builds, and 05-testing-and-operations.md
// § Integration Tests (Script tests): the build number is the release number kept by hand in Models.swift (`public let siteBlockBuildNumber = <n>`); no generated file and no
// script write it; the version people see is <series>.<max(0, build - series first build)>; version.json carries `version` "1.0.<build>", `build` and `displayVersion`;
// release-check.sh prints `release` for a higher new build, `skip` for an equal one, and fails (exit 1, an "error: ..." line on standard error, nothing on standard output)
// for a lower one or for a file whose `build` is not a JSON whole number.
//
// scripts/package.sh builds release programs with scripts/build.sh, which takes minutes. The packaging tests therefore run package.sh on a COPY in a temporary folder and
// replace ONLY scripts/build.sh in the copy with a stand-in that compiles a tiny daemon together with the copy's own Sources/SiteBlockCore/Models.swift, so the version the
// stand-in daemon prints comes from that file exactly as the real daemon's does. The copy's Models.swift carries a release number of its own (for example 7), which proves that
// version.json takes the number from the file in the tree that is packaged, not from the commit count and not from the build these tests were compiled with.

// Where the repository is: the folder above Tests/, found by walking up from this file until Package.swift appears.
private let repositoryRoot: String = {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) { return directory.path }
        directory.deleteLastPathComponent()
    }
    fatalError("Package.swift not found above \(#filePath)")
}()

// The environment every script and git call gets: a private git identity and no user or system git configuration, so the repository on the machine cannot change the result.
private let gitEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "QA", "GIT_AUTHOR_EMAIL": "qa@example.invalid", "GIT_COMMITTER_NAME": "QA", "GIT_COMMITTER_EMAIL": "qa@example.invalid"]

// One clang module cache shared by every stand-in compile, so Foundation's modules are built once per machine instead of once per test (a cold cache costs about 15 s).
private let sharedModuleCache = "/tmp/sbs-module-cache"

// Runs git inside a folder and returns the trimmed standard output; throws when git fails.
@discardableResult
private func git(_ directory: String, _ arguments: [String]) throws -> String {
    let result = try runProgram("/usr/bin/git", ["-C", directory, "-c", "commit.gpgsign=false"] + arguments, environment: gitEnvironment)
    try require(result.status == 0 && !result.timedOut, "git \(arguments.joined(separator: " ")) failed (\(result.status)): \(result.stderr)")
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

// Makes an empty folder under /tmp that the exit hook deletes at the latest, and returns its path.
private func makeTemporaryFolder(_ prefix: String = "/tmp/sbs-") throws -> String {
    Registry.installOnce()
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    let root = prefix + String((0..<8).map { _ in alphabet.randomElement()! })
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    Registry.add(directory: root)
    return root
}

// The repository's Models.swift with the lines that declare the given constants replaced (for example ["siteBlockBuildNumber": "7"]). Throws unless each constant is declared
// on exactly one line, so a test can never silently keep the repository's own number.
private func modelsSwift(replacing values: [String: String]) throws -> String {
    var lines = try #require(readText(repositoryRoot + "/Sources/SiteBlockCore/Models.swift")).components(separatedBy: "\n")
    for (name, value) in values {
        let indexes = lines.indices.filter { lines[$0].hasPrefix("public let \(name) = ") }
        try require(indexes.count == 1, "Models.swift declares \(name) on \(indexes.count) lines, expected exactly one")
        lines[indexes[0]] = "public let \(name) = \(value)"
    }
    return lines.joined(separator: "\n")
}

// The right-hand side of `public let <name> = <value>` in a Swift source text, or nil when the text does not declare it on exactly one line.
private func declaredValue(_ name: String, in text: String) -> String? {
    let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("public let \(name) = ") }
    guard lines.count == 1 else { return nil }
    return String(lines[0].dropFirst("public let \(name) = ".count)).trimmingCharacters(in: .whitespaces)
}

// The repository's Models.swift as text.
private func repositoryModels() throws -> String { try #require(readText(repositoryRoot + "/Sources/SiteBlockCore/Models.swift"), "Models.swift is missing") }

// A temporary folder laid out like the repository: the named real scripts copied into scripts/ and a Sources/SiteBlockCore/Models.swift whose release number is `buildNumber`.
private struct ScriptTree {
    let root: String
    var modelsFile: String { root + "/Sources/SiteBlockCore/Models.swift" }

    // Makes the folder under /tmp (the exit hook deletes it). A non-nil `commits` makes it a git repository with that many empty commits; nil leaves it a plain folder.
    static func make(commits: Int?, buildNumber: Int, scripts: [String]) throws -> ScriptTree {
        let root = try makeTemporaryFolder()
        try FileManager.default.createDirectory(atPath: root + "/scripts", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Sources/SiteBlockCore", withIntermediateDirectories: true)
        for name in scripts { try FileManager.default.copyItem(atPath: repositoryRoot + "/scripts/" + name, toPath: root + "/scripts/" + name) }
        let tree = ScriptTree(root: root)
        try tree.setBuildNumber(buildNumber)
        if let commits {
            try git(root, ["init", "-q", "-b", "main"])
            for number in 0..<commits { try git(root, ["commit", "-q", "--allow-empty", "-m", "commit \(number)"]) }
        }
        return tree
    }

    // Writes the tree's Models.swift: the repository's own file with only the release number changed.
    func setBuildNumber(_ number: Int) throws { try writeText(try modelsSwift(replacing: ["siteBlockBuildNumber": String(number)]), to: modelsFile) }

    func addCommit() throws { try git(root, ["commit", "-q", "--allow-empty", "-m", "another"]) }
}

// Compiles a tiny program together with the given Models.swift text and returns what it prints: the shown version, the marketing version and the build id, one per line.
private func versionsCompiledFrom(models text: String) throws -> [String] {
    let folder = try makeTemporaryFolder()
    try writeText(text, to: folder + "/Models.swift")
    try writeText("print(siteBlockVersion)\nprint(siteBlockMarketingVersion)\nprint(siteBlockBuildID)\n", to: folder + "/main.swift")
    let compiled = try runProgram("/usr/bin/swiftc", ["-module-cache-path", sharedModuleCache, "-o", folder + "/probe", folder + "/main.swift", folder + "/Models.swift"], timeout: 240)
    try require(compiled.status == 0 && !compiled.timedOut, "swiftc failed (\(compiled.status)): \(compiled.stderr)")
    let run = try runProgram(folder + "/probe", [])
    try require(run.status == 0, "the probe failed: \(run.stderr)")
    return run.stdout.split(separator: "\n").map(String.init)
}

@Suite("Script tests: the hand-kept release number")
struct ReleaseNumberTests {
    // 04 § Version Numbers: the build number is `public let siteBlockBuildNumber = <n>` in Models.swift, a checked-in whole number. Exactly one declaration in all of Sources/,
    // so no second (generated or forgotten) file can define or shadow it.
    @Test func modelsSwiftDeclaresTheReleaseNumberOnceAsAWholeNumberAboveZeroAndNoOtherSourceFileDoes() throws {
        let text = try repositoryModels()
        let value = try #require(declaredValue("siteBlockBuildNumber", in: text), "Models.swift does not declare siteBlockBuildNumber on exactly one line")
        #expect(value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber), "the release number must be a plain whole-number literal; it is '\(value)'")
        #expect((Int(value) ?? 0) > 0, "the release number must be above 0; it is '\(value)'")
        let sources = try #require(FileManager.default.enumerator(atPath: repositoryRoot + "/Sources")).compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        let declaring = sources.filter { (readText(repositoryRoot + "/Sources/" + $0) ?? "").contains("let siteBlockBuildNumber") }
        #expect(declaring == ["SiteBlockCore/Models.swift"], "files declaring siteBlockBuildNumber: \(declaring)")
    }

    // 04 § Version Numbers: no generated BuildNumber.swift and no write-build-number script exist, and the build, test and package scripts do not call one.
    @Test func noGeneratedBuildNumberFileAndNoWriteBuildNumberScriptRemain() {
        for gone in ["Sources/SiteBlockCore/BuildNumber.swift", "scripts/write-build-number.sh"] {
            #expect(!FileManager.default.fileExists(atPath: repositoryRoot + "/" + gone), "\(gone) must not exist")
        }
        for script in ["scripts/build.sh", "scripts/test.sh", "scripts/package.sh"] {
            let text = readText(repositoryRoot + "/" + script) ?? ""
            #expect(!text.isEmpty, "\(script) is missing")
            #expect(!text.contains("write-build-number") && !text.contains("BuildNumber.swift"), "\(script) still refers to the generated build number")
        }
    }

    // 04 § Version Numbers: the library, the build id and the built daemon all carry the number written in Models.swift, and the shown version is
    // <series>.<max(0, build - series first build)>. The numbers are read from the file's text, so the test holds for any release number.
    @Test func theLibraryAndTheBuiltDaemonCarryTheNumberWrittenInModelsSwift() throws {
        let text = try repositoryModels()
        let build = try #require(Int(declaredValue("siteBlockBuildNumber", in: text) ?? ""))
        let first = try #require(Int(declaredValue("siteBlockSeriesFirstBuild", in: text) ?? ""))
        let seriesLiteral = try #require(declaredValue("siteBlockSeries", in: text))
        let series = seriesLiteral.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let shown = "\(series).\(max(0, build - first))"
        #expect(siteBlockBuildNumber == build, "the tests were built with \(siteBlockBuildNumber), Models.swift says \(build)")
        #expect(siteBlockBuildID == "1.0.\(build)")
        #expect(siteBlockMarketingVersion == shown && siteBlockVersion == shown, "shown version: \(siteBlockVersion), expected \(shown)")
        let version = try runDaemonProgram(["--version"])
        #expect(version.status == 0)
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "siteblockd \(shown) (build \(build))", "got: \(version.stdout)")
    }

    // 04 § Version Numbers, with the design's own example (series 1.2 starting at build 51: build 94 shows 1.2.43). Builds at or below the series' first build show <series>.0;
    // 1051 shows a four-digit count. Each case compiles Models.swift for real with only the three numbers changed.
    @Test(arguments: [(7, "1.2.0"), (50, "1.2.0"), (51, "1.2.0"), (52, "1.2.1"), (94, "1.2.43"), (1051, "1.2.1000")])
    func theShownVersionIsTheSeriesAndHowFarTheBuildIsPastTheSeriesFirstBuild(build: Int, shown: String) throws {
        let text = try modelsSwift(replacing: ["siteBlockSeries": "\"1.2\"", "siteBlockSeriesFirstBuild": "51", "siteBlockBuildNumber": String(build)])
        let printed = try versionsCompiledFrom(models: text)
        #expect(printed == [shown, shown, "1.0.\(build)"], "printed \(printed)")
    }
}

// Writes a complete version.json (the six fields package.sh writes) whose `build` is the given JSON fragment, or with no `build` at all when the fragment is nil, and returns its path.
private func writeVersionFile(in folder: String, name: String, build fragment: String?) throws -> String {
    let buildLine = fragment.map { "  \"build\": \($0),\n" } ?? ""
    let text = "{\n  \"version\": \"1.0.95\",\n\(buildLine)  \"displayVersion\": \"1.2.44\",\n  \"commit\": \"\(String(repeating: "a", count: 40))\",\n  \"asset\": \"SiteBlock.zip\",\n  \"sha256\": \"\(String(repeating: "b", count: 64))\"\n}\n"
    let path = folder + "/" + name
    try writeText(text, to: path)
    return path
}

// Runs the repository's own scripts/release-check.sh directly (as the workflow does, so its shebang and executable bit are part of the test) with the two paths.
private func releaseCheck(_ new: String, _ published: String) throws -> ProgramResult {
    try runProgram(repositoryRoot + "/scripts/release-check.sh", [new, published], timeout: 30)
}

// Runs release-check.sh on two complete version files whose `build` fields are the given JSON fragments.
private func releaseCheck(new: String?, published: String?) throws -> ProgramResult {
    let folder = try makeTemporaryFolder()
    return try releaseCheck(try writeVersionFile(in: folder, name: "new.json", build: new), try writeVersionFile(in: folder, name: "published.json", build: published))
}

// The checks every refusal must pass: exit code 1, nothing on standard output, and an "error: ..." line on standard error.
private func expectRefused(_ result: ProgramResult, _ context: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!result.timedOut && !result.killedBySignal, "\(context): the script did not finish", sourceLocation: sourceLocation)
    #expect(result.status == 1, "\(context): exit \(result.status), stdout '\(result.stdout)', stderr '\(result.stderr)'", sourceLocation: sourceLocation)
    #expect(result.stdout.isEmpty, "\(context): a refusal must print nothing on standard output, got '\(result.stdout)'", sourceLocation: sourceLocation)
    #expect(result.stderr.hasPrefix("error: "), "\(context): standard error must start with 'error: ', got '\(result.stderr)'", sourceLocation: sourceLocation)
}

// The script's decision, with the checks every accepted comparison must pass: exit code 0 and exactly one line on standard output.
private func decision(_ result: ProgramResult) -> String? {
    guard result.status == 0, !result.timedOut else { return nil }
    let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count == 2, lines[1].isEmpty else { return "<not one line: '\(result.stdout)'>" }
    return lines[0]
}

@Suite("Script tests: release-check.sh")
struct ReleaseCheckScriptTests {
    // A higher new build is a release. Pairs where the new number has more digits (100 > 99, 1000 > 999, 10 > 9) catch a text comparison; 0 is a JSON whole number too;
    // 3000000000 is above the 32-bit range, which a whole-number build may still reach.
    @Test(arguments: [(95, 94), (100, 99), (1000, 999), (10, 9), (1, 0), (3_000_000_000, 2_999_999_999)])
    func aHigherNewBuildPrintsReleaseAndExitsZero(new: Int, published: Int) throws {
        let result = try releaseCheck(new: String(new), published: String(published))
        #expect(decision(result) == "release", "new \(new), published \(published): exit \(result.status), stdout '\(result.stdout)', stderr '\(result.stderr)'")
    }

    @Test(arguments: [1, 94, 1000])
    func anEqualBuildPrintsSkipAndExitsZero(build: Int) throws {
        let result = try releaseCheck(new: String(build), published: String(build))
        #expect(decision(result) == "skip", "build \(build): exit \(result.status), stdout '\(result.stdout)', stderr '\(result.stderr)'")
    }

    // A lower new build is refused: installed copies would never take it. 99 against 100 and 999 against 1000 are "higher" as text, so a text comparison would print release.
    @Test(arguments: [(93, 94), (99, 100), (999, 1000), (9, 10), (0, 1)])
    func aLowerNewBuildIsRefused(new: Int, published: Int) throws {
        expectRefused(try releaseCheck(new: String(new), published: String(published)), "new \(new), published \(published)")
    }

    // A `build` that is not a JSON whole number is refused in either file. The opposite file holds a valid 94, so the only fault is the one under test.
    // "95.0" comes from the draft 04 § Automatic Package Builds ("a decimal such as 95.0" is refused).
    // 1e3 is the number 1000 written with an exponent: not a whole-number literal, so it is refused like 95.0.
    @Test(arguments: ["\"95\"", "95.5", "95.0", "1e3", "-1", "null", "true", "false", "{}", "[95]", "\"\"", nil] as [String?], [true, false])
    func aBuildThatIsNotAJSONWholeNumberIsRefusedInEitherFile(fragment: String?, inNewFile: Bool) throws {
        let result = inNewFile ? try releaseCheck(new: fragment, published: "94") : try releaseCheck(new: "95", published: fragment)
        expectRefused(result, "build \(fragment ?? "<missing>") in the \(inNewFile ? "new" : "published") file")
    }

    // -0 is the JSON whole number 0 written with a sign, so it counts as 0 in either file: equal to a published 0 (skip), lower than a published 1 (refused), lower than a
    // new 1 (release). A check that refused every minus sign, or read -0 as "below 0", would get the first and third rows wrong.
    @Test(arguments: [("-0", "0", "skip"), ("0", "-0", "skip"), ("1", "-0", "release"), ("-0", "1", "refused")])
    func minusZeroCountsAsZeroInEitherFile(new: String, published: String, expected: String) throws {
        let result = try releaseCheck(new: new, published: published)
        if expected == "refused" { expectRefused(result, "new \(new), published \(published)") }
        else { #expect(decision(result) == expected, "new \(new), published \(published): exit \(result.status), stdout '\(result.stdout)', stderr '\(result.stderr)'") }
    }

    // A file that is missing, empty, not JSON, or JSON without a top-level `build` (an array holding the object, the field nested deeper, or the key spelled "Build") is refused,
    // in either position.
    @Test(arguments: ["<missing>", "", "not json at all\n", "[{\"build\": 95}]\n", "{\"info\": {\"build\": 95}}\n", "{\"Build\": 95}\n", "{\"build\": 95\n"], [true, false])
    func aFileThatIsMissingOrNotAVersionObjectIsRefusedInEitherPosition(content: String, inNewFile: Bool) throws {
        let folder = try makeTemporaryFolder()
        let bad = folder + "/bad.json"
        if content != "<missing>" { try writeText(content, to: bad) }
        let good = try writeVersionFile(in: folder, name: "good.json", build: inNewFile ? "94" : "95")
        expectRefused(inNewFile ? try releaseCheck(bad, good) : try releaseCheck(good, bad), "file '\(content)' as the \(inNewFile ? "new" : "published") file")
    }

    // The workflow passes real paths; a folder with spaces and non-ASCII letters must not break the script's quoting.
    @Test func pathsWithSpacesAndNonASCIILettersWork() throws {
        let folder = try makeTemporaryFolder() + "/a folder ñ é"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let new = try writeVersionFile(in: folder, name: "new version.json", build: "95")
        let published = try writeVersionFile(in: folder, name: "published version.json", build: "94")
        let result = try releaseCheck(new, published)
        #expect(decision(result) == "release", "exit \(result.status), stdout '\(result.stdout)', stderr '\(result.stderr)'")
    }

    // The workflow runs `scripts/release-check.sh ...` directly, so git must record the file as executable (mode 100755), or GitHub's checkout cannot run it.
    @Test func gitRecordsTheScriptAsExecutable() throws {
        let listed = try git(repositoryRoot, ["ls-files", "-s", "scripts/release-check.sh"])
        #expect(listed.hasPrefix("100755 "), "git ls-files -s says: '\(listed)'")
    }
}

// The result of one real run of scripts/package.sh in a prepared copy.
private struct PackageRun {
    let tree: ScriptTree
    let result: ProgramResult
    var dist: String { tree.root + "/dist" }
    var zip: String { dist + "/SiteBlock.zip" }
    var versionFile: String { dist + "/version.json" }

    // The stand-in for scripts/build.sh: a tiny arm64 program per product in build/, signed ad hoc, laid out as the real build.sh does. The program is compiled together with THIS
    // tree's Sources/SiteBlockCore/Models.swift and prints the line the real daemon prints, so its version and build number are the tree's own.
    private static let standInBuild = """
    #!/bin/bash
    set -euo pipefail
    cd "$(dirname "$0")/.."
    rm -rf build
    mkdir -p build/SiteBlock.app/Contents/MacOS
    mkdir -p "$TMPDIR_STANDIN"
    printf 'print("siteblockd \\(siteBlockVersion) (build \\(siteBlockBuildNumber))")\\n' > "$TMPDIR_STANDIN/main.swift"
    swiftc -module-cache-path "$MODULE_CACHE_STANDIN" -o build/siteblockd "$TMPDIR_STANDIN/main.swift" Sources/SiteBlockCore/Models.swift
    cp build/siteblockd build/siteblock
    cp build/siteblockd build/SiteBlock.app/Contents/MacOS/SiteBlock
    printf '<?xml version="1.0" encoding="UTF-8"?>\\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>SiteBlock</string><key>CFBundleIdentifier</key><string>com.example.standin</string></dict></plist>\\n' > build/SiteBlock.app/Contents/Info.plist
    codesign --force -s - build/siteblockd build/siteblock build/SiteBlock.app
    """

    // Prepares a copy with the real package.sh, install.sh and verify-install.sh, the stand-in build.sh, and a Models.swift whose release number is `buildNumber`.
    // `commits` nil makes a folder that is not a git checkout.
    static func prepare(commits: Int?, buildNumber: Int) throws -> ScriptTree {
        let tree = try ScriptTree.make(commits: commits, buildNumber: buildNumber, scripts: ["package.sh", "install.sh", "verify-install.sh"])
        try writeText(standInBuild + "\n", to: tree.root + "/scripts/build.sh")
        try chmodPath(tree.root + "/scripts/build.sh", 0o755)
        return tree
    }

    // Runs package.sh of the copy.
    static func run(in tree: ScriptTree) throws -> PackageRun {
        let environment = gitEnvironment.merging(["TMPDIR_STANDIN": tree.root + "/standin", "MODULE_CACHE_STANDIN": sharedModuleCache]) { _, new in new }
        let result = try runProgram("/bin/bash", [tree.root + "/scripts/package.sh"], environment: environment, timeout: 300)
        return PackageRun(tree: tree, result: result)
    }

    static func make(commits: Int?, buildNumber: Int) throws -> PackageRun { try run(in: try prepare(commits: commits, buildNumber: buildNumber)) }

    // The file's JSON object, or nil.
    var versionObject: [String: Any]? { readJSONObject(versionFile) as? [String: Any] }

    // The `build` field as a whole number, or nil when it is missing, not a number, or a boolean.
    var build: Int? {
        guard let number = versionObject?["build"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    // The SHA-256 of the zip as `shasum -a 256` reports it.
    func shasumOfZip() throws -> String {
        let out = try runProgram("/usr/bin/shasum", ["-a", "256", zip])
        return out.stdout.split(separator: " ").first.map(String.init) ?? ""
    }
}

// One run in a git checkout with 3 commits whose Models.swift says 7, and one in a folder that is not a checkout whose Models.swift also says 7. The commit count (3) and the
// number the tests themselves were built with differ from 7, so only a build number read from the packaged tree's Models.swift gives 7. Each run is made once and only read.
private let gitPackage = Result { try PackageRun.make(commits: 3, buildNumber: 7) }
private let plainPackage = Result { try PackageRun.make(commits: nil, buildNumber: 7) }

@Suite("Script tests: package.sh and version.json")
struct PackageScriptTests {
    // 04 § Packaging for Another Mac: package.sh "writes two files into dist/": SiteBlock.zip and version.json. The staging folder is removed.
    @Test func packageShSucceedsAndLeavesExactlyTheZipAndVersionJson() throws {
        let run = try gitPackage.get()
        #expect(run.result.status == 0 && !run.result.timedOut, "package.sh failed:\n\(run.result.stdout)\n\(run.result.stderr)")
        let listing = ((try? FileManager.default.contentsOfDirectory(atPath: run.dist)) ?? []).sorted()
        #expect(listing == ["SiteBlock.zip", "version.json"], "dist holds: \(listing)")
    }

    // 04: version.json has the six fields `version` (the technical id 1.0.<build>), `build` (a number), `displayVersion` (the version people see, from the daemon), `commit`, `asset` and `sha256` (text), and no others.
    @Test func versionJsonHasExactlyTheSixDocumentedFieldsWithTheDocumentedTypes() throws {
        let run = try gitPackage.get()
        let object = try #require(run.versionObject, "version.json is not a JSON object")
        #expect(Set(object.keys) == ["version", "build", "displayVersion", "commit", "asset", "sha256"])
        #expect(object["version"] is String && object["displayVersion"] is String && object["commit"] is String && object["asset"] is String && object["sha256"] is String)
        #expect(run.build != nil, "build is not a whole number: \(String(describing: object["build"]))")
        #expect(object["asset"] as? String == "SiteBlock.zip")
    }

    // The release number comes from the packaged tree's Models.swift (7): not the commit count (3) and not the number these tests were compiled with. The shown version for 7
    // under series 1.2 starting at 51 is 1.2.0 (the count never goes below 0), and the technical id is 1.0.7.
    @Test func versionJsonCarriesTheReleaseNumberWrittenInThePackagedTreesModelsSwift() throws {
        let run = try gitPackage.get()
        try require(run.result.status == 0, "package.sh failed:\n\(run.result.stdout)\n\(run.result.stderr)")
        #expect(siteBlockBuildNumber != 7, "the repository's own number is 7, so this test cannot tell the two apart; change the tree's number")
        #expect(run.build == 7, "version.json: \(String(describing: run.versionObject))")
        #expect(run.versionObject?["version"] as? String == "1.0.7")
        #expect(run.versionObject?["displayVersion"] as? String == "1.2.0")
    }

    // 05 § Script tests: its sha256 equals the SHA-256 of the zip it describes, as computed by shasum -a 256, written as 64 lowercase hexadecimal characters.
    @Test func theChecksumInVersionJsonIsTheShasumOfTheZip() throws {
        let run = try gitPackage.get()
        let written = try #require(run.versionObject?["sha256"] as? String)
        #expect(written == (try run.shasumOfZip()), "version.json says \(written)")
        #expect(written.count == 64 && written == written.lowercased())
    }

    // 05 § Script tests: UpdateCheck.parse accepts the file; its commit is the full hash `git rev-parse HEAD` reports; its version and build are those of the program just built
    // (the stand-in daemon's own --version, which is compiled from the tree's Models.swift).
    @Test func versionJsonIsAcceptedByParseAndNamesTheBuiltVersionAndTheCheckedOutCommit() throws {
        let run = try gitPackage.get()
        let data = try #require(FileManager.default.contents(atPath: run.versionFile))
        let info = try #require(UpdateCheck.parse(data), "UpdateCheck.parse rejected:\n\(String(data: data, encoding: .utf8) ?? "?")")
        #expect(info.build == 7 && info.version == "1.0.7" && info.displayVersion == "1.2.0")
        #expect(info.commit == (try git(run.tree.root, ["rev-parse", "HEAD"])))
        #expect(info.asset == "SiteBlock.zip")
        let daemon = try runProgram(run.tree.root + "/build/siteblockd", ["--version"])
        #expect(daemon.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "siteblockd 1.2.0 (build 7)", "daemon says: \(daemon.stdout)")
    }

    // 04: the zip holds one `SiteBlock` folder with build/, scripts/install.sh, scripts/verify-install.sh, Install SiteBlock.command and INSTALL.txt, and it is a valid zip.
    @Test func theZipHoldsTheDocumentedFilesUnderOneSiteBlockFolder() throws {
        let run = try gitPackage.get()
        let tested = try runProgram("/usr/bin/unzip", ["-tq", run.zip])
        #expect(tested.status == 0, "unzip -t: \(tested.stdout) \(tested.stderr)")
        let names = try runProgram("/usr/bin/unzip", ["-Z1", run.zip]).stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX") }
        #expect(!names.isEmpty && names.allSatisfy { $0.hasPrefix("SiteBlock/") }, "entries outside SiteBlock/: \(names.filter { !$0.hasPrefix("SiteBlock/") })")
        for required in ["SiteBlock/build/siteblockd", "SiteBlock/build/siteblock", "SiteBlock/build/SiteBlock.app/Contents/Info.plist", "SiteBlock/scripts/install.sh", "SiteBlock/scripts/verify-install.sh", "SiteBlock/Install SiteBlock.command", "SiteBlock/INSTALL.txt"] {
            #expect(names.contains(required), "missing \(required) in \(names)")
        }
    }

    // 04: "When git is not available, the commit is 40 zeros." The build number does not depend on git at all, so a folder that is not a checkout still gets the number in
    // its Models.swift (7), not 0. The checksum still describes the zip.
    @Test func withoutGitTheCommitIsFortyZerosAndTheBuildIsStillTheNumberInModelsSwift() throws {
        let run = try plainPackage.get()
        #expect(run.result.status == 0 && !run.result.timedOut, "package.sh failed:\n\(run.result.stdout)\n\(run.result.stderr)")
        #expect(run.versionObject?["commit"] as? String == String(repeating: "0", count: 40))
        #expect(run.versionObject?["sha256"] as? String == (try run.shasumOfZip()))
        #expect(run.build == 7 && run.versionObject?["version"] as? String == "1.0.7", "version.json: \(String(describing: run.versionObject))")
    }

    // 04 § Version Numbers: another commit does not change the build number (only raising it in Models.swift does), while the commit and the checksum follow the new commit and
    // the new zip. Raising the number by one then gives the next build and the next shown version (60 shows 1.2.9; 61 shows 1.2.10, a two-digit count).
    @Test func aCommitLeavesTheBuildAloneAndRaisingTheNumberInModelsSwiftRaisesIt() throws {
        let tree = try PackageRun.prepare(commits: 2, buildNumber: 60)
        let first = try PackageRun.run(in: tree)
        try require(first.result.status == 0, "first run failed:\n\(first.result.stdout)\n\(first.result.stderr)")
        // Read now: every run writes the same dist/version.json, so each object must be captured before the next run replaces it.
        let firstObject = first.versionObject
        try tree.addCommit()
        let second = try PackageRun.run(in: tree)
        try require(second.result.status == 0, "second run failed:\n\(second.result.stdout)\n\(second.result.stderr)")
        let secondObject = second.versionObject
        try tree.setBuildNumber(61)
        let third = try PackageRun.run(in: tree)
        try require(third.result.status == 0, "third run failed:\n\(third.result.stdout)\n\(third.result.stderr)")

        #expect((firstObject?["build"] as? NSNumber)?.intValue == 60 && firstObject?["displayVersion"] as? String == "1.2.9" && firstObject?["version"] as? String == "1.0.60")
        #expect((secondObject?["build"] as? NSNumber)?.intValue == 60, "a commit must not change the build: \(String(describing: secondObject))")
        #expect(secondObject?["commit"] as? String != firstObject?["commit"] as? String, "the commit must follow the new HEAD")
        #expect(secondObject?["commit"] as? String == (try git(tree.root, ["rev-parse", "HEAD"])))
        #expect(third.build == 61 && third.versionObject?["displayVersion"] as? String == "1.2.10" && third.versionObject?["version"] as? String == "1.0.61")
        #expect(third.versionObject?["sha256"] as? String == (try third.shasumOfZip()))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: third.dist)) ?? []).sorted() == ["SiteBlock.zip", "version.json"])
    }
}

// One step of a workflow: its name, its step-level keys (id, if, uses, run, ...) and its whole text (from its "- name:" line to the next step).
struct WorkflowStep {
    let name: String
    let keys: [String: String]
    let text: String
}

// Splits a GitHub workflow into its steps, in order, across every job. A `steps:` line opens a list; each line that starts with "- " at the list's dash column starts a
// step (named or not); a line at or left of the `steps:` column closes the list. A step's keys are its first line's key and the lines exactly two columns past the dash
// (the step's own keys), so a key that only appears inside a `run:` script or a `with:` block is never mistaken for one. Comment lines are dropped.
func workflowSteps(_ text: String) -> [WorkflowStep] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    var steps: [(indent: Int, lines: [String])] = []
    var stepsColumn: Int? = nil
    var dashColumn: Int? = nil
    var open = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " }.count
        if trimmed.isEmpty { if open { steps[steps.count - 1].lines.append(line) }; continue }
        if trimmed == "steps:" { stepsColumn = indent; dashColumn = nil; open = false; continue }
        guard let column = stepsColumn else { continue }
        if indent <= column { stepsColumn = nil; open = false; continue }
        if trimmed.hasPrefix("- "), dashColumn == nil || indent == dashColumn {
            dashColumn = indent
            steps.append((indent, [line]))
            open = true
        } else if open {
            steps[steps.count - 1].lines.append(line)
        }
    }
    return steps.map { step in
        var keys: [String: String] = [:]
        // Reads "key: value" from a line, ignoring lines without a colon.
        func record(_ trimmed: Substring) {
            guard let colon = trimmed.firstIndex(of: ":") else { return }
            keys[String(trimmed[..<colon])] = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        record(step.lines[0].trimmingCharacters(in: .whitespaces).dropFirst(2))
        for line in step.lines.dropFirst() where line.prefix(while: { $0 == " " }).count == step.indent + 2 { record(Substring(line.trimmingCharacters(in: .whitespaces))) }
        return WorkflowStep(name: keys["name"] ?? "", keys: keys, text: step.lines.joined(separator: "\n"))
    }
}

// A step-level `if:` value with an optional ${{ }} wrapper removed, so both spellings of the same condition compare equal.
func bareCondition(_ value: String?) -> String? {
    guard var value else { return nil }
    if value.hasPrefix("${{") && value.hasSuffix("}}") { value = String(value.dropFirst(3).dropLast(2)) }
    return value.trimmingCharacters(in: .whitespaces)
}

// .github/workflows/package.yml read as text. Design: 04-infrastructure.md § Version Numbers and § Automatic Package Builds: the checkout takes only the newest commit
// (the release number is read from Models.swift), the workflow runs the tests and scripts/package.sh, a step named "Decide whether this is a release" with id `decide` runs
// scripts/release-check.sh on the new and the published version.json, and every publishing step runs only when that decision is `release`.
@Suite("Script tests: package workflow")
struct PackageWorkflowTests {
    private static let text = readText(repositoryRoot + "/.github/workflows/package.yml") ?? ""
    private static let steps = workflowSteps(text)

    // The first step whose text contains the fragment.
    private func step(containing fragment: String) -> WorkflowStep? { Self.steps.first { $0.text.contains(fragment) } }

    // The position of the named step, or nil.
    private func index(named name: String) -> Int? { Self.steps.firstIndex { $0.name == name } }

    @Test func theWorkflowFileExists() { #expect(!Self.text.isEmpty && Self.steps.count > 3) }

    // 04 § Version Numbers: "the GitHub workflow checks out only the newest commit", so no step asks for the full history.
    // The pattern also catches a quoted 0 and a 0 followed by a comment; the self-check below proves it, so a narrower pattern cannot pass this test by matching nothing.
    @Test func theCheckoutDoesNotFetchTheFullHistory() throws {
        let checkout = try #require(step(containing: "actions/checkout"), "no checkout step")
        let fullHistory = Self.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.asksForFullHistory)
        #expect(fullHistory.isEmpty, "checkout step:\n\(checkout.text)")
        #expect(["fetch-depth: 0", "fetch-depth: '0'", "fetch-depth: \"0\"", "fetch-depth: 0 # x", "fetch-depth:0#x"].allSatisfy(Self.asksForFullHistory), "the pattern misses a spelling of fetch-depth 0")
        #expect(!["fetch-depth: 1", "fetch-depth: 10", "fetch-depth: 1 # 0"].contains(where: Self.asksForFullHistory), "the pattern matches a depth other than 0")
    }

    // True when a trimmed workflow line sets fetch-depth to 0 (the full history), quoted or not, with or without a trailing comment.
    private static func asksForFullHistory(_ line: some StringProtocol) -> Bool { String(line).range(of: #"^fetch-depth:\s*['"]?0['"]?\s*(#.*)?$"#, options: .regularExpression) != nil }

    @Test func theWorkflowRunsTheTestsAndThenThePackageScript() throws {
        let tests = try #require(Self.steps.firstIndex { $0.text.contains("scripts/test.sh") }, "no step runs scripts/test.sh")
        let package = try #require(Self.steps.firstIndex { $0.text.contains("scripts/package.sh") }, "no step runs scripts/package.sh")
        #expect(tests < package, "the tests must run before the package is built, so a failing test stops the publish")
    }

    // The decide step: named as the design says, id `decide`, runs release-check.sh with the freshly built dist/version.json first and the downloaded published file second,
    // and writes `decision=` to $GITHUB_OUTPUT (that output is what every publishing step reads; without it nothing could ever be published).
    @Test func theDecideStepHasIdDecideRunsTheReleaseCheckAndWritesTheDecisionOutput() throws {
        let decide = try #require(Self.steps.first { $0.name == "Decide whether this is a release" }, "no step named 'Decide whether this is a release'")
        #expect(decide.keys["id"] == "decide", "id: \(decide.keys["id"] ?? "<none>")")
        let call = try #require(decide.text.split(separator: "\n").first { $0.contains("scripts/release-check.sh") }, "the decide step does not run scripts/release-check.sh")
        let afterScript = call.components(separatedBy: "scripts/release-check.sh").last ?? ""
        let arguments = afterScript.split(separator: " ").map(String.init)
        #expect(arguments.first == "dist/version.json", "the new file must be the first argument: \(call)")
        #expect(arguments.count >= 2 && arguments[1].hasSuffix("version.json") && arguments[1] != "dist/version.json", "the published file must be the second argument: \(call)")
        #expect(decide.text.contains("decision=") && decide.text.contains("GITHUB_OUTPUT"), "the decide step must write decision=<...> to $GITHUB_OUTPUT")
        #expect(decide.text.contains("gh release download"), "the decide step must download the published version.json")
    }

    // The decision needs the new dist/version.json, so it runs after the package is built, and before anything is published.
    @Test func theDecideStepRunsAfterThePackageIsBuiltAndBeforeThePublishStep() throws {
        let decide = try #require(index(named: "Decide whether this is a release"))
        let package = try #require(Self.steps.firstIndex { $0.text.contains("scripts/package.sh") })
        let publish = try #require(index(named: "Publish this version as the latest release"), "no step named 'Publish this version as the latest release'")
        #expect(package < decide && decide < publish, "order: package \(package), decide \(decide), publish \(publish)")
    }

    // Every step that changes a release or a tag on GitHub (gh release create/delete/upload/edit, git tag, git push) runs only when the decision is `release`, the named
    // publish step included. The decide step's own `gh release download` only reads.
    @Test func everyPublishingStepRunsOnlyWhenTheDecisionIsRelease() throws {
        let publishing = Self.steps.filter { step in ["gh release create", "gh release delete", "gh release upload", "gh release edit", "git tag", "git push"].contains { step.text.contains($0) } }
        #expect(publishing.contains { $0.name == "Publish this version as the latest release" }, "the named publish step is missing or publishes nothing: \(publishing.map(\.name))")
        for step in publishing {
            #expect(bareCondition(step.keys["if"]) == "steps.decide.outputs.decision == 'release'", "step '\(step.name)' has if: \(step.keys["if"] ?? "<none>")")
        }
    }

    @Test func theReleaseStepUploadsBothFilesFromDist() throws {
        let release = try #require(step(containing: "gh release create"), "no step creates the release")
        #expect(release.text.contains("dist/SiteBlock.zip") && release.text.contains("dist/version.json"), "release step:\n\(release.text)")
        // 04 § Automatic Package Builds: each version gets its own release tagged v<version>, marked as the latest, so older releases (and their download counts) are kept.
        #expect(release.text.contains("\"v$VERSION\"") && release.text.contains("--latest"), "the release must be tagged v<version> and marked latest")
    }
}

// The number of spaces a line starts with.
private func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }

// The script of a step's own `run:` key: for `run: |`, the block under it with its common indentation removed (as YAML reads a literal block); otherwise the inline value.
// Nil when the step has no `run:` of its own. Comment lines are already gone from the step's text, which changes nothing a shell runs.
func runScript(of step: WorkflowStep) -> String? {
    let lines = step.text.components(separatedBy: "\n")
    let keyColumn = leadingSpaces(lines[0]) + 2
    guard let at = lines.indices.dropFirst().first(where: { leadingSpaces(lines[$0]) == keyColumn && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("run:") }) else { return nil }
    let value = lines[at].trimmingCharacters(in: .whitespaces).dropFirst(4).trimmingCharacters(in: .whitespaces)
    guard value == "|" else { return value.isEmpty ? nil : value + "\n" }
    var body: [String] = []
    for line in lines[(at + 1)...] {
        if !line.trimmingCharacters(in: .whitespaces).isEmpty && leadingSpaces(line) <= keyColumn { break }
        body.append(line)
    }
    let indent = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(leadingSpaces).min() ?? 0
    return body.map { String($0.dropFirst(min(indent, leadingSpaces($0)))) }.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
}

// A stand-in for the GitHub command line (`gh`), put first on the PATH. It records every call (one file per call, the words separated by NUL) in $STUB_CALLS. For
// `gh release download` it copies $STUB_SOURCE into the --dir folder under the --pattern name, as the real download does, or fails like a missing release when
// $STUB_FAIL is set. Any other command exits 97, so a step that did something besides downloading would show up.
private let ghStub = """
#!/bin/bash
n=$(ls "$STUB_CALLS" | wc -l | tr -d ' ')
printf '%s\\0' gh "$@" > "$STUB_CALLS/$(printf '%03d' "$n").args"
[ "$1" = release ] && [ "$2" = download ] || exit 97
if [ -n "${STUB_FAIL:-}" ]; then echo "release not found (stub)" >&2; exit 1; fi
pattern=""; dir="."
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --pattern|-p) pattern="$2"; shift ;;
    --dir|-D) dir="$2"; shift ;;
  esac
  shift
done
[ -n "$pattern" ] || exit 98
cp "$STUB_SOURCE" "$dir/$pattern"

"""

// What one real run of package.yml's decide step gave: the process result, the lines it wrote to $GITHUB_OUTPUT, and each recorded `gh` call's words (after "gh").
private struct DecideStepRun {
    let result: ProgramResult
    let outputLines: [String]
    let ghCalls: [[String]]
    var stdoutLines: [String] { result.stdout.components(separatedBy: "\n") }
    var errorLines: [String] { stdoutLines.filter { $0.hasPrefix("::error") } }

    // Runs the step's real `run:` script with `bash -e`, as GitHub runs a step with no shell named, in a folder laid out as the checkout is at that point: dist/version.json
    // with the new build, and scripts/release-check.sh as a link to the repository's real script. The stand-in gh "downloads" a version file whose build is `published`
    // (or fails when `published` is nil). $GITHUB_OUTPUT is an empty temporary file, as on GitHub.
    static func run(new: String, published: String?) throws -> DecideStepRun {
        let steps = workflowSteps(readText(repositoryRoot + "/.github/workflows/package.yml") ?? "")
        let decide = try #require(steps.first { $0.name == "Decide whether this is a release" }, "no step named 'Decide whether this is a release'")
        let script = try #require(runScript(of: decide), "the decide step has no run: script")
        try require(!script.contains("${{"), "the decide step's script holds a ${{ }} expression this test does not fill in:\n\(script)")
        let tree = try makeTemporaryFolder()
        let tools = try makeTemporaryFolder()
        for folder in [tree + "/dist", tree + "/scripts", tools + "/bin", tools + "/calls"] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        _ = try writeVersionFile(in: tree + "/dist", name: "version.json", build: new)
        try FileManager.default.createSymbolicLink(atPath: tree + "/scripts/release-check.sh", withDestinationPath: repositoryRoot + "/scripts/release-check.sh")
        let source = try writeVersionFile(in: tools, name: "published-source.json", build: published ?? "94")
        try writeText(ghStub, to: tools + "/bin/gh")
        try chmodPath(tools + "/bin/gh", 0o755)
        try writeText(script, to: tools + "/step.sh")
        try writeText("", to: tools + "/github-output")
        var environment = ["PATH": tools + "/bin:/usr/bin:/bin", "GITHUB_OUTPUT": tools + "/github-output", "GH_TOKEN": "stub-token", "STUB_CALLS": tools + "/calls", "STUB_SOURCE": source]
        if published == nil { environment["STUB_FAIL"] = "1" }
        let result = try runProgram("/bin/bash", ["-c", "cd \"$1\" || exit 99; exec /bin/bash -e \"$2\"", "bash", tree, tools + "/step.sh"], environment: environment, timeout: 30)
        let output = (readText(tools + "/github-output") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        let callFiles = ((try? FileManager.default.contentsOfDirectory(atPath: tools + "/calls")) ?? []).sorted()
        // Each file is "gh\0word\0...\0": the first word is the program and the empty piece after the last NUL is dropped.
        let calls: [[String]] = callFiles.map { file in Array((readText(tools + "/calls/" + file) ?? "").components(separatedBy: "\0").dropFirst().dropLast()) }
        return DecideStepRun(result: result, outputLines: output, ghCalls: calls)
    }

    // The words of a `gh release download` call that are not options or option values: the release tag, when one is named.
    static func positionalArguments(ofDownload call: [String]) -> [String] {
        var words = Array(call.dropFirst(2))
        var positional: [String] = []
        while !words.isEmpty {
            let word = words.removeFirst()
            if ["--pattern", "-p", "--dir", "-D", "--repo", "-R", "--output", "-O", "--archive", "-A"].contains(word) { if !words.isEmpty { words.removeFirst() } }
            else if !word.hasPrefix("-") { positional.append(word) }
        }
        return positional
    }
}

// package.yml's "Decide whether this is a release" step, run for real. Design: 04-infrastructure.md § Automatic Package Builds, step 5: the step downloads version.json from
// the release marked latest (`gh release download --pattern version.json`, so no tag is named) and runs scripts/release-check.sh on the new and the published file. On
// `release` the publishing step runs (it reads `decision=release` from the step's output); on `skip` a notice titled "Not a release" names the number to raise
// (`siteBlockBuildNumber` in `Models.swift`) and nothing is published; a published file that cannot be downloaded, or a failed check (a lower build, a malformed file),
// stops the run with an error annotation, so no decision may be written.
@Suite("Script tests: package workflow decide step, run for real")
struct PackageDecideStepRunTests {
    // The checks for a download made as the design says: exactly one gh call, `release download` from the latest release (no tag) with the pattern version.json.
    private func expectDownloadFromTheLatestRelease(_ run: DecideStepRun, _ context: String) {
        #expect(run.ghCalls.count == 1, "\(context): gh calls \(run.ghCalls)")
        guard let call = run.ghCalls.first else { return }
        #expect(Array(call.prefix(2)) == ["release", "download"], "\(context): \(call)")
        #expect(DecideStepRun.positionalArguments(ofDownload: call).isEmpty, "\(context): the download must come from the release marked latest, so no tag may be named: \(call)")
        let pattern = call.firstIndex { $0 == "--pattern" || $0 == "-p" }.flatMap { $0 + 1 < call.count ? call[$0 + 1] : nil }
        #expect(pattern == "version.json", "\(context): \(call)")
    }

    @Test func aHigherBuildWritesExactlyDecisionReleaseAndExitsZero() throws {
        let run = try DecideStepRun.run(new: "95", published: "94")
        #expect(run.result.status == 0 && !run.result.timedOut, "exit \(run.result.status), stdout '\(run.result.stdout)', stderr '\(run.result.stderr)'")
        #expect(run.outputLines == ["decision=release"], "GITHUB_OUTPUT: \(run.outputLines)")
        #expect(run.errorLines.isEmpty && !run.result.stdout.contains("Not a release"), "stdout: \(run.result.stdout)")
        expectDownloadFromTheLatestRelease(run, "release")
    }

    @Test func anEqualBuildWritesDecisionSkipAndANoticeNamingTheNumberToRaise() throws {
        let run = try DecideStepRun.run(new: "94", published: "94")
        #expect(run.result.status == 0 && !run.result.timedOut, "exit \(run.result.status), stdout '\(run.result.stdout)', stderr '\(run.result.stderr)'")
        #expect(run.outputLines == ["decision=skip"], "GITHUB_OUTPUT: \(run.outputLines)")
        let notice = run.stdoutLines.first { $0.hasPrefix("::notice title=Not a release::") }
        #expect(notice.map { $0.contains("siteBlockBuildNumber") && $0.contains("Models.swift") } == true, "the notice must name siteBlockBuildNumber in Models.swift; stdout: \(run.result.stdout)")
        #expect(run.errorLines.isEmpty, "stdout: \(run.result.stdout)")
        expectDownloadFromTheLatestRelease(run, "skip")
    }

    // A lower new build, a published build written as text, and a failed download each stop the step with an error annotation and write no decision, so nothing is published.
    @Test(arguments: [("93", "94" as String?, "a lower build"), ("95", "\"94\"", "a malformed published file"), ("95", nil, "a failed download")])
    func aLowerBuildAMalformedPublishedFileOrAFailedDownloadStopsTheRunWithoutADecision(new: String, published: String?, context: String) throws {
        let run = try DecideStepRun.run(new: new, published: published)
        #expect(run.result.status != 0 && !run.result.timedOut, "\(context): the step must fail; exit \(run.result.status), stdout '\(run.result.stdout)'")
        #expect(!run.errorLines.isEmpty, "\(context): the step must write an ::error annotation; stdout '\(run.result.stdout)', stderr '\(run.result.stderr)'")
        #expect(!run.outputLines.contains { $0.hasPrefix("decision=") }, "\(context): no decision may be written: \(run.outputLines)")
        expectDownloadFromTheLatestRelease(run, context)
    }
}

// A check of the step parser itself, so the workflow tests above cannot pass because the parser found nothing or read a key from inside a script.
@Suite("Script tests: workflow step parser")
struct WorkflowStepParserTests {
    @Test func theParserReadsStepLevelKeysAndIgnoresKeysInsideScriptsAndComments() {
        let text = """
        jobs:
          a:
            steps:
              - name: First
                id: one
                # if: commented-out
                run: |
                  echo "if: inside the script"
                  id: also-inside
              - name: Second
                if: ${{ steps.one.outputs.x == 'y' }}
                with:
                  if: nested
          b:
            steps:
              - uses: actions/checkout@v6
              - name: Third
                run: gh release create x
        """
        let steps = workflowSteps(text)
        #expect(steps.map(\.name) == ["First", "Second", "", "Third"])
        #expect(steps[2].keys["uses"] == "actions/checkout@v6" && !steps[2].text.contains("Third"))
        #expect(steps[0].keys["id"] == "one" && steps[0].keys["if"] == nil)
        #expect(bareCondition(steps[1].keys["if"]) == "steps.one.outputs.x == 'y'")
        #expect(!steps[1].text.contains("b:"), "the second step swallowed the next job: \(steps[1].text)")
        // runScript reads the block under `run: |` with its indentation removed, reads an inline `run:`, and finds none in a step without one.
        #expect(runScript(of: steps[0]) == "echo \"if: inside the script\"\nid: also-inside\n", "got: \(String(describing: runScript(of: steps[0])))")
        #expect(runScript(of: steps[3]) == "gh release create x\n" && runScript(of: steps[1]) == nil)
    }
}

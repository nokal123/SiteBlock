import Foundation
import SiteBlockCore
import Testing

// Real runs of scripts/write-build-number.sh and scripts/package.sh as child processes. Expected values come from Design Plans/04-infrastructure.md § Version Numbers and
// § Packaging for Another Mac, and 05-testing-and-operations.md § Integration Tests (Script tests). Every script runs on a COPY placed in a temporary folder laid out like the
// repository, so the repository's own generated BuildNumber.swift, build/ and dist/ are never touched (the first test below checks that).
//
// scripts/package.sh builds release programs with scripts/build.sh, which takes minutes. The packaging tests therefore replace ONLY scripts/build.sh in the copy with a stand-in
// that assembles build/ from the already-built debug programs (signed ad hoc, arm64 like the real ones). Everything the design says about version.json (the version taken from the
// built daemon, the commit, the checksum of the zip) is done by the real package.sh. The stand-in daemon prints the build number from the copy's own generated BuildNumber.swift.

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

// Runs git inside a folder and returns the trimmed standard output; throws when git fails.
@discardableResult
private func git(_ directory: String, _ arguments: [String]) throws -> String {
    let result = try runProgram("/usr/bin/git", ["-C", directory, "-c", "commit.gpgsign=false"] + arguments, environment: gitEnvironment)
    try require(result.status == 0 && !result.timedOut, "git \(arguments.joined(separator: " ")) failed (\(result.status)): \(result.stderr)")
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

// A temporary folder laid out like the repository: the real scripts copied into scripts/ and an empty Sources/SiteBlockCore/. Deleted by the exit hook at the latest.
private struct ScriptTree {
    let root: String
    var buildNumberFile: String { root + "/Sources/SiteBlockCore/BuildNumber.swift" }

    // Makes the folder under /tmp (the exit hook deletes it). A non-nil `commits` makes it a git repository with that many empty commits; nil leaves it a plain folder.
    static func make(commits: Int? = nil, scripts: [String] = ["write-build-number.sh"]) throws -> ScriptTree {
        Registry.installOnce()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let root = "/tmp/sbs-" + String((0..<8).map { _ in alphabet.randomElement()! })
        try FileManager.default.createDirectory(atPath: root + "/scripts", withIntermediateDirectories: true)
        Registry.add(directory: root)
        try FileManager.default.createDirectory(atPath: root + "/Sources/SiteBlockCore", withIntermediateDirectories: true)
        for name in scripts { try FileManager.default.copyItem(atPath: repositoryRoot + "/scripts/" + name, toPath: root + "/scripts/" + name) }
        let tree = ScriptTree(root: root)
        if let commits {
            try git(root, ["init", "-q", "-b", "main"])
            for number in 0..<commits { try git(root, ["commit", "-q", "--allow-empty", "-m", "commit \(number)"]) }
        }
        return tree
    }

    // Runs scripts/write-build-number.sh of the copy with the given PATH.
    @discardableResult
    func writeBuildNumber(path: String = "/usr/bin:/bin") throws -> ProgramResult {
        try runProgram("/bin/bash", [root + "/scripts/write-build-number.sh"], environment: gitEnvironment.merging(["PATH": path]) { _, new in new })
    }

    // The text of the generated file, or nil when the script wrote none.
    var generated: String? { readText(buildNumberFile) }

    // The number in the generated file's one declaration, or nil when the file is missing or does not hold exactly the documented declaration.
    var generatedNumber: Int? {
        guard let text = generated else { return nil }
        let declarations = text.split(separator: "\n").filter { $0.hasPrefix("public let siteBlockBuildNumber = ") }
        guard declarations.count == 1, let last = declarations.first?.split(separator: " ").last else { return nil }
        return Int(last)
    }

    func addCommit() throws { try git(root, ["commit", "-q", "--allow-empty", "-m", "another"]) }
}

@Suite("Script tests: write-build-number.sh")
struct WriteBuildNumberScriptTests {
    // 04 § Version Numbers: the file holds the number of commits, taken with `git rev-list --count HEAD`. Counts of one digit, two digits and a power of ten catch a text comparison or a wrong digit count.
    @Test(arguments: [1, 3, 9, 10, 12])
    func theScriptWritesTheCommitCountOfAGitCheckout(commits: Int) throws {
        let tree = try ScriptTree.make(commits: commits)
        let result = try tree.writeBuildNumber()
        #expect(result.status == 0 && !result.timedOut, "stderr: \(result.stderr)")
        #expect(try git(tree.root, ["rev-list", "--count", "HEAD"]) == String(commits), "the test repository itself has the wrong number of commits")
        #expect(tree.generatedNumber == commits, "file:\n\(tree.generated ?? "<none>")")
    }

    // 05 § Script tests: "After one more commit and a second run, the file holds the number plus one. Running it twice on the same commit gives the same file."
    @Test func oneMoreCommitRaisesTheNumberByOneAndARerunOnTheSameCommitChangesNothing() throws {
        let tree = try ScriptTree.make(commits: 4)
        try tree.writeBuildNumber()
        let first = try #require(tree.generated)
        #expect(tree.generatedNumber == 4)
        try tree.writeBuildNumber()
        #expect(tree.generated == first, "a second run on the same commit changed the file")
        try tree.addCommit()
        try tree.writeBuildNumber()
        #expect(tree.generatedNumber == 5, "file:\n\(tree.generated ?? "<none>")")
    }

    // 04 § Version Numbers: "the number of commits on the checked-out branch" counted from HEAD, so an older commit that is checked out gives its own, lower count.
    @Test func aCheckedOutOlderCommitGivesItsOwnCount() throws {
        let tree = try ScriptTree.make(commits: 5)
        try git(tree.root, ["checkout", "-q", "--detach", "HEAD~2"])
        try tree.writeBuildNumber()
        #expect(tree.generatedNumber == 3)
    }

    // 04 § Version Numbers and 05 § Script tests: "When git is not available, or the folder is not a git checkout, the script writes 0", and the exit code is 0.
    @Test func aFolderThatIsNotAGitCheckoutGetsZeroAndExitCodeZero() throws {
        let tree = try ScriptTree.make()
        let result = try tree.writeBuildNumber()
        #expect(result.status == 0 && !result.timedOut, "stderr: \(result.stderr)")
        #expect(tree.generatedNumber == 0, "file:\n\(tree.generated ?? "<none>")")
    }

    // A repository with no commit yet has nothing to count: the same answer as the no-git case, 0, without failing the build.
    @Test func aGitRepositoryWithoutCommitsGetsZero() throws {
        let tree = try ScriptTree.make(commits: 0)
        let result = try tree.writeBuildNumber()
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(tree.generatedNumber == 0)
    }

    // 04 § Version Numbers: "When git is not available ... the script writes 0". Here the checkout is real and has 6 commits, but git is not on the PATH (only dirname and cat are).
    @Test func whenGitIsNotOnThePathTheNumberIsZeroEvenInACheckout() throws {
        let tree = try ScriptTree.make(commits: 6)
        let tools = tree.root + "/tools"
        try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
        for name in ["dirname", "cat"] { try FileManager.default.createSymbolicLink(atPath: tools + "/" + name, withDestinationPath: "/usr/bin/" + name) }
        let result = try tree.writeBuildNumber(path: tools)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(tree.generatedNumber == 0, "file:\n\(tree.generated ?? "<none>")")
    }

    // 04 § Version Numbers: the file holds ONE declaration, `public let siteBlockBuildNumber = <build>`. Checked by compiling it for real (a parse with swiftc), not only by reading the text.
    @Test func theGeneratedFileIsValidSwiftWithOneDeclaration() throws {
        let tree = try ScriptTree.make(commits: 7)
        try tree.writeBuildNumber()
        let text = try #require(tree.generated)
        #expect(text.hasSuffix("public let siteBlockBuildNumber = 7\n"), "file:\n\(text)")
        let parsed = try runProgram("/usr/bin/swiftc", ["-parse", tree.buildNumberFile], timeout: 60)
        #expect(parsed.status == 0 && !parsed.timedOut, "swiftc said: \(parsed.stderr)")
    }

    // 05 § Script tests: the script runs on a copy, so the repository's own file is not overwritten: the real file keeps its identity (file and modification time) through a run of the copy.
    @Test func runningTheCopyDoesNotTouchTheRepositorysOwnGeneratedFile() throws {
        let real = repositoryRoot + "/Sources/SiteBlockCore/BuildNumber.swift"
        let before = identity(of: real)
        let bytes = FileManager.default.contents(atPath: real)
        let tree = try ScriptTree.make(commits: 2)
        try tree.writeBuildNumber()
        #expect(identity(of: real) == before)
        #expect(FileManager.default.contents(atPath: real) == bytes)
        #expect(tree.generatedNumber == 2)
    }

    // 04 § Version Numbers: "The file is generated and listed in `.gitignore`". 05: `git check-ignore Sources/SiteBlockCore/BuildNumber.swift` in the repository reports the file as ignored.
    @Test func gitIgnoresTheGeneratedFileInTheRepository() throws {
        let result = try runProgram("/usr/bin/git", ["-C", repositoryRoot, "check-ignore", "Sources/SiteBlockCore/BuildNumber.swift"], environment: gitEnvironment)
        #expect(result.status == 0, "git check-ignore exit \(result.status): \(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Sources/SiteBlockCore/BuildNumber.swift")
    }

    // 04 § Version Numbers: "Every program shows the version 1.0.<build>, where <build> is the number of commits". The programs built from this checkout (by scripts/test.sh, which runs the script first) show the checkout's commit count.
    @Test func theBuiltDaemonAndTheLibraryShowTheCheckoutsCommitCount() throws {
        let count = try git(repositoryRoot, ["rev-list", "--count", "HEAD"])
        #expect(siteBlockVersion == "1.0." + count, "the library says \(siteBlockVersion); run scripts/write-build-number.sh and rebuild")
        #expect(siteBlockBuildNumber == Int(count))
        let version = try runDaemonProgram(["--version"])
        #expect(version.status == 0)
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "siteblockd 1.0." + count, "got: \(version.stdout)")
    }
}

// The result of one real run of scripts/package.sh in a prepared copy.
private struct PackageRun {
    let tree: ScriptTree
    let result: ProgramResult
    var dist: String { tree.root + "/dist" }
    var zip: String { dist + "/SiteBlock.zip" }
    var versionFile: String { dist + "/version.json" }

    // The stand-in for scripts/build.sh: a tiny arm64 program per product (reporting the copy's own build number) in build/, signed ad hoc, laid out as the real build.sh does.
    private static let standInBuild = """
    #!/bin/bash
    set -euo pipefail
    cd "$(dirname "$0")/.."
    rm -rf build
    mkdir -p build/SiteBlock.app/Contents/MacOS
    # A tiny program compiled together with THIS tree's generated BuildNumber.swift (package.sh has just written it), so the version it prints is the tree's own, as the real daemon's is.
    mkdir -p "$TMPDIR_STANDIN"
    printf 'print("siteblockd 1.0.\\(siteBlockBuildNumber)")\\n' > "$TMPDIR_STANDIN/main.swift"
    swiftc -module-cache-path "$TMPDIR_STANDIN/cache" -o build/siteblockd "$TMPDIR_STANDIN/main.swift" Sources/SiteBlockCore/BuildNumber.swift
    cp build/siteblockd build/siteblock
    cp build/siteblockd build/SiteBlock.app/Contents/MacOS/SiteBlock
    printf '<?xml version="1.0" encoding="UTF-8"?>\\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>SiteBlock</string><key>CFBundleIdentifier</key><string>com.example.standin</string></dict></plist>\\n' > build/SiteBlock.app/Contents/Info.plist
    codesign --force -s - build/siteblockd build/siteblock build/SiteBlock.app
    """

    // Prepares a copy with the real package.sh, write-build-number.sh, install.sh and verify-install.sh and the stand-in build.sh. `commits` nil makes a folder that is not a git checkout.
    static func prepare(commits: Int?) throws -> ScriptTree {
        let tree = try ScriptTree.make(commits: commits, scripts: ["write-build-number.sh", "package.sh", "install.sh", "verify-install.sh"])
        try writeText(standInBuild + "\n", to: tree.root + "/scripts/build.sh")
        try chmodPath(tree.root + "/scripts/build.sh", 0o755)
        return tree
    }

    // Runs package.sh of the copy.
    static func run(in tree: ScriptTree) throws -> PackageRun {
        let result = try runProgram("/bin/bash", [tree.root + "/scripts/package.sh"], environment: gitEnvironment.merging(["TMPDIR_STANDIN": tree.root + "/standin"]) { _, new in new }, timeout: 180)
        return PackageRun(tree: tree, result: result)
    }

    static func make(commits: Int?) throws -> PackageRun { try run(in: try prepare(commits: commits)) }

    // The file's JSON object, or nil.
    var versionObject: [String: Any]? { readJSONObject(versionFile) as? [String: Any] }

    // The SHA-256 of the zip as `shasum -a 256` reports it.
    func shasumOfZip() throws -> String {
        let out = try runProgram("/usr/bin/shasum", ["-a", "256", zip])
        return out.stdout.split(separator: " ").first.map(String.init) ?? ""
    }
}

// One run in a git checkout with 3 commits and one in a folder that is not a checkout. Each is made once and only read by the tests, so the tests stay independent.
private let gitPackage = Result { try PackageRun.make(commits: 3) }
private let plainPackage = Result { try PackageRun.make(commits: nil) }

@Suite("Script tests: package.sh and version.json")
struct PackageScriptTests {
    // 04 § Packaging for Another Mac: package.sh "writes two files into dist/": SiteBlock.zip and version.json. The staging folder is removed.
    @Test func packageShSucceedsAndLeavesExactlyTheZipAndVersionJson() throws {
        let run = try gitPackage.get()
        #expect(run.result.status == 0 && !run.result.timedOut, "package.sh failed:\n\(run.result.stdout)\n\(run.result.stderr)")
        let listing = ((try? FileManager.default.contentsOfDirectory(atPath: run.dist)) ?? []).sorted()
        #expect(listing == ["SiteBlock.zip", "version.json"], "dist holds: \(listing)")
    }

    // 04: version.json has the five fields `version` (text), `build` (a number), `commit`, `asset` and `sha256` (text), and no others.
    @Test func versionJsonHasExactlyTheFiveDocumentedFieldsWithTheDocumentedTypes() throws {
        let run = try gitPackage.get()
        let object = try #require(run.versionObject, "version.json is not a JSON object")
        #expect(Set(object.keys) == ["version", "build", "commit", "asset", "sha256"])
        #expect(object["version"] is String && object["commit"] is String && object["asset"] is String && object["sha256"] is String)
        let build = try #require(object["build"] as? NSNumber, "build is not a number")
        #expect(CFGetTypeID(build) != CFBooleanGetTypeID(), "build is a boolean")
        #expect(object["asset"] as? String == "SiteBlock.zip")
    }

    // 05 § Script tests: "Its sha256 equals the SHA-256 of the zip it describes, as computed by shasum -a 256", written as 64 lowercase hexadecimal characters.
    @Test func theChecksumInVersionJsonIsTheShasumOfTheZip() throws {
        let run = try gitPackage.get()
        let written = try #require(run.versionObject?["sha256"] as? String)
        #expect(written == (try run.shasumOfZip()), "version.json says \(written)")
        #expect(written.count == 64 && written == written.lowercased())
    }

    // 05 § Script tests: UpdateCheck.parse accepts the file; its version is 1.0. followed by its build; its commit is the full hash `git rev-parse HEAD` reports. The version and build are those of the programs just built (the daemon's own --version).
    @Test func versionJsonIsAcceptedByParseAndNamesTheBuiltVersionAndTheCheckedOutCommit() throws {
        let run = try gitPackage.get()
        let data = try #require(FileManager.default.contents(atPath: run.versionFile))
        let info = try #require(UpdateCheck.parse(data), "UpdateCheck.parse rejected:\n\(String(data: data, encoding: .utf8) ?? "?")")
        #expect(info.version == "1.0.\(info.build)")
        #expect(info.build == Int(try git(run.tree.root, ["rev-list", "--count", "HEAD"])), "build must be the temp tree's commit count (3), not the build the test itself was compiled with")
        #expect(info.build == 3)
        #expect(info.commit == (try git(run.tree.root, ["rev-parse", "HEAD"])))
        #expect(info.asset == "SiteBlock.zip")
        let daemon = try runProgram(run.tree.root + "/build/siteblockd", ["--version"])
        #expect(daemon.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "siteblockd " + info.version, "daemon says: \(daemon.stdout)")
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

    // 04: "When git is not available, the build is 0 and the commit is 40 zeros." The checksum still describes the zip.
    @Test func withoutGitTheBuildIsZeroTheCommitIsFortyZerosAndParseRejectsTheFile() throws {
        let run = try plainPackage.get()
        #expect(run.result.status == 0 && !run.result.timedOut, "package.sh failed:\n\(run.result.stdout)\n\(run.result.stderr)")
        #expect(run.versionObject?["commit"] as? String == String(repeating: "0", count: 40))
        #expect(run.versionObject?["sha256"] as? String == (try run.shasumOfZip()))
        #expect(run.tree.generatedNumber == 0, "package.sh runs write-build-number.sh first; outside git it writes 0")
        // 04: "the build is 0 ... UpdateCheck.parse rejects a file whose build is 0, so a package made without git is never offered as an update."
        #expect((run.versionObject?["build"] as? NSNumber)?.intValue == 0 && run.versionObject?["version"] as? String == "1.0.0", "version.json: \(String(describing: run.versionObject))")
        let data = try #require(FileManager.default.contents(atPath: run.versionFile))
        #expect(UpdateCheck.parse(data) == nil, "a package built without git must not be accepted as an update")
    }

    // 04: "The version and build fields are those of the programs the script just built", and the commit/checksum follow the new commit and the new zip when package.sh runs again in the same folder.
    @Test func aSecondRunAfterAnotherCommitDescribesTheNewCommitAndTheNewZip() throws {
        let tree = try PackageRun.prepare(commits: 2)
        let first = try PackageRun.run(in: tree)
        try require(first.result.status == 0, "first run failed:\n\(first.result.stdout)\n\(first.result.stderr)")
        // Read now: both runs write the same dist/version.json, so the object must be captured before the second run replaces it.
        let firstCommit = first.versionObject?["commit"] as? String
        let firstBuild = (first.versionObject?["build"] as? NSNumber)?.intValue
        try tree.addCommit()
        let second = try PackageRun.run(in: tree)
        try require(second.result.status == 0, "second run failed:\n\(second.result.stdout)\n\(second.result.stderr)")
        let head = try git(tree.root, ["rev-parse", "HEAD"])
        #expect(firstBuild == 2)
        #expect((second.versionObject?["build"] as? NSNumber)?.intValue == 3 && second.versionObject?["version"] as? String == "1.0.3")
        #expect(second.versionObject?["commit"] as? String == head)
        #expect(second.versionObject?["commit"] as? String != firstCommit)
        #expect(second.versionObject?["sha256"] as? String == (try second.shasumOfZip()))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: second.dist)) ?? []).sorted() == ["SiteBlock.zip", "version.json"])
    }
}

// .github/workflows/package.yml read as text. Design: 04-infrastructure.md § Version Numbers and § Automatic Package Builds: the checkout fetches the full history (fetch-depth 0, otherwise every build is numbered 1),
// the workflow runs the tests and scripts/package.sh, and the release carries SiteBlock.zip and version.json.
@Suite("Script tests: package workflow")
struct PackageWorkflowTests {
    private static let text = readText(repositoryRoot + "/.github/workflows/package.yml") ?? ""

    // The lines of the workflow that are not comments.
    private static let code: [String] = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

    // The text of one step (from its "- name:" line to the next step), found by a fragment of its `uses:` or `run:` line.
    private func step(containing fragment: String) -> String? {
        var steps: [[String]] = []
        for line in Self.code {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- name:") { steps.append([line]) } else if !steps.isEmpty { steps[steps.count - 1].append(line) }
        }
        return steps.map { $0.joined(separator: "\n") }.first { $0.contains(fragment) }
    }

    @Test func theWorkflowFileExists() { #expect(!Self.text.isEmpty) }

    @Test func theCheckoutStepFetchesTheFullHistory() throws {
        let checkout = try #require(step(containing: "actions/checkout"), "no checkout step")
        #expect(checkout.contains("fetch-depth: 0"), "checkout step:\n\(checkout)")
    }

    @Test func theWorkflowRunsTheTestsAndThenThePackageScript() throws {
        let tests = try #require(step(containing: "scripts/test.sh"), "no step runs scripts/test.sh")
        let package = try #require(step(containing: "scripts/package.sh"), "no step runs scripts/package.sh")
        let all = Self.code.joined(separator: "\n")
        let testsAt = try #require(all.range(of: tests)?.lowerBound)
        let packageAt = try #require(all.range(of: package)?.lowerBound)
        #expect(testsAt < packageAt, "the tests must run before the package is built, so a failing test stops the publish")
    }

    @Test func theReleaseStepUploadsBothFilesFromDist() throws {
        let release = try #require(step(containing: "gh release create"), "no step creates the release")
        #expect(release.contains("dist/SiteBlock.zip") && release.contains("dist/version.json"), "release step:\n\(release)")
        #expect(release.contains("latest"), "the release must be the one tagged latest")
    }
}

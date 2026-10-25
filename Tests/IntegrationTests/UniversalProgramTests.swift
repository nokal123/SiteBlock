import Foundation
import Testing

// Tests for universal Mac programs (a copy for Apple chips, arm64, and one for Intel processors, x86_64, in each file): package.sh's refusal of a program missing either copy,
// install.sh's step-1 check of this Mac's processor family and macOS version, and the Rosetta steps of .github/workflows/package.yml, the workflow steps run for real.
// Expected values come from Design Plans/04-infrastructure.md § Build Script, § Install Script, § Packaging for Another Mac and § Automatic Package Builds, and
// 05-testing-and-operations.md § Integration Tests (Script tests):
// - package.sh exits non-zero, writes no zip, and says "is not built for Apple chips (arm64)" or "is not built for Intel processors (x86_64)" for a program missing that copy.
//   INSTALL.txt says the Mac needs "an Apple chip or an Intel processor, macOS 14 (Sonoma) or newer".
// - install.sh step 1 prints "this Mac: an Apple chip (arm64), macOS <v>" or "this Mac: an Intel processor (x86_64), macOS <v>". Before step 2 it exits 1 with an "error:" line
//   when macOS is older than 14 (naming the version and Software Update), or when any of the three programs has no copy for this Mac's family (naming the program, what it is
//   built for, and https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip). The family is arm64 when `sysctl -n hw.optional.arm64` prints 1, else
//   x86_64; the version comes from `sw_vers -productVersion`; an arm64e copy is not an arm64 copy. On success it prints "the programs have a copy for this Mac's processor".
//   Only in --dry-run do SITEBLOCK_TEST_MAC_ARCH and SITEBLOCK_TEST_MACOS_VERSION stand in for the family and the version.
//
// The programs the installer tests read are tiny real Mach-O files (the executable format macOS runs) compiled with clang for each target and joined with lipo, so the
// installer's own `file -b` reads real program headers. A real install needs root, so "a real run never reads the test variables" is checked by running the installer's two
// lookup functions on their own with the dry-run flag off, plus a text check that nothing else in the script reads the variables.

// The download link every installer refusal must name.
private let downloadLink = "https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip"

// The PATH the installer and the workflow steps get: the folders a Mac's own shell has, so /usr/sbin/sysctl is found.
private let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

// The three programs the installer checks, as paths under the package folder.
private let programPaths = ["build/siteblockd", "build/siteblock", "build/SiteBlock.app/Contents/MacOS/SiteBlock"]

// What a tiny test program holds. Each case names the processor families of the copies inside it; `notAProgram` is a text file.
enum ProgramKind: String, CaseIterable, Sendable {
    case universal, arm64Only, x86_64Only, arm64eOnly, arm64eAndX86_64, notAProgram

    // The families of the copies inside, as lipo names them, or nil for a file that is not a program.
    var families: Set<String>? {
        switch self {
        case .universal: ["arm64", "x86_64"]
        case .arm64Only: ["arm64"]
        case .x86_64Only: ["x86_64"]
        case .arm64eOnly: ["arm64e"]
        case .arm64eAndX86_64: ["arm64e", "x86_64"]
        case .notAProgram: nil
        }
    }

    // The design's rule: a program serves a Mac when it holds a copy for exactly that Mac's family (arm64e does not count as arm64).
    func serves(_ family: String) -> Bool { families?.contains(family) ?? false }
}

// A tiny C program: `--version` prints "stand-in <family of the copy that ran>", and `--print-plist <job>` prints a small valid plist, or "not a plist" when
// $STANDIN_BAD_PLIST names that job. It stands in for siteblockd and siteblock in the workflow step that runs the packaged Intel copies.
private let standInProgramSource = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
#if defined(__x86_64__)
    const char *family = "x86_64";
#elif defined(__arm64e__)
    const char *family = "arm64e";
#else
    const char *family = "arm64";
#endif
    if (argc > 1 && strcmp(argv[1], "--version") == 0) { printf("stand-in %s\\n", family); return 0; }
    if (argc > 2 && strcmp(argv[1], "--print-plist") == 0) {
        const char *bad = getenv("STANDIN_BAD_PLIST");
        if (bad && strcmp(bad, argv[2]) == 0) { printf("not a plist\\n"); return 0; }
        printf("<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>\\n<plist version=\\"1.0\\"><dict><key>Label</key><string>%s</string></dict></plist>\\n", argv[2]);
        return 0;
    }
    return 2;
}

"""

// One file of each ProgramKind, built once per test run: clang compiles the program for arm64, x86_64 and arm64e (macOS 14), and lipo joins the universal ones.
private let programFixtures = Result { () throws -> [ProgramKind: String] in
    let folder = try makeTemporaryFolder("/tmp/sbs-macho-")
    try writeText(standInProgramSource, to: folder + "/main.c")
    for family in ["arm64", "x86_64", "arm64e"] {
        let compiled = try runProgram("/usr/bin/clang", ["-target", "\(family)-apple-macosx14.0", "-o", folder + "/thin-" + family, folder + "/main.c"], timeout: 120)
        try require(compiled.status == 0 && !compiled.timedOut, "clang for \(family) failed (\(compiled.status)): \(compiled.stderr)")
    }
    for (name, parts) in [("universal", ["arm64", "x86_64"]), ("arm64e-x86_64", ["arm64e", "x86_64"])] {
        let joined = try runProgram("/usr/bin/lipo", ["-create"] + parts.map { folder + "/thin-" + $0 } + ["-output", folder + "/" + name])
        try require(joined.status == 0, "lipo -create \(parts) failed: \(joined.stderr)")
    }
    try writeText("#!/bin/sh\necho this is a shell script, not a program built for any processor\n", to: folder + "/text")
    try chmodPath(folder + "/text", 0o755)
    let names: [ProgramKind: String] = [.universal: "universal", .arm64Only: "thin-arm64", .x86_64Only: "thin-x86_64", .arm64eOnly: "thin-arm64e", .arm64eAndX86_64: "arm64e-x86_64", .notAProgram: "text"]
    return names.mapValues { folder + "/" + $0 }
}

// The families lipo reports for a file, or nil when lipo cannot read it as a program.
private func lipoFamilies(_ path: String) throws -> Set<String>? {
    let result = try runProgram("/usr/bin/lipo", ["-archs", path])
    guard result.status == 0 else { return nil }
    return Set(result.stdout.split(whereSeparator: \.isWhitespace).map(String.init))
}

// Copies the real scripts/install.sh into a new folder laid out as the unzipped package (scripts/install.sh, build/siteblockd, build/siteblock, build/SiteBlock.app) with the
// three programs of the given kinds, in the order siteblockd, siteblock, app. `parent` puts the folder somewhere other than /tmp (for example a path with a space).
private func makePackageFolder(_ kinds: [ProgramKind], under parent: String? = nil) throws -> String {
    try require(kinds.count == 3, "three program kinds are needed")
    let fixtures = try programFixtures.get()
    let root = try parent.map { parent -> String in
        let path = parent + "/package"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    } ?? makeTemporaryFolder("/tmp/sbs-pkg-")
    for folder in ["scripts", "build/SiteBlock.app/Contents/MacOS"] { try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true) }
    try FileManager.default.copyItem(atPath: repositoryRoot + "/scripts/install.sh", toPath: root + "/scripts/install.sh")
    try chmodPath(root + "/scripts/install.sh", 0o755)
    for (path, kind) in zip(programPaths, kinds) {
        try FileManager.default.copyItem(atPath: try #require(fixtures[kind]), toPath: root + "/" + path)
        try chmodPath(root + "/" + path, 0o755)
    }
    return root
}

// Writes small stand-in commands (name → bash script text) into a new folder and returns it, for putting first on the PATH.
private func makeStubFolder(_ stubs: [String: String]) throws -> String {
    let folder = try makeTemporaryFolder("/tmp/sbs-stub-")
    for (name, script) in stubs {
        try writeText("#!/bin/bash\n" + script + "\n", to: folder + "/" + name)
        try chmodPath(folder + "/" + name, 0o755)
    }
    return folder
}

// One `scripts/install.sh --dry-run` run of a package folder.
private struct InstallerRun {
    let result: ProgramResult
    var outLines: [String] { result.stdout.components(separatedBy: "\n") }
    var errorLines: [String] { result.stderr.components(separatedBy: "\n").filter { $0.hasPrefix("error:") } }
    var describe: String { "exit \(result.status)\n--- stdout\n\(result.stdout)\n--- stderr\n\(result.stderr)" }

    // Runs the copied installer directly (so its own #! line and run permission are used) with --dry-run. A nil `arch` or `version` leaves that test variable unset, so the
    // installer asks sysctl or sw_vers (which `stubs` may replace).
    static func run(_ kinds: [ProgramKind], arch: String?, version: String?, stubs: [String: String] = [:], under parent: String? = nil) throws -> InstallerRun {
        let root = try makePackageFolder(kinds, under: parent)
        var environment = ["PATH": (stubs.isEmpty ? "" : try makeStubFolder(stubs) + ":") + systemPath]
        if let arch { environment["SITEBLOCK_TEST_MAC_ARCH"] = arch }
        if let version { environment["SITEBLOCK_TEST_MACOS_VERSION"] = version }
        return try launch(root, environment: environment)
    }

    // Runs `scripts/install.sh --dry-run` of an already prepared package folder with exactly the given environment (runProgram passes nothing else). Normally the copied
    // installer runs directly; `underRosetta` instead runs `arch -x86_64 /bin/bash scripts/install.sh --dry-run` from inside the folder, as the design's Rosetta case.
    static func launch(_ root: String, environment: [String: String], underRosetta: Bool = false) throws -> InstallerRun {
        if underRosetta { return InstallerRun(result: try runProgram("/bin/bash", ["-c", "cd \"$1\" || exit 99; exec /usr/bin/arch -x86_64 /bin/bash scripts/install.sh --dry-run", "bash", root], environment: environment, timeout: 120)) }
        return InstallerRun(result: try runProgram(root + "/scripts/install.sh", ["--dry-run"], environment: environment, timeout: 60))
    }

    // The position of the first stdout line that starts with the prefix.
    func index(startingWith prefix: String) -> Int? { outLines.firstIndex { $0.hasPrefix(prefix) } }

    // The line step 1 must print for this family and version.
    static func macLine(_ family: String, _ version: String) -> String { "this Mac: \(family == "arm64" ? "an Apple chip" : "an Intel processor") (\(family)), macOS \(version)" }

    // A refusal as the design wants it: exit code 1, at least one "error:" line, and nothing from step 2 on (no step 2 heading and no dry-run action).
    func expectRefusedBeforeStep2(_ context: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.status == 1 && !result.timedOut, "\(context): expected exit code 1; \(describe)", sourceLocation: sourceLocation)
        #expect(!errorLines.isEmpty, "\(context): expected an 'error:' line on stderr; \(describe)", sourceLocation: sourceLocation)
        #expect(index(startingWith: "==> Step 2") == nil && !outLines.contains { $0.hasPrefix("[dry-run]") }, "\(context): the installer went past step 1; \(describe)", sourceLocation: sourceLocation)
    }

    // A pass as the design wants it: exit 0, the "this Mac" line and then the pass line, both in step 1, and the dry run going on to step 2.
    func expectPassed(_ family: String, _ version: String, _ context: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.status == 0 && !result.timedOut, "\(context): expected exit 0; \(describe)", sourceLocation: sourceLocation)
        #expect(errorLines.isEmpty, "\(context): \(describe)", sourceLocation: sourceLocation)
        let step1 = index(startingWith: "==> Step 1"), mac = outLines.firstIndex(of: Self.macLine(family, version))
        let passed = outLines.firstIndex(of: "the programs have a copy for this Mac's processor"), step2 = index(startingWith: "==> Step 2")
        #expect(mac != nil && passed != nil, "\(context): expected '\(Self.macLine(family, version))' and the pass line; \(describe)", sourceLocation: sourceLocation)
        if let step1, let mac, let passed, let step2 { #expect(step1 < mac && mac < passed && passed < step2, "\(context): lines out of order; \(describe)", sourceLocation: sourceLocation) }
        else { Issue.record("\(context): a step heading is missing; \(describe)", sourceLocation: sourceLocation) }
    }
}

// This Mac's processor family and macOS version as the design defines them, asked here directly: arm64 when `/usr/sbin/sysctl -n hw.optional.arm64` prints 1, else x86_64,
// and `sw_vers -productVersion`. hw.optional.arm64 is 1 on an Apple chip even when this test process runs translated by Rosetta (the Intel test run), so the answer there
// is still arm64, which is what the design wants the installer to say too.
private func thisMac() throws -> (family: String, version: String) {
    let sysctl = try runProgram("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"])
    let family = sysctl.status == 0 && sysctl.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "arm64" : "x86_64"
    return (family, try runProgram("/usr/bin/sw_vers", ["-productVersion"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
}

// True on a Mac with an Apple chip where Rosetta can run an Intel program. The Rosetta installer test needs both: an Intel Mac has nothing to translate, and without
// Rosetta `arch -x86_64` cannot start anything.
private let appleChipWithRosetta: Bool = {
    guard let mac = try? thisMac(), mac.family == "arm64" else { return false }
    return (try? runProgram("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]))?.status == 0
}()

// True when the text names the program path as a whole (so "build/siteblock" is not found inside "build/siteblockd").
private func names(_ path: String, in text: String) -> Bool {
    text.range(of: NSRegularExpression.escapedPattern(for: path) + "($|[^A-Za-z0-9_./])", options: .regularExpression) != nil
}

@Suite("Universal programs: test fixtures")
struct ProgramFixtureTests {
    // The installer tests are only as good as their programs: each fixture must hold exactly the copies its kind claims, or a refusal test could pass for the wrong reason.
    @Test(arguments: ProgramKind.allCases)
    func eachFixtureHoldsExactlyTheCopiesItsKindNames(kind: ProgramKind) throws {
        let path = try #require(try programFixtures.get()[kind])
        #expect(try lipoFamilies(path) == kind.families, "lipo -archs \(path)")
    }
}

// install.sh step 1 against universal, arm64-only and x86_64-only programs, acting out each family and four macOS versions.
@Suite("Universal programs: install.sh checks this Mac in step 1")
struct InstallerMacCheckTests {
    // 04 § Install Script: macOS older than 14 stops the install (naming the version and Software Update). A version that does not start with a number cannot be shown to
    // be 14 or newer, so it is refused too (the design does not name this case; see the report). With a supported version, the programs decide: a missing copy for the
    // family stops the install, and programs with that copy pass. In every case step 1 first prints the "this Mac" line.
    @Test(arguments: [ProgramKind.universal, .arm64Only, .x86_64Only], ["arm64", "x86_64"].flatMap { family in ["13.7", "14.0", "26.5", "junk"].map { (family, $0) } })
    func theInstallerPassesOnlyASupportedMacOSWithACopyForThisFamily(kind: ProgramKind, mac: (family: String, version: String)) throws {
        let (family, version) = mac
        let run = try InstallerRun.run([kind, kind, kind], arch: family, version: version)
        let context = "\(kind.rawValue) programs, \(family), macOS \(version)"
        #expect(run.outLines.contains(InstallerRun.macLine(family, version)), "\(context): \(run.describe)")
        let supported = version == "14.0" || version == "26.5"
        if !supported {
            run.expectRefusedBeforeStep2(context)
            if kind.serves(family) {
                #expect(run.errorLines.contains { $0.contains(version) }, "\(context): the refusal must name the version; \(run.describe)")
                #expect(run.errorLines.contains { $0.contains("Software Update") }, "\(context): the refusal must point to Software Update; \(run.describe)")
            }
        } else if kind.serves(family) {
            run.expectPassed(family, version, context)
        } else {
            run.expectRefusedBeforeStep2(context)
            #expect(run.errorLines.contains { $0.contains(downloadLink) }, "\(context): the refusal must give the download link; \(run.describe)")
        }
    }

    // One program at a time lacks this Mac's copy (it holds only the other family's), while the other two are universal: the refusal names that program and no other,
    // says what it is built for, and gives the download link.
    @Test(arguments: [0, 1, 2], ["arm64", "x86_64"])
    func aSingleProgramWithoutThisFamilysCopyIsRefusedByName(position: Int, family: String) throws {
        let other: ProgramKind = family == "arm64" ? .x86_64Only : .arm64Only
        var kinds: [ProgramKind] = [.universal, .universal, .universal]
        kinds[position] = other
        let run = try InstallerRun.run(kinds, arch: family, version: "26.5")
        let context = "\(programPaths[position]) holds only \(other.rawValue), Mac is \(family)"
        run.expectRefusedBeforeStep2(context)
        let refusal = run.errorLines.joined(separator: "\n")
        #expect(names(programPaths[position], in: refusal), "\(context): the refusal must name the program; \(run.describe)")
        for (index, path) in programPaths.enumerated() where index != position { #expect(!names(path, in: refusal), "\(context): the refusal also names \(path), which holds both copies; \(run.describe)") }
        #expect(refusal.contains(other.families!.first!), "\(context): the refusal must say what the program is built for; \(run.describe)")
        #expect(refusal.contains(downloadLink), "\(context): the refusal must give the download link; \(run.describe)")
    }

    // 04: "the pattern `executable arm64` must not match `arm64e`". A program with only an arm64e copy serves no Mac family; one with arm64e and x86_64 serves only an Intel
    // Mac. A text file is not a program for any family.
    @Test(arguments: [ProgramKind.arm64eOnly, .arm64eAndX86_64, .notAProgram], ["arm64", "x86_64"])
    func arm64eCopiesAndNonProgramsDoNotCountAsACopyForTheMac(kind: ProgramKind, family: String) throws {
        let run = try InstallerRun.run([kind, kind, kind], arch: family, version: "26.5")
        let context = "\(kind.rawValue) programs on \(family)"
        if kind.serves(family) { run.expectPassed(family, "26.5", context) } else {
            run.expectRefusedBeforeStep2(context)
            #expect(run.errorLines.contains { $0.contains(downloadLink) }, "\(context): \(run.describe)")
        }
    }

    // A refusal must stand out even when the package folder's path has a space and non-ASCII letters (where the user unzipped it), and a pass must still pass.
    @Test func aPackageFolderWithASpaceAndNonASCIILettersIsCheckedTheSameWay() throws {
        let parent = try makeTemporaryFolder("/tmp/sbs-space-") + "/Mes Téléchargements/SiteBlock 2"
        let passed = try InstallerRun.run([.universal, .universal, .universal], arch: "x86_64", version: "15.4", under: parent + "/a")
        passed.expectPassed("x86_64", "15.4", "universal programs under a path with a space")
        let refused = try InstallerRun.run([.universal, .arm64Only, .universal], arch: "x86_64", version: "15.4", under: parent + "/b")
        refused.expectRefusedBeforeStep2("arm64-only siteblock under a path with a space")
        #expect(names("build/siteblock", in: refused.errorLines.joined(separator: "\n")), "\(refused.describe)")
    }
}

// Without the test variables the installer must ask the Mac itself: sysctl for the family and sw_vers for the version. Stand-in sysctl and sw_vers commands first on the
// PATH act out each answer. The programs hold only an arm64 copy, so the family decides whether the check passes.
@Suite("Universal programs: install.sh asks sysctl and sw_vers")
struct InstallerMacDetectionTests {
    // 04: arm64 when `sysctl -n hw.optional.arm64` prints 1; x86_64 otherwise, including on an Intel Mac, where the name does not exist and sysctl fails.
    @Test(arguments: [("echo 1", "arm64"), ("echo 0", "x86_64"), ("echo \"sysctl: unknown oid 'hw.optional.arm64'\" >&2; exit 1", "x86_64")])
    func theFamilyComesFromHwOptionalArm64(sysctl body: String, family: String) throws {
        // The stand-in answers only the one question the design names; any other question fails, so a different lookup cannot pass by accident.
        let sysctl = "if [ \"$*\" = \"-n hw.optional.arm64\" ]; then \(body); else echo \"unexpected sysctl $*\" >&2; exit 64; fi"
        let run = try InstallerRun.run([.arm64Only, .arm64Only, .arm64Only], arch: nil, version: "26.5", stubs: ["sysctl": sysctl])
        #expect(run.outLines.contains(InstallerRun.macLine(family, "26.5")), "\(run.describe)")
        if family == "arm64" { run.expectPassed(family, "26.5", "sysctl \(body)") } else { run.expectRefusedBeforeStep2("sysctl \(body)") }
    }

    // 04: the version comes from `sw_vers -productVersion`.
    @Test(arguments: [("13.6.1", false), ("15.4", true)])
    func theVersionComesFromSwVers(version: String, supported: Bool) throws {
        let swVers = "if [ \"$*\" = \"-productVersion\" ]; then echo \(version); else echo \"unexpected sw_vers $*\" >&2; exit 64; fi"
        let run = try InstallerRun.run([.universal, .universal, .universal], arch: "arm64", version: nil, stubs: ["sw_vers": swVers])
        if supported { run.expectPassed("arm64", version, "sw_vers \(version)") } else {
            run.expectRefusedBeforeStep2("sw_vers \(version)")
            #expect(run.errorLines.contains { $0.contains(version) }, "\(run.describe)")
        }
    }
}

// 04 § Install Script: the program check reads each program with `file -b` and not with `lipo`, because on a Mac without developer tools /usr/bin/lipo opens an "install
// developer tools" window and fails. Stand-in `lipo` and `xcrun` commands first on the PATH act out that Mac: each records its call and exits 1. The installer must reach
// the same verdict as on a Mac with developer tools, and call neither.
@Suite("Universal programs: install.sh never runs lipo")
struct InstallerWithoutDeveloperToolsTests {
    // Writes the two failing stand-ins into a new folder and returns it with the log file every call is appended to ("<name> <arguments>" per line).
    private static func failingDeveloperTools() throws -> (folder: String, log: String) {
        let log = try makeTemporaryFolder("/tmp/sbs-devtools-") + "/calls.log"
        let body = "printf '%s %s\\n' \"$(basename \"$0\")\" \"$*\" >> '\(log)'\necho 'xcode-select: note: No developer tools were found, requesting install.' >&2\nexit 1"
        return (try makeStubFolder(["lipo": body, "xcrun": body]), log)
    }

    // For each family: universal programs still pass, and a siteblock that holds only the other family's copy is still refused, by name, with what it is built for and the
    // download link. Neither run may call lipo or xcrun.
    @Test(arguments: ["arm64", "x86_64"])
    func theProgramCheckGivesTheSameVerdictWithoutCallingLipoOrXcrun(family: String) throws {
        let tools = try Self.failingDeveloperTools()
        let path = tools.folder + ":" + systemPath
        // Control: the stand-ins are what a bare `lipo` or `xcrun` finds on this PATH, and they do record, so an empty log below means they were never called.
        let probe = try runProgram("/bin/bash", ["-c", "lipo -archs probe; xcrun --find lipo; exit 0"], environment: ["PATH": path])
        try require(probe.status == 0 && readText(tools.log) == "lipo -archs probe\nxcrun --find lipo\n", "the stand-ins did not record: \(readText(tools.log) ?? "<no log>")")
        try FileManager.default.removeItem(atPath: tools.log)

        let environment = ["PATH": path, "SITEBLOCK_TEST_MAC_ARCH": family, "SITEBLOCK_TEST_MACOS_VERSION": "26.5"]
        let passed = try InstallerRun.launch(try makePackageFolder([.universal, .universal, .universal]), environment: environment)
        passed.expectPassed(family, "26.5", "universal programs, \(family), no developer tools")

        let other: ProgramKind = family == "arm64" ? .x86_64Only : .arm64Only
        let refused = try InstallerRun.launch(try makePackageFolder([.universal, other, .universal]), environment: environment)
        refused.expectRefusedBeforeStep2("\(other.rawValue) siteblock, \(family), no developer tools")
        let refusal = refused.errorLines.joined(separator: "\n")
        #expect(names("build/siteblock", in: refusal) && !names("build/siteblockd", in: refusal), "the refusal must name build/siteblock alone; \(refused.describe)")
        #expect(refusal.contains(other.families!.first!) && refusal.contains(downloadLink), "the refusal must say what siteblock is built for and give the link; \(refused.describe)")

        #expect(readText(tools.log) == nil, "the installer called a developer tool:\n\(readText(tools.log) ?? "")")
    }
}

// 04 § Install Script: "a run started with a short PATH still finds sysctl and does not take an Apple chip for an Intel processor", and the Rosetta note: the family is arm64
// when hw.optional.arm64 is 1, "which is also true when the script itself runs translated by Rosetta". Both tests use the real sysctl and sw_vers and no test variables, and
// programs that hold only this Mac's copy, so a wrong family would also turn the pass into a refusal.
@Suite("Universal programs: install.sh finds this Mac's family with a short PATH and under Rosetta")
struct InstallerRealMacTests {
    // The environment is exactly PATH=/usr/bin:/bin. On an Intel Mac a missed sysctl gives the same answer (x86_64), so only an Apple-chip Mac can catch that mistake.
    @Test func aDryRunWithOnlyUsrBinAndBinOnThePathStillNamesThisMacsFamily() throws {
        // Control: sysctl really is outside /usr/bin and /bin, so the installer can only find it through the folders it adds itself.
        try require(!FileManager.default.fileExists(atPath: "/usr/bin/sysctl") && !FileManager.default.fileExists(atPath: "/bin/sysctl"), "sysctl is in /usr/bin or /bin here, so this test proves nothing")
        let mac = try thisMac()
        let only: ProgramKind = mac.family == "arm64" ? .arm64Only : .x86_64Only
        let run = try InstallerRun.launch(try makePackageFolder([only, only, only]), environment: ["PATH": "/usr/bin:/bin"])
        run.expectPassed(mac.family, mac.version, "PATH=/usr/bin:/bin, real sysctl, \(only.rawValue) programs")
    }

    // `arch -x86_64 /bin/bash scripts/install.sh --dry-run` on an Apple chip: the installer runs as an Intel program, yet must still call this Mac an Apple chip and accept
    // programs that hold only an arm64 copy. When this test process is itself translated (the Intel test run), everything it starts is translated as well, and the expected
    // answer is the same.
    @Test(.enabled(if: appleChipWithRosetta, "needs a Mac with an Apple chip and Rosetta: an Intel Mac has nothing to translate, and without Rosetta arch -x86_64 cannot run"))
    func aDryRunTranslatedByRosettaStillCallsThisMacAnAppleChip() throws {
        // Control: a shell started the same way really runs translated.
        let translated = try runProgram("/usr/bin/arch", ["-x86_64", "/bin/bash", "-c", "/usr/sbin/sysctl -n sysctl.proc_translated"])
        try require(translated.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "arch -x86_64 /bin/bash did not run translated: \(translated.stdout) \(translated.stderr)")
        let mac = try thisMac()
        let run = try InstallerRun.launch(try makePackageFolder([.arm64Only, .arm64Only, .arm64Only]), environment: ["PATH": systemPath], underRosetta: true)
        run.expectPassed("arm64", mac.version, "install.sh under arch -x86_64, arm64-only programs")
    }
}

// "In --dry-run only, SITEBLOCK_TEST_MAC_ARCH and SITEBLOCK_TEST_MACOS_VERSION stand in; a real install never reads them." A real install needs root, so these tests run the
// installer's own lookup code with the dry-run flag off and on, and check that nothing else in the script reads the variables.
@Suite("Universal programs: a real install ignores the test variables")
struct InstallerTestVariableTests {
    private static let script = readText(repositoryRoot + "/scripts/install.sh") ?? ""
    private static let variables = ["SITEBLOCK_TEST_MAC_ARCH", "SITEBLOCK_TEST_MACOS_VERSION"]

    // The script's shell functions whose bodies mention a test variable, each as its full text from the "name() {" line to its closing "}" line.
    private static func functionsReadingTheVariables() -> [(name: String, lines: Range<Int>)] {
        let lines = script.components(separatedBy: "\n")
        var found: [(String, Range<Int>)] = []
        var start: Int? = nil
        for (index, line) in lines.enumerated() {
            if start == nil, line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{$"#, options: .regularExpression) != nil { start = index }
            else if let begin = start, line == "}" {
                if lines[begin...index].contains(where: { text in variables.contains { text.contains($0) } }) { found.append((String(lines[begin].prefix { $0 != "(" }), begin..<(index + 1))) }
                start = nil
            }
        }
        return found
    }

    // Every line outside comments that mentions a test variable lies inside a function whose behaviour the next test checks, so no other line of a real run can read them.
    @Test func onlyTheFamilyAndVersionLookupsMentionTheTestVariables() throws {
        let lines = Self.script.components(separatedBy: "\n")
        let functions = Self.functionsReadingTheVariables()
        #expect(!functions.isEmpty, "no function mentions the test variables")
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") && Self.variables.contains(where: { line.contains($0) }) {
            #expect(functions.contains { $0.lines.contains(index) }, "line \(index + 1) reads a test variable outside the lookup functions: \(line)")
        }
    }

    // Each lookup function, run on its own: with DRY_RUN=1 it returns the test variable (the control, so the check below cannot pass by never reading it), and with DRY_RUN=0
    // it returns what this Mac really says, computed here from sysctl and sw_vers, even though the variables are set to the opposite family and an old macOS.
    @Test func theLookupsReturnTheTestValuesOnlyInADryRun() throws {
        let functions = Self.functionsReadingTheVariables()
        let lines = Self.script.components(separatedBy: "\n")
        let definitions = functions.map { lines[$0.lines].joined(separator: "\n") }.joined(separator: "\n")
        let (realFamily, realVersion) = try thisMac()
        let fakeFamily = realFamily == "arm64" ? "x86_64" : "arm64"
        let environment = ["PATH": systemPath, "SITEBLOCK_TEST_MAC_ARCH": fakeFamily, "SITEBLOCK_TEST_MACOS_VERSION": "13.0"]
        var answers: [Int: [String]] = [:]
        for dryRun in [0, 1] {
            let calls = functions.map(\.name).joined(separator: "; ")
            let result = try runProgram("/bin/bash", ["-c", "set -euo pipefail; DRY_RUN=\(dryRun)\n\(definitions)\n\(calls)"], environment: environment)
            try require(result.status == 0, "the lookups failed with DRY_RUN=\(dryRun): \(result.stderr)")
            answers[dryRun] = result.stdout.split(separator: "\n").map(String.init).sorted()
        }
        #expect(answers[1] == ["13.0", fakeFamily].sorted(), "a dry run must use the test variables: \(answers[1] ?? [])")
        #expect(answers[0] == [realVersion, realFamily].sorted(), "a real run must ask the Mac (\(realFamily), \(realVersion)): \(answers[0] ?? [])")
    }
}

@Suite("Universal programs: package.sh")
struct UniversalPackageTests {
    // The stand-in build must make what the real build makes, so the packaging tests exercise package.sh's real check: three programs, each with exactly the two copies, and
    // the zip keeps both copies and the signatures.
    @Test func theStandInBuildAndThePackagedProgramsAreUniversalAndSigned() throws {
        let run = try gitPackage.get()
        try require(run.result.status == 0, "package.sh failed:\n\(run.result.stdout)\n\(run.result.stderr)")
        for path in programPaths { #expect(try lipoFamilies(run.tree.root + "/" + path) == ["arm64", "x86_64"], "\(path) in build/") }
        let unzipped = try makeTemporaryFolder()
        let extracted = try runProgram("/usr/bin/ditto", ["-x", "-k", run.zip, unzipped])
        try require(extracted.status == 0, "ditto -x failed: \(extracted.stderr)")
        for path in programPaths {
            #expect(try lipoFamilies(unzipped + "/SiteBlock/" + path) == ["arm64", "x86_64"], "\(path) in the zip")
        }
        for path in ["build/siteblockd", "build/siteblock", "build/SiteBlock.app"] {
            let verified = try runProgram("/usr/bin/codesign", ["--verify", "--strict", unzipped + "/SiteBlock/" + path])
            #expect(verified.status == 0, "codesign --verify \(path) in the zip: \(verified.stderr)")
        }
    }

    // 04 § Packaging for Another Mac: a program missing either copy stops package.sh with the matching message, and no zip is written.
    @Test(arguments: ["siteblockd", "siteblock", "SiteBlock.app/Contents/MacOS/SiteBlock"], ["arm64", "x86_64"])
    func aProgramWithOnlyOneFamilysCopyIsRefusedAndNoZipIsWritten(program: String, kept: String) throws {
        let tree = try PackageRun.prepare(commits: 1, buildNumber: 7)
        let run = try PackageRun.run(in: tree, thin: "\(program):\(kept)")
        let context = "build/\(program) holds only \(kept)"
        try require(!run.result.timedOut, "\(context): package.sh timed out")
        // The stand-in really thinned the program; otherwise this test proves nothing.
        try require(try lipoFamilies(tree.root + "/build/" + program) == [kept], "\(context): the stand-in did not thin the program")
        let message = kept == "arm64" ? "is not built for Intel processors (x86_64)" : "is not built for Apple chips (arm64)"
        #expect(run.result.status != 0, "\(context): package.sh must fail; stdout:\n\(run.result.stdout)")
        #expect(run.result.stderr.contains(message), "\(context): expected '\(message)'; stderr:\n\(run.result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: run.zip), "\(context): a zip was written")
    }

    // 04: INSTALL.txt states the requirement as "a Mac with an Apple chip or an Intel processor, macOS 14 (Sonoma) or newer". Line breaks in the file are read as spaces.
    @Test func installTxtNamesBothProcessorFamiliesAndMacOS14() throws {
        let run = try gitPackage.get()
        let text = try runProgram("/usr/bin/unzip", ["-p", run.zip, "SiteBlock/INSTALL.txt"]).stdout
        let flowing = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flowing.contains("a Mac with an Apple chip or an Intel processor, macOS 14 (Sonoma) or newer"), "INSTALL.txt:\n\(text)")
        #expect(!flowing.contains("M1 or newer"), "INSTALL.txt still names Apple chips only:\n\(text)")
    }
}

// Runs one named step of package.yml for real: its `run:` script with `bash -e` (GitHub's default shell) inside `tree`, with the given environment.
private func runWorkflowStep(_ name: String, in tree: String, environment: [String: String], timeout: Double = 120) throws -> ProgramResult {
    let steps = workflowSteps(readText(repositoryRoot + "/.github/workflows/package.yml") ?? "")
    let step = try #require(steps.first { $0.name == name }, "no step named '\(name)'")
    let script = try #require(runScript(of: step), "the step '\(name)' has no run: script")
    try require(!script.contains("${{"), "the step '\(name)' holds a ${{ }} expression this test does not fill in:\n\(script)")
    let folder = try makeTemporaryFolder("/tmp/sbs-step-")
    try writeText(script, to: folder + "/step.sh")
    return try runProgram("/bin/bash", ["-c", "cd \"$1\" || exit 99; exec /bin/bash -e \"$2\"", "bash", tree, folder + "/step.sh"], environment: environment, timeout: timeout)
}

// A stand-in that records its arguments (NUL-separated) in $STUB_CALLS/<name>.args, prints $STUB_OUTPUT and exits with $STUB_STATUS (0 when unset).
private func recordingStub(_ name: String) -> String { "printf '%s\\0' \"$@\" > \"$STUB_CALLS/\(name).args\"\n[ -n \"${STUB_OUTPUT:-}\" ] && printf '%s\\n' \"$STUB_OUTPUT\"\nexit \"${STUB_STATUS:-0}\"" }

// The arguments a recording stub was called with, or nil when it was not called.
private func recordedArguments(_ calls: String, _ name: String) -> [String]? {
    guard let text = readText(calls + "/" + name + ".args") else { return nil }
    return Array(text.components(separatedBy: "\0").dropLast())
}

@Suite("Universal programs: the package workflow's Rosetta steps")
struct RosettaWorkflowTests {
    private static let steps = workflowSteps(readText(repositoryRoot + "/.github/workflows/package.yml") ?? "")

    // The order the design gives, with the new steps unconditional (a step with `if:` could be skipped, and then the Intel code would ship untested), and the publish step
    // still gated on the decision.
    @Test func theRosettaStepsRunInOrderBetweenTheTestsAndTheReleaseDecision() throws {
        let order = ["Run the tests", "Install Rosetta", "Run the tests on Intel under Rosetta", "Build the package", "Run the packaged Intel programs under Rosetta", "Decide whether this is a release", "Publish this version as the latest release"]
        let positions = try order.map { name in try #require(Self.steps.firstIndex { $0.name == name }, "no step named '\(name)'") }
        #expect(positions == positions.sorted() && Set(positions).count == positions.count, "steps out of order: \(zip(order, positions).map { "\($0) at \($1)" })")
        for name in ["Install Rosetta", "Run the tests on Intel under Rosetta", "Run the packaged Intel programs under Rosetta"] {
            #expect(Self.steps.first { $0.name == name }?.keys["if"] == nil, "step '\(name)' must always run")
        }
        let publish = try #require(Self.steps.first { $0.name == "Publish this version as the latest release" })
        #expect(bareCondition(publish.keys["if"]) == "steps.decide.outputs.decision == 'release'", "publish if: \(publish.keys["if"] ?? "<none>")")
    }

    // The Install Rosetta step, run with a stand-in sudo: it runs exactly the design's command.
    @Test func theInstallRosettaStepRunsSoftwareupdateWithTheLicenseAgreed() throws {
        let tree = try makeTemporaryFolder("/tmp/sbs-tree-"), calls = try makeTemporaryFolder("/tmp/sbs-calls-")
        let stubs = try makeStubFolder(["sudo": recordingStub("sudo")])
        let result = try runWorkflowStep("Install Rosetta", in: tree, environment: ["PATH": stubs + ":" + systemPath, "STUB_CALLS": calls])
        #expect(result.status == 0, "exit \(result.status): \(result.stderr)")
        #expect(recordedArguments(calls, "sudo") == ["softwareupdate", "--install-rosetta", "--agree-to-license"])
    }

    // The Intel test step, run with a stand-in `arch` that acts out the test run: it runs exactly the design's command, a passing run passes, and a failing run stops the
    // workflow (the pipe through tee must not hide the failure) with each ✘ line as a "Failed Intel test" annotation.
    @Test(arguments: [(0, "✔ Test run with 10 tests passed"), (1, "✘ Test brokenThing() failed after 0.1 seconds"), (1, "the build failed before any test ran")] as [(Int32, String)])
    func theIntelTestStepRunsTestShUnderRosettaAndStopsTheRunWhenItFails(status: Int32, output: String) throws {
        let tree = try makeTemporaryFolder("/tmp/sbs-tree-"), calls = try makeTemporaryFolder("/tmp/sbs-calls-")
        let stubs = try makeStubFolder(["arch": recordingStub("arch")])
        let environment = ["PATH": stubs + ":" + systemPath, "STUB_CALLS": calls, "STUB_OUTPUT": output, "STUB_STATUS": String(status)]
        let result = try runWorkflowStep("Run the tests on Intel under Rosetta", in: tree, environment: environment)
        #expect(recordedArguments(calls, "arch") == ["-x86_64", "/bin/bash", "scripts/test.sh", "--triple", "x86_64-apple-macosx14.0", "--scratch-path", ".build-x86"])
        let annotations = result.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("::error") }
        if status == 0 {
            #expect(result.status == 0 && annotations.isEmpty, "exit \(result.status), stdout:\n\(result.stdout)")
        } else {
            #expect(result.status != 0, "a failed Intel test run must stop the workflow; stdout:\n\(result.stdout)")
            #expect(annotations == (output.contains("✘") ? ["::error title=Failed Intel test::\(output)"] : []), "annotations: \(annotations)")
        }
    }

    // The step that runs the packaged Intel copies, run for real under Rosetta in a folder laid out as the checkout after package.sh: universal stand-in programs in build/
    // and the real install.sh. It passes, and the two --version lines come from the Intel copies.
    @Test func thePackagedIntelStepPassesForUniversalProgramsAndRunsTheirIntelCopies() throws {
        let tree = try makePackageFolder([.universal, .universal, .universal])
        let result = try runWorkflowStep("Run the packaged Intel programs under Rosetta", in: tree, environment: ["PATH": systemPath])
        #expect(result.status == 0 && !result.timedOut, "exit \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        let versions = result.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("stand-in ") }
        #expect(versions == ["stand-in x86_64", "stand-in x86_64"], "the --version runs must use the Intel copies: \(versions)")
    }

    // The same step stops the run when any of the three programs lacks either copy (each program once with only the Apple-chip copy and once with only the Intel copy, so
    // every entry of the lipo check is needed), when any program is missing from build/, and when any of the three plists the daemon prints is not a valid plist.
    // The design lists the lipo check first, so a program problem stops the step before any program runs; a bad plist stops it after both --version runs.
    @Test(arguments: [0, 1, 2].flatMap { [IntelStepProblem.missingCopy(position: $0, kind: .arm64Only), .missingCopy(position: $0, kind: .x86_64Only), .missingProgram(position: $0)] } + ["daemon", "watchdog", "app"].map { IntelStepProblem.badPlist(job: $0) })
    func thePackagedIntelStepFailsForAProgramWithoutBothCopiesOrABadPlist(problem: IntelStepProblem) throws {
        var kinds: [ProgramKind] = [.universal, .universal, .universal]
        if case .missingCopy(let position, let kind) = problem { kinds[position] = kind }
        let tree = try makePackageFolder(kinds)
        if case .missingProgram(let position) = problem { try FileManager.default.removeItem(atPath: tree + "/" + IntelStepProblem.buildItems[position]) }
        var environment = ["PATH": systemPath]
        if case .badPlist(let job) = problem { environment["STANDIN_BAD_PLIST"] = job }
        let result = try runWorkflowStep("Run the packaged Intel programs under Rosetta", in: tree, environment: environment)
        let context = "\(problem.testDescription)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        #expect(result.status != 0 && !result.timedOut, "the step must fail: \(context)")
        let versions = result.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("stand-in ") }
        if case .badPlist = problem { #expect(versions == ["stand-in x86_64", "stand-in x86_64"], "the step should fail at the plist check, after both --version runs: \(context)") }
        else { #expect(versions.isEmpty, "the lipo check must stop the step before any program runs: \(context)") }
    }

    // The dry run's pass line is a check of its own. A stand-in lipo that accepts every program acts out a lipo check that lets a problem through; with SiteBlock.app
    // missing from build/, the step must still fail, because install.sh cannot print "the programs have a copy for this Mac's processor" without the app. With all three
    // programs the same stand-in lets the step pass, so the failure comes from the missing pass line and not from the stand-in.
    @Test(arguments: [true, false])
    func thePackagedIntelStepNeedsTheDryRunsPassLineEvenWhenLipoLetsAProgramThrough(appPresent: Bool) throws {
        let tree = try makePackageFolder([.universal, .universal, .universal])
        if !appPresent { try FileManager.default.removeItem(atPath: tree + "/build/SiteBlock.app") }
        let log = try makeTemporaryFolder("/tmp/sbs-calls-") + "/lipo.log"
        let stubs = try makeStubFolder(["lipo": "printf '%s\\n' \"$*\" >> '\(log)'\nexit 0"])
        let result = try runWorkflowStep("Run the packaged Intel programs under Rosetta", in: tree, environment: ["PATH": stubs + ":" + systemPath])
        let context = "SiteBlock.app \(appPresent ? "present" : "missing")\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        // The stand-in really took the place of lipo for all three programs.
        try require((readText(log) ?? "").split(separator: "\n").count == 3, "the stand-in lipo was not called for the three programs: \(readText(log) ?? "<no log>")\n\(context)")
        let dryRun = readText(tree + "/install-dry-run.log") ?? ""
        let passLine = dryRun.components(separatedBy: "\n").contains("the programs have a copy for this Mac's processor")
        if appPresent {
            #expect(result.status == 0 && passLine, "with all three programs the step must pass: \(context)\ndry run:\n\(dryRun)")
        } else {
            #expect(result.status != 0 && !result.timedOut, "without SiteBlock.app the step must fail: \(context)\ndry run:\n\(dryRun)")
            #expect(!passLine, "the dry run printed the pass line without SiteBlock.app:\n\(dryRun)")
        }
    }
}

// What is wrong with the checkout in one run of the packaged Intel step: a program holding only one family's copy, a program missing from build/ (for the app, the whole
// SiteBlock.app), or the daemon printing something that is not a plist for one job.
enum IntelStepProblem: Sendable, CustomTestStringConvertible {
    case missingCopy(position: Int, kind: ProgramKind)
    case missingProgram(position: Int)
    case badPlist(job: String)

    // The items under the checkout that `missingProgram` removes, in the order siteblockd, siteblock, app.
    static let buildItems = ["build/siteblockd", "build/siteblock", "build/SiteBlock.app"]

    var testDescription: String {
        switch self {
        case .missingCopy(let position, let kind): "\(programPaths[position]) is \(kind.rawValue)"
        case .missingProgram(let position): "\(Self.buildItems[position]) is missing"
        case .badPlist(let job): "bad \(job) plist"
        }
    }
}

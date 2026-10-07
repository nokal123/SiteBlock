import Foundation
import SiteBlockCore
import Testing

// The siteblockd command line: which flag combinations are refused with exit 64, and what the print-only modes output.
// Design: 03-daemon-cli-app.md § siteblockd Entry Point; 04-infrastructure.md § Launchd Jobs, § Sandbox Mode.
// Every refused case runs as a normal user. If a combination were wrongly accepted, siteblockd would stop with "must run as root" (exit 77) and touch nothing; these tests are switched off when the test process itself is root so they can never start the real daemon.
@Suite("siteblockd flags")
struct DaemonFlagsTests {
    // A sandbox folder name for flag combinations that include --sandbox. It is removed again by the caller.
    static func scratchDirectory() throws -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let path = "/tmp/sbf-" + String((0..<8).map { _ in alphabet.randomElement()! })
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }

    // 03 § siteblockd Entry Point: --tick and --policy-fast are only accepted together with --sandbox, so the installed daemon can never run with short waits. The flag order must not matter.
    @Test(.enabled(if: geteuid() != 0), arguments: [
        ["--tick", "1", "--daemon"],
        ["--daemon", "--tick", "1"],
        ["--daemon", "--policy-fast"],
        ["--policy-fast", "--daemon"],
        ["--daemon", "--tick", "1", "--policy-fast"],
        ["--tick", "0.2", "--policy-fast", "--daemon"],
    ])
    func tickAndPolicyFastWithoutSandboxExit64(flags: [String]) throws {
        let result = try runDaemonProgram(flags)
        #expect(!result.timedOut, "siteblockd \(flags) kept running")
        #expect(result.status == 64, "siteblockd \(flags.joined(separator: " ")) exited \(result.status); stderr: \(result.stderr)")
        #expect(!result.stderr.isEmpty, "usage goes to standard error")
    }

    // 03 § siteblockd Entry Point: "Exactly one of --daemon, --watchdog, --version or --print-plist is required. Unknown flags print usage to standard error and exit with code 64."
    @Test(.enabled(if: geteuid() != 0), arguments: [
        [String](),
        ["--bogus"],
        ["--daemon", "--bogus"],
        ["--daemon", "--version"],
        ["--version", "--print-plist", "daemon"],
        ["--tick", "1"],
        ["--policy-fast"],
        ["--print-plist"],
        ["--print-plist", "nonsense"],
        ["daemon"],
        ["-d"],
    ])
    func missingConflictingOrUnknownFlagsExit64(flags: [String]) throws {
        let result = try runDaemonProgram(flags)
        #expect(!result.timedOut, "siteblockd \(flags) kept running")
        #expect(result.status == 64, "siteblockd \(flags.joined(separator: " ")) exited \(result.status); stderr: \(result.stderr)")
        #expect(!result.stderr.isEmpty)
    }

    // Combinations that include --sandbox but are still wrong. If the unknown flag or the bad value were ignored the daemon would start inside the sandbox folder and run until the time limit kills it, which this test reports as "kept running".
    @Test(.enabled(if: geteuid() != 0), arguments: [
        ["--daemon", "--sandbox", "DIR", "--bogus"],
        ["--sandbox", "DIR"],
        ["--sandbox", "DIR", "--tick", "1"],
        ["--daemon", "--sandbox", "DIR", "--tick", "abc"],
        ["--daemon", "--sandbox", "DIR", "--tick", "0"],
        ["--daemon", "--sandbox", "DIR", "--tick", "-1"],
        ["--daemon", "--sandbox", "DIR", "--tick"],
        ["--daemon", "--sandbox"],
        // The watchdog's whole job is to call launchctl, which a sandbox forbids, so the two never go together (in either order).
        ["--watchdog", "--sandbox", "DIR"],
        ["--sandbox", "DIR", "--watchdog"],
        ["--watchdog", "--sandbox", "DIR", "--tick", "1", "--policy-fast"],
    ])
    func wrongCombinationsWithASandboxExit64(flags: [String]) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let arguments = flags.map { $0 == "DIR" ? directory : $0 }
        let result = try runDaemonProgram(arguments, timeout: 6)
        #expect(!result.timedOut, "siteblockd \(flags) started a daemon instead of refusing")
        #expect(result.status == 64, "siteblockd \(flags.joined(separator: " ")) exited \(result.status); stderr: \(result.stderr)")
    }

    // The installed watchdog runs as root; started by an ordinary user without --sandbox it must refuse at once instead of failing halfway: exit code 77 (the Unix code for "permission denied"). The design names no exit code for this refusal (a spec gap: 03 § siteblockd Entry Point only says `--sandbox` is refused with 64 as root); 77 is the code the task and the program use. The test is switched off for a root test process, which would otherwise start the real watchdog.
    @Test(.enabled(if: geteuid() != 0))
    func theWatchdogWithoutASandboxRefusesToRunAsANormalUserWithExit77() throws {
        let result = try runDaemonProgram(["--watchdog"], timeout: 6)
        #expect(!result.timedOut, "siteblockd --watchdog kept running as a normal user")
        #expect(result.status == 77 && !result.killedBySignal, "exited \(result.status); stderr: \(result.stderr)")
        #expect(!result.stderr.isEmpty, "the reason goes to standard error")
    }

    // 03 § siteblockd Entry Point: --version prints the version and exits; the daemon, the CLI and a running daemon's status all report the same version string.
    @Test func versionStringsAgreeAcrossTheDaemonTheCLIAndAStatusReply() throws {
        try withDaemon { daemon in
            let daemonProgram = try runDaemonProgram(["--version"])
            let cli = try runCLI(["version"], socket: daemon.socketPath)
            #expect(daemonProgram.status == 0 && cli.status == 0)
            let status = try daemon.status()
            let fromDaemon = daemonProgram.stdout.split(whereSeparator: \.isWhitespace).last.map(String.init)
            let fromCLI = cli.stdout.split(whereSeparator: \.isWhitespace).last.map(String.init)
            #expect(!status.version.isEmpty)
            #expect(fromDaemon == status.version, "siteblockd --version printed \(daemonProgram.stdout)")
            #expect(fromCLI == status.version, "siteblock version printed \(cli.stdout)")
        }
    }

    // Parses plist XML text into a dictionary.
    static func plist(_ xml: String) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil)
        return try #require(object as? [String: Any], "not a plist dictionary")
    }

    // 04 § Launchd Jobs: --print-plist prints each job's launchd plist, with the keys the design lists. The install script writes these files from this output.
    @Test(.enabled(if: geteuid() != 0), arguments: [("daemon", "com.nokal.siteblock.daemon", "--daemon", "siteblockd.log"), ("watchdog", "com.nokal.siteblock.watchdog", "--watchdog", "watchdog.log")])
    func theLaunchDaemonPlistsHaveTheKeysTheDesignLists(job: String, label: String, flag: String, log: String) throws {
        let result = try runDaemonProgram(["--print-plist", job])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        let plist = try Self.plist(result.stdout)
        #expect(plist["Label"] as? String == label)
        #expect(plist["ProgramArguments"] as? [String] == ["/Library/Application Support/SiteBlock/bin/siteblockd", flag])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["AbandonProcessGroup"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/Library/Logs/SiteBlock/" + log)
        #expect(plist["StandardErrorPath"] as? String == "/Library/Logs/SiteBlock/" + log)
        #expect(plist["ThrottleInterval"] as? Int == 5)
    }

    // 04 § Launchd Jobs: the app's LaunchAgent starts the app at login, and quitting the app keeps it closed (KeepAlive false).
    @Test(.enabled(if: geteuid() != 0))
    func theAppLaunchAgentPlistStartsTheAppAtLoginWithoutKeepAlive() throws {
        let result = try runDaemonProgram(["--print-plist", "app"])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        let plist = try Self.plist(result.stdout)
        #expect(plist["Label"] as? String == "com.nokal.siteblock.app")
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/SiteBlock.app/Contents/MacOS/SiteBlock"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == false)
    }
}

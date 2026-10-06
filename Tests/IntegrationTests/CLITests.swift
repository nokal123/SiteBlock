import Foundation
import SiteBlockCore
import Testing

// The real `siteblock` command-line tool talking to a sandbox daemon through SITEBLOCK_SOCKET, with passwords piped on standard input.
// Design: 03-daemon-cli-app.md § siteblock CLI (usage, password reading, exit codes 0 / 1 / 2 / 64); 05-testing-and-operations.md § Integration Tests.
@Suite("siteblock CLI")
struct CLITests {
    static let password = SandboxDaemon.password

    // Runs the CLI against the daemon's socket.
    static func cli(_ daemon: SandboxDaemon, _ arguments: [String], stdin: String? = nil) throws -> ProgramResult {
        try runCLI(arguments, socket: daemon.socketPath, stdin: stdin)
    }

    // 05 Integration Tests, CLI bullet: setup, add and status through the real tool. With a tick that never fires, the hosts file can only have been written by the command itself, so it must be correct the moment the tool exits.
    @Test func setupAddAndStatusWorkAndTheBlockIsOnDiskWhenTheToolExits() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            let before = try Self.cli(daemon, ["status"])
            #expect(before.status == 0 && !before.timedOut, "stderr: \(before.stderr)")
            #expect(before.stdout.contains("2 seconds"), "status prints the unblock delay; got: \(before.stdout)")

            let setup = try Self.cli(daemon, ["setup"], stdin: "\(Self.password)\n\(Self.password)\n")
            #expect(setup.status == 0, "stderr: \(setup.stderr)")
            let again = try Self.cli(daemon, ["setup"], stdin: "other-password\nother-password\n")
            #expect(again.status == 1, "a second setup is refused by the daemon")
            #expect(!again.stderr.isEmpty, "the daemon's error sentence goes to standard error")

            let add = try Self.cli(daemon, ["add", "reddit.com"])
            #expect(add.status == 0, "stderr: \(add.stderr)")
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com")))

            let status = try Self.cli(daemon, ["status"])
            #expect(status.status == 0)
            let line = status.stdout.components(separatedBy: "\n").first { $0.contains("reddit.com") }
            #expect(line != nil, "status must list reddit.com: \(status.stdout)")
            #expect(line?.contains("28") == true, "status shows each site with its host count (reddit.com expands to 28 names): \(line ?? "")")
        }
    }

    // 05 Integration Tests, CLI bullet: `unblock` with the password piped on standard input. A wrong password exits 1; the right one exits 0, starts the countdown and the site goes away after the 2 s delay.
    @Test func unblockThroughTheCLIUsesThePipedPasswordAndFinishesAfterTheDelay() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))

            let wrong = try Self.cli(daemon, ["unblock", "reddit.com"], stdin: "not-the-password\n")
            #expect(wrong.status == 1)
            #expect(!wrong.stderr.isEmpty)
            let afterWrong = try daemon.status()
            #expect(afterWrong.blocked.first?.unblockSecondsRemaining == nil)

            let empty = try Self.cli(daemon, ["unblock", "reddit.com"], stdin: "")
            #expect(empty.status != 0 && !empty.timedOut, "no password on standard input must fail, not hang")
            let afterEmpty = try daemon.status()
            #expect(afterEmpty.blocked.first?.unblockSecondsRemaining == nil)

            let good = try Self.cli(daemon, ["unblock", "reddit.com"], stdin: "\(Self.password)\n")
            let watch = Stopwatch()
            #expect(good.status == 0, "stderr: \(good.stderr)")
            #expect(good.stdout.contains("reddit.com") && good.stdout.contains("2 seconds"), "the confirmation names the site and the delay: \(good.stdout)")
            let pending = try Self.cli(daemon, ["status"])
            let line = pending.stdout.components(separatedBy: "\n").first { $0.contains("reddit.com") } ?? ""
            #expect(line.range(of: "[0-9]:[0-9][0-9]", options: .regularExpression) != nil, "status shows the countdown as a clock: \(line)")
            #expect(daemon.hostsText() == blocked)

            let removed = waitUntil(timeout: 3.5, interval: 0.02) { daemon.hostsText() == StandardHosts.text }
            #expect(removed != nil)
            #expect(watch.elapsed >= 1.8)
            let after = try Self.cli(daemon, ["status"])
            #expect(!after.stdout.contains("reddit.com"), "status after the unblock: \(after.stdout)")
        }
    }

    // 03 § siteblock CLI: `cancel <site>` cancels a pending unblock, with no password.
    @Test func cancelThroughTheCLIStopsThePendingUnblock() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let nothing = try Self.cli(daemon, ["cancel", "reddit.com"])
            #expect(nothing.status == 1, "nothing is pending yet")
            let start = try Self.cli(daemon, ["unblock", "reddit.com"], stdin: "\(Self.password)\n")
            #expect(start.status == 0)
            let cancel = try Self.cli(daemon, ["cancel", "reddit.com"])
            #expect(cancel.status == 0, "stderr: \(cancel.stderr)")
            pause(3.2)
            #expect(daemon.hosts().blocks("reddit.com"))
        }
    }

    // One CLI call and the exit code it must give.
    struct ExitCase: Sendable {
        let arguments: [String]
        let stdin: String?
        let exit: Int32
    }

    // 03 § siteblock CLI: exit codes. 0 success, 1 the daemon refused, 64 usage error. Run in order against one daemon that has a password and reddit.com blocked; only two wrong passwords are used so no lockout starts.
    @Test func exitCodesFollowTheDesign() throws {
        let password = "\(Self.password)\n"
        let cases: [ExitCase] = [
            // 64: the command line itself is wrong.
            ExitCase(arguments: [], stdin: nil, exit: 64),
            ExitCase(arguments: ["bogus"], stdin: nil, exit: 64),
            ExitCase(arguments: ["status", "extra"], stdin: nil, exit: 64),
            ExitCase(arguments: ["add"], stdin: nil, exit: 64),
            ExitCase(arguments: ["unblock"], stdin: password, exit: 64),
            ExitCase(arguments: ["unblock", "a.example", "b.example"], stdin: password, exit: 64),
            ExitCase(arguments: ["cancel"], stdin: nil, exit: 64),
            ExitCase(arguments: ["delay", "soon"], stdin: password, exit: 64),
            ExitCase(arguments: ["uninstall", "--bogus"], stdin: password, exit: 64),
            ExitCase(arguments: ["recover", "--bogus"], stdin: nil, exit: 64),
            // 1: the daemon refused.
            ExitCase(arguments: ["add", "1.2.3.4"], stdin: nil, exit: 1),
            ExitCase(arguments: ["add", "localhost"], stdin: nil, exit: 1),
            ExitCase(arguments: ["add", "reddit.com"], stdin: nil, exit: 1),
            ExitCase(arguments: ["unblock", "nothere.example"], stdin: password, exit: 1),
            ExitCase(arguments: ["unblock", "reddit.com"], stdin: "wrong-one\n", exit: 1),
            ExitCase(arguments: ["cancel", "reddit.com"], stdin: nil, exit: 1),
            ExitCase(arguments: ["delay", "--cancel"], stdin: nil, exit: 1),
            ExitCase(arguments: ["delay", "8d"], stdin: password, exit: 1),
            ExitCase(arguments: ["uninstall", "--cancel"], stdin: nil, exit: 1),
            ExitCase(arguments: ["recover", "--cancel"], stdin: nil, exit: 1),
            ExitCase(arguments: ["setup"], stdin: "another-password\nanother-password\n", exit: 1),
            // 0: success.
            ExitCase(arguments: ["status"], stdin: nil, exit: 0),
            ExitCase(arguments: ["version"], stdin: nil, exit: 0),
            ExitCase(arguments: ["delay"], stdin: nil, exit: 0),
            ExitCase(arguments: ["add", "ok1.example", "ok2.example"], stdin: nil, exit: 0),
        ]
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for item in cases {
                let result = try Self.cli(daemon, item.arguments, stdin: item.stdin)
                #expect(!result.timedOut, "\(item.arguments) hung")
                #expect(result.status == item.exit, "siteblock \(item.arguments.joined(separator: " ")) exited \(result.status), expected \(item.exit). stderr: \(result.stderr)")
                if item.exit == 1 { #expect(!result.stderr.isEmpty, "a refusal prints the error sentence to standard error: \(item.arguments)") }
            }
            let status = try daemon.status()
            #expect(Set(status.blocked.map(\.domain)) == ["reddit.com", "ok1.example", "ok2.example"])
            #expect(status.lockoutSecondsRemaining == nil)
        }
    }

    // 03 § siteblock CLI: `sudo siteblock recover` is refused when the caller is not root (the daemon checks the kernel-reported user id), exit 1, and nothing starts.
    @Test(.enabled(if: geteuid() != 0))
    func recoverFromANonRootUserIsRefusedWithExit1() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let result = try Self.cli(daemon, ["recover"])
            #expect(result.status == 1, "stderr: \(result.stderr)")
            #expect(!result.stderr.isEmpty)
            let status = try daemon.status()
            #expect(status.recoverySecondsRemaining == nil)
        }
    }

    // 03 § siteblock CLI: `add` with several sites sends one request per site, keeps going after a failure, and exits 1 if any failed.
    @Test func addWithSeveralSitesKeepsGoingAfterAFailureAndExitsOne() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let result = try Self.cli(daemon, ["add", "first.example", "1.2.3.4", "last.example"])
            #expect(result.status == 1)
            #expect(!result.stderr.isEmpty)
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["first.example", "last.example"])
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["first.example", "last.example"])))
        }
    }

    // 03 § siteblock CLI: exit code 2 when the daemon is not running: for every command, with a socket path that never existed and with the stale socket file a crash leaves behind.
    @Test func everyCommandExitsWithCode2WhenNoDaemonIsRunning() throws {
        let password = "\(Self.password)\n"
        let invocations: [(args: [String], stdin: String?)] = [
            (["status"], nil), (["add", "x.example"], nil), (["unblock", "x.example"], password), (["cancel", "x.example"], nil),
            (["delay"], nil), (["delay", "5m"], password), (["delay", "--cancel"], nil), (["passwd"], "old-old-old\nnew-new-new\nnew-new-new\n"),
            (["uninstall"], password), (["uninstall", "--cancel"], nil), (["recover"], nil), (["recover", "--cancel"], nil),
            (["setup"], "pwpwpw-1\npwpwpw-1\n"),
        ]
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.kill9()
            try require(FileManager.default.fileExists(atPath: daemon.socketPath), "kill -9 should leave the socket file behind")
            let neverExisted = daemon.root + "/nothing-here.sock"
            for socket in [daemon.socketPath, neverExisted] {
                for invocation in invocations {
                    let result = try runCLI(invocation.args, socket: socket, stdin: invocation.stdin)
                    #expect(!result.timedOut, "\(invocation.args) hung")
                    #expect(result.status == 2, "siteblock \(invocation.args.joined(separator: " ")) with socket \(socket.hasSuffix("nothing-here.sock") ? "that never existed" : "left by a crash") exited \(result.status); stderr: \(result.stderr)")
                    #expect(!result.stderr.isEmpty)
                }
            }
        }
    }

    // 03 § siteblock CLI: `delay` shows the delay, `delay <duration>` changes it (longer applies at once), `delay <shorter>` waits, `delay --cancel` drops the pending change, and a wrong password is refused.
    @Test func delayCommandsWorkThroughTheCLI() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let shown = try Self.cli(daemon, ["delay"])
            #expect(shown.status == 0 && shown.stdout.contains("2 seconds"), "got: \(shown.stdout)")
            let longer = try Self.cli(daemon, ["delay", "5m"], stdin: "\(Self.password)\n")
            #expect(longer.status == 0, "stderr: \(longer.stderr)")
            let five = try daemon.status()
            #expect(five.delaySeconds == 300)
            let shown2 = try Self.cli(daemon, ["delay"])
            #expect(shown2.stdout.contains("5 minutes"), "got: \(shown2.stdout)")
            let shorter = try Self.cli(daemon, ["delay", "1m"], stdin: "\(Self.password)\n")
            #expect(shorter.status == 0)
            let pending = try daemon.status()
            #expect(pending.delaySeconds == 300)
            #expect(pending.pendingDelay?.newDelaySeconds == 60)
            let wrong = try Self.cli(daemon, ["delay", "3m"], stdin: "wrong-password\n")
            #expect(wrong.status == 1)
            let cancel = try Self.cli(daemon, ["delay", "--cancel"])
            #expect(cancel.status == 0)
            let cleared = try daemon.status()
            #expect(cleared.pendingDelay == nil)
            #expect(cleared.delaySeconds == 300)
            let unit = try Self.cli(daemon, ["delay", "1h30m"], stdin: "\(Self.password)\n")
            #expect(unit.status == 0)
            let combined = try daemon.status()
            #expect(combined.delaySeconds == 5400, "1h30m is 5400 s")
        }
    }

    // 03 § siteblock CLI: `passwd` reads the old password and the new one (twice). The old password stops working, a weak or wrong or mismatched entry changes nothing.
    @Test func passwdThroughTheCLIReplacesThePassword() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let newPassword = "new-secret-99"
            let weak = try Self.cli(daemon, ["passwd"], stdin: "\(Self.password)\nabc\nabc\n")
            #expect(weak.status == 1, "a password under 6 characters is refused by the daemon")
            let wrongOld = try Self.cli(daemon, ["passwd"], stdin: "bad-old-pw\n\(newPassword)\n\(newPassword)\n")
            #expect(wrongOld.status == 1)
            let mismatch = try Self.cli(daemon, ["passwd"], stdin: "\(Self.password)\nfirst-new-1\nfirst-new-2\n")
            #expect(mismatch.status != 0 && !mismatch.timedOut)
            let ok = try Self.cli(daemon, ["passwd"], stdin: "\(Self.password)\n\(newPassword)\n\(newPassword)\n")
            #expect(ok.status == 0, "stderr: \(ok.stderr)")
            let oldNow = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
            #expect(oldNow.errorCode == .wrongPassword, "the old password must stop working")
            try daemon.send(.unblock, domain: "reddit.com", password: newPassword).requireOK()
        }
    }

    // 02 § PasswordHasher: passwords are kept exactly as typed (spaces kept, no Unicode normalization). The CLI strips only the line ending, so a password set through it must match byte for byte when sent by another client.
    @Test func aPasswordWithSpacesAndAccentsRoundTripsExactlyThroughTheCLI() throws {
        let exact = "  pässwörd ✓ x  "
        let decomposed = exact.decomposedStringWithCanonicalMapping
        try require(Array(exact.utf8) != Array(decomposed.utf8), "the test needs two different byte sequences")
        try withDaemon { daemon in
            let setup = try Self.cli(daemon, ["setup"], stdin: "\(exact)\n\(exact)\n")
            #expect(setup.status == 0, "stderr: \(setup.stderr)")
            try daemon.block("reddit.com")
            for wrong in [exact.trimmingCharacters(in: .whitespaces), decomposed, exact + " "] {
                let reply = try daemon.send(.unblock, domain: "reddit.com", password: wrong)
                #expect(reply.errorCode == .wrongPassword, "\(wrong.debugDescription) must not be accepted")
            }
            try daemon.send(.unblock, domain: "reddit.com", password: exact).requireOK()
        }
    }

    // 03 § siteblock CLI: `uninstall` asks for the password and starts the countdown; `uninstall --cancel` stops it. `status` mentions a pending uninstall.
    @Test func uninstallAndItsCancelWorkThroughTheCLI() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.setDelay, password: Self.password, seconds: 60).requireOK()
            let wrong = try Self.cli(daemon, ["uninstall"], stdin: "bad-password\n")
            #expect(wrong.status == 1)
            let start = try Self.cli(daemon, ["uninstall"], stdin: "\(Self.password)\n")
            #expect(start.status == 0, "stderr: \(start.stderr)")
            let pending = try Self.cli(daemon, ["status"])
            #expect(pending.stdout.lowercased().contains("uninstall"), "status must mention the pending uninstall: \(pending.stdout)")
            let cancel = try Self.cli(daemon, ["uninstall", "--cancel"])
            #expect(cancel.status == 0)
            let after = try Self.cli(daemon, ["status"])
            #expect(!after.stdout.lowercased().contains("uninstall"), "got: \(after.stdout)")
        }
    }

    // 05 Integration Tests / 03 § siteblock CLI: with a lockout running, the CLI refuses with exit 1 even for the right password.
    @Test func theCLIReportsALockoutWithExit1() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for n in 1...5 { _ = try Self.cli(daemon, ["unblock", "reddit.com"], stdin: "wrong-\(n)\n") }
            let refused = try Self.cli(daemon, ["unblock", "reddit.com"], stdin: "\(Self.password)\n")
            #expect(refused.status == 1)
            let status = try Self.cli(daemon, ["status"])
            #expect(status.stdout.lowercased().contains("lock"), "status mentions the lockout: \(status.stdout)")
        }
    }
}

import Foundation
import SiteBlockCore
import Testing

// The real `siteblock` tool and temporary unblocks, against a real siteblockd with --policy-fast (unblock delay 2 s).
// Design: 03-daemon-cli-app.md § 7 siteblock CLI (usage; `status` prints "opens in 42m, for 1h" while a temporary unblock waits and "OPEN — blocks again in 37m" while it is open, with the
// durations written by `Formatting.compact`; exit codes 0, 1, 2 and 64; "`unblock <site or rule> --for <duration>` ... `--in` ... Both durations are read with `parseDuration` ... a value it rejects
// is a usage error (64) that is never sent to the daemon. `--in` without `--for` is also a usage error (64). Each option may be given once, and it takes the next argument as its value. Every option
// is checked before the password is asked for"; "`cancel <site or rule>` ... needs no password") and § 14 (rules); 05-testing-and-operations.md § Integration Tests (the CLI bullet).

private func cli(_ daemon: SandboxDaemon, _ arguments: [String], stdin: String? = nil) throws -> ProgramResult {
    try runCLI(arguments, socket: daemon.socketPath, stdin: stdin)
}

private let password = SandboxDaemon.password

// The line right under the first line of the status output that names the site or rule, without its indentation, or nil.
private func lineUnder(_ name: String, in output: String) -> String? {
    let lines = output.components(separatedBy: "\n")
    guard let index = lines.firstIndex(where: { $0.contains(name) }), index + 1 < lines.count else { return nil }
    return lines[index + 1].trimmingCharacters(in: .whitespaces)
}

// True while the daemon reports the site's temporary unblock as open.
private func isOpen(_ daemon: SandboxDaemon, site: String) -> Bool {
    (try? daemon.temporaryStatus(ofSite: site))?.isOpen == true
}

@Suite("siteblock CLI temporary unblock")
struct CLITemporaryUnblockTests {
    // 05 Integration Tests: "`unblock <site> --for 2s --in 2s` with the password piped on standard input schedules a temporary unblock; `status` shows the waiting line ...; `cancel` ends it".
    // A long wait is used here so the waiting line can be compared exactly: with 2 hours to go the display reads "2h" for the first minute.
    @Test func unblockWithForAndInSchedulesItStatusShowsTheWaitingLineAndCancelEndsIt() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["reddit.com"])
            let result = try cli(daemon, ["unblock", "reddit.com", "--for", "90m", "--in", "2h"], stdin: "\(password)\n")
            #expect(result.status == 0 && !result.timedOut, "stderr: \(result.stderr)")
            #expect(result.stdout.contains("reddit.com opens in 2 hours, for 1 hour 30 minutes, then blocks again."), "got: \(result.stdout)")
            let scheduled = try #require(try daemon.temporaryStatus(ofSite: "reddit.com"))
            #expect((7198...7200).contains(scheduled.opensInSeconds ?? -1) && scheduled.secondsRemaining == 5400 && scheduled.windowSeconds == 5400 && !scheduled.isOpen, "got \(scheduled)")
            #expect(daemon.hostsText() == blocked, "nothing opens during the start wait")

            let waiting = try cli(daemon, ["status"])
            #expect(waiting.status == 0)
            #expect(lineUnder("reddit.com", in: waiting.stdout) == "opens in 2h, for 1h 30m", "got: \(waiting.stdout)")

            let cancel = try cli(daemon, ["cancel", "reddit.com"])
            #expect(cancel.status == 0, "stderr: \(cancel.stderr)")
            #expect(cancel.stdout.contains("The temporary unblock is cancelled; reddit.com stays blocked."), "got: \(cancel.stdout)")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil)
            let after = try cli(daemon, ["status"])
            #expect(!(lineUnder("reddit.com", in: after.stdout) ?? "").hasPrefix("opens in") && !after.stdout.contains("OPEN"), "got: \(after.stdout)")
            let again = try cli(daemon, ["cancel", "reddit.com"])
            #expect(again.status == 1, "nothing is left to cancel")
        }
    }

    // The open phase: `status` prints the OPEN line, the site's lines are gone from the hosts file, and `cancel` blocks it again with the open sentence before it exits.
    @Test func anOpenTemporaryUnblockShowsTheOpenLineAndCancelBlocksTheSiteAgainAtOnce() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsExpected(blocking: ["reddit.com", "example.com"])
            let open = daemon.hostsExpected(blocking: ["example.com"])
            let result = try cli(daemon, ["unblock", "reddit.com", "--for", "2h", "--in", "2s"], stdin: "\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            #expect(waitUntil(timeout: 5.0) { isOpen(daemon, site: "reddit.com") } != nil, "the site never opened")
            #expect(waitUntil(timeout: 1.5) { daemon.hostsText() == open } != nil, "file:\n\(daemon.hostsText())")
            let status = try cli(daemon, ["status"])
            #expect(lineUnder("reddit.com", in: status.stdout) == "OPEN \u{2014} blocks again in 2h", "got: \(status.stdout)")
            let cancel = try cli(daemon, ["cancel", "reddit.com"])
            #expect(cancel.status == 0, "stderr: \(cancel.stderr)")
            #expect(cancel.stdout.contains("reddit.com is blocked again."), "got: \(cancel.stdout)")
            #expect(daemon.hostsText() == blocked, "the lines must be back when cancel returns; file:\n\(daemon.hostsText())")
            #expect(!(lineUnder("reddit.com", in: try cli(daemon, ["status"]).stdout) ?? "").contains("OPEN"))
        }
    }

    // 03 § 7: "`OPEN — blocks again in 37m` while it is open": the time LEFT in the window, not its length. A window of 61 s is written "2m" at the start; a few seconds into it, the line must show the seconds
    // that remain ("57s" or so), written by `Formatting.compact`.
    @Test func theOpenLineShowsTheTimeLeftInTheWindowAndNotItsLength() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let result = try cli(daemon, ["unblock", "reddit.com", "--for", "61s", "--in", "2s"], stdin: "\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            try require(waitUntil(timeout: 5.0) { isOpen(daemon, site: "reddit.com") } != nil, "the site never opened")
            pause(3.0)
            let line = lineUnder("reddit.com", in: try cli(daemon, ["status"]).stdout) ?? ""
            let shown = line.range(of: "^OPEN \u{2014} blocks again in (5[4-9])s$", options: .regularExpression)
            #expect(shown != nil, "about 58 s of a 61 s window are left, so the line reads 'OPEN \u{2014} blocks again in 5Xs'; got: \(line)")
        }
    }

    // The same `OPEN` line sits under a path rule while its temporary unblock is open. A window of 2 hours reads "2h" for the first minute, so the line can be compared exactly.
    @Test func anOpenRuleShowsTheOpenLineUnderTheRule() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let result = try cli(daemon, ["unblock", "youtube.com/shorts", "--for", "2h", "--in", "2s"], stdin: "\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            try require(waitUntil(timeout: 5.0) { ((try? daemon.temporaryStatus(ofRule: "youtube.com/shorts")) ?? nil)?.isOpen == true } != nil, "the rule never opened")
            let status = try cli(daemon, ["status"])
            #expect(lineUnder("youtube.com/shorts", in: status.stdout) == "OPEN \u{2014} blocks again in 2h", "got: \(status.stdout)")
            #expect(!(lineUnder("reddit.com", in: status.stdout) ?? "").contains("OPEN"), "the site is not open")
            let cancel = try cli(daemon, ["cancel", "youtube.com/shorts"])
            #expect(cancel.status == 0 && cancel.stdout.contains("youtube.com/shorts is blocked again."), "stderr: \(cancel.stderr) stdout: \(cancel.stdout)")
        }
    }

    // 03 § 14: a text with a path acts on the rule. `--for` sends temporaryUnblockPath; the rule's status line sits under the rule; `cancel` with the rule text cancels only that.
    @Test func aRuleTextWithForSchedulesTheRulesTemporaryUnblock() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            let result = try cli(daemon, ["unblock", "https://www.youtube.com/shorts/", "--for", "30m", "--in", "1h"], stdin: "\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            #expect(result.stdout.contains("youtube.com/shorts opens in 1 hour, for 30 minutes, then blocks again."), "got: \(result.stdout)")
            #expect(try daemon.temporaryStatus(ofRule: "youtube.com/shorts")?.windowSeconds == 1800)
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil, "the site is not touched")
            let status = try cli(daemon, ["status"])
            #expect(lineUnder("youtube.com/shorts", in: status.stdout) == "opens in 1h, for 30m", "got: \(status.stdout)")
            #expect(!(lineUnder("reddit.com", in: status.stdout) ?? "").hasPrefix("opens in"))
            let cancel = try cli(daemon, ["cancel", "youtube.com/shorts"])
            #expect(cancel.status == 0 && cancel.stdout.contains("The temporary unblock is cancelled; youtube.com/shorts stays blocked."), "stderr: \(cancel.stderr) stdout: \(cancel.stdout)")
            #expect(try daemon.temporaryStatus(ofRule: "youtube.com/shorts") == nil)
        }
    }

    // 03 § 7: "after a start wait of `--in` (the unblock delay when `--in` is missing)". With the sandbox delay of 2 s, `--for 30m` alone opens after 2 s.
    @Test func withoutInTheStartWaitIsTheUnblockDelay() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let watch = Stopwatch()
            let result = try cli(daemon, ["unblock", "reddit.com", "--for", "30m"], stdin: "\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let scheduled = try #require(try daemon.temporaryStatus(ofSite: "reddit.com"))
            #expect((1...2).contains(scheduled.opensInSeconds ?? -1) && scheduled.windowSeconds == 1800 && scheduled.secondsRemaining == 1800, "got \(scheduled)")
            #expect(waitUntil(timeout: 4.0) { isOpen(daemon, site: "reddit.com") } != nil)
            #expect(watch.elapsed >= 2.0, "it opened after \(watch.elapsed) s, before the 2 s unblock delay")
            #expect(watch.elapsed < 2.9, "it opened only \(watch.elapsed) s after the request; the 2 s delay plus one 0.2 s tick plus the tool's start-up was expected")
        }
    }

    // Both durations are read with parseDuration: seconds, minutes, hours, days and combinations all work. The window and the start wait each come out as seconds in the daemon's status.
    @Test(arguments: [("30m", "1h", 1800, 3600), ("90m", "2h", 5400, 7200), ("1h", "1h30m", 3600, 5400), ("2h", "1d", 7200, 86_400), ("900", "3600s", 900, 3600), ("4h", "7d", 14_400, 604_800), ("5M", "2H", 300, 7200)])
    func bothDurationsAreReadWithParseDuration(window: String, start: String, windowSeconds: Int, startSeconds: Int) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let result = try cli(daemon, ["unblock", "reddit.com", "--for", window, "--in", start], stdin: "\(password)\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")
            let scheduled = try #require(try daemon.temporaryStatus(ofSite: "reddit.com"))
            #expect(scheduled.windowSeconds == windowSeconds && scheduled.secondsRemaining == windowSeconds)
            #expect(scheduled.opensInSeconds.map { $0 <= startSeconds && $0 >= startSeconds - 2 } == true, "--in \(start) should be \(startSeconds) s; got \(String(describing: scheduled.opensInSeconds))")
        }
    }

    // MARK: usage errors

    // The argument lists that 03 § 7 calls usage errors: a duration parseDuration rejects, `--in` without `--for`, an option given twice, an option without a value, an option that does not exist (there is no `--reason`) and a wrong number of sites.
    static let badOptionCases: [[String]] = [
        ["unblock", "reddit.com", "--in", "1h"],
        ["unblock", "reddit.com", "--for", "abc"],
        ["unblock", "reddit.com", "--for", ""],
        ["unblock", "reddit.com", "--for", "1.5h"],
        ["unblock", "reddit.com", "--for", "-5m"],
        ["unblock", "reddit.com", "--for", "5x"],
        ["unblock", "reddit.com", "--for", "1h30"],
        ["unblock", "reddit.com", "--for", "30m", "--in", "soon"],
        ["unblock", "reddit.com", "--for", "30m", "--in", "-1h"],
        ["unblock", "reddit.com", "--for", "30m", "--for", "1h"],
        ["unblock", "reddit.com", "--for", "30m", "--in", "1h", "--in", "2h"],
        ["unblock", "reddit.com", "--for"],
        ["unblock", "reddit.com", "--for", "30m", "--in"],
        ["unblock", "reddit.com", "--for", "--in", "1h"],
        ["unblock", "reddit.com", "--for", "30m", "--reason", "because"],
        ["unblock", "reddit.com", "--reason", "because"],
        ["unblock", "reddit.com", "--for", "30m", "--bogus"],
        ["unblock", "--for", "30m"],
        ["unblock", "reddit.com", "example.com", "--for", "30m"],
        ["unblock", "reddit.com", "--for", "30m", "extra.example"],
    ]

    // Each is a usage error (64). The password given on standard input is the RIGHT one, so a request that was wrongly sent anyway would show: the site would get an unblock.
    @Test(arguments: CLITemporaryUnblockTests.badOptionCases)
    func badOptionsAreUsageErrorsAndNothingIsSent(arguments: [String]) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.requireTwoSecondDelay()
            let result = try cli(daemon, arguments, stdin: "\(password)\n")
            #expect(result.status == 64 && !result.timedOut, "siteblock \(arguments.joined(separator: " ")) exited \(result.status); stderr: \(result.stderr)")
            let status = try daemon.status()
            #expect(status.blocked.allSatisfy { $0.unblockSecondsRemaining == nil && $0.temporaryUnblock == nil }, "a request was sent although the options were wrong: \(status.blocked)")
            #expect(status.lockoutSecondsRemaining == nil && daemon.stateObject()?["failedAttempts"] as? Int == 0)
            #expect(daemon.logCount(of: "temporary unblock approved") == 0)
        }
    }

    // The same bad options with a WRONG password on standard input: a request that was wrongly sent would count a wrong password. After many such runs the daemon has counted none and is not locked out.
    @Test func badOptionsNeverCostAPasswordAttempt() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for round in 0..<3 {
                for arguments in [["unblock", "reddit.com", "--in", "1h"], ["unblock", "reddit.com", "--for", "abc"], ["unblock", "reddit.com", "--for", "30m", "--reason", "x"], ["unblock", "reddit.com", "--for", "30m", "--for", "1h"]] {
                    let result = try cli(daemon, arguments, stdin: "wrong-password-1\n")
                    #expect(result.status == 64, "round \(round): siteblock \(arguments.joined(separator: " ")) exited \(result.status)")
                }
            }
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 0, "12 usage errors cost no password attempt")
            #expect(try daemon.status().lockoutSecondsRemaining == nil)
        }
    }

    // 03 § 7: "Every option is checked before the password is asked for, so a mistyped option never costs a password attempt." With EMPTY standard input the password prompt would report "no password was entered" if it were reached first;
    // every bad-option case must end with the usage error and never mention that. (The words "no password was entered" are matched, not "password", which the usage text contains.) The control at the end shows the message does appear
    // when the options are fine and the password really is missing.
    @Test(arguments: CLITemporaryUnblockTests.badOptionCases)
    func badOptionsAreFoundBeforeThePasswordIsAskedFor(arguments: [String]) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            let result = try cli(daemon, arguments, stdin: "")
            #expect(result.status == 64 && !result.timedOut, "siteblock \(arguments.joined(separator: " ")) exited \(result.status); stderr: \(result.stderr)")
            #expect(!result.stderr.contains("no password was entered"), "the password was asked for before the options were checked: \(result.stderr)")
            #expect(!result.stderr.isEmpty, "a usage error must say what is wrong")
        }
    }

    @Test func theNoPasswordMessageAppearsWhenTheOptionsAreFineAndThePasswordIsMissing() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let result = try cli(daemon, ["unblock", "reddit.com", "--for", "30m", "--in", "1h"], stdin: "")
            #expect(result.status == 64)
            #expect(result.stderr.contains("no password was entered"), "got: \(result.stderr)")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil)
        }
    }

    // MARK: refusals by the daemon

    // A request the daemon refuses is printed with exit code 1. Each case is sent with a WRONG password: the refusals that come before the password check count no attempt, so after the whole table
    // the daemon holds no failed attempt and no lockout. The one with the delay in it prints the daemon's own sentence for a start wait below the unblock delay.
    @Test func requestsTheDaemonRefusesExitWithOneAndNeverCountAWrongPassword() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let wrong = "wrong-password-1\n"
            let cases: [(arguments: [String], sentence: String?)] = [
                (["unblock", "reddit.com", "--for", "0"], nil),
                (["unblock", "reddit.com", "--for", "5h"], nil),
                (["unblock", "reddit.com", "--for", "14401"], nil),
                (["unblock", "reddit.com", "--for", "30m", "--in", "1s"], "It can't open sooner than your unblock delay of 2 seconds."),
                (["unblock", "reddit.com", "--for", "30m", "--in", "0"], nil),
                (["unblock", "reddit.com", "--for", "30m", "--in", "8d"], nil),
                (["unblock", "reddit.com", "--for", "30m", "--in", "604801"], nil),
                (["unblock", "nowhere.example", "--for", "30m"], nil),
                (["unblock", "youtube.com/shorts", "--for", "30m"], nil),
                (["unblock", "reddit.com/shorts", "--for", "30m"], nil),
            ]
            for item in cases {
                let result = try cli(daemon, item.arguments, stdin: wrong)
                #expect(result.status == 1 && !result.timedOut, "siteblock \(item.arguments.joined(separator: " ")) exited \(result.status); stderr: \(result.stderr)")
                #expect(!result.stderr.isEmpty, "the daemon's sentence goes to standard error")
                if let sentence = item.sentence { #expect(result.stderr.contains(sentence), "got: \(result.stderr)") }
            }
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 0, "none of the refusals counted a wrong password")
            #expect(try daemon.status().lockoutSecondsRemaining == nil)
            // A request the daemon accepts for checking but with the wrong password is exit 1 too, and does count.
            let valid = try cli(daemon, ["unblock", "reddit.com", "--for", "30m", "--in", "1h"], stdin: wrong)
            #expect(valid.status == 1)
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 1)
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil)
        }
    }

    // The two kinds of unblock keep each other out, through the CLI: the daemon's sentences are printed, the exit code is 1, and the earlier unblock is untouched. A longer delay (600 s) is set first so the
    // permanent unblock below does not finish while the test runs.
    @Test func aSiteWithOneKindOfUnblockRefusesTheOtherThroughTheCLI() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "example.com")
            try daemon.send(.setDelay, password: password, seconds: 600).requireOK()
            try require(try daemon.status().delaySeconds == 600, "the longer delay applies at once")

            try daemon.send(.unblock, domain: "reddit.com", password: password).requireOK()
            let temporaryOnPending = try cli(daemon, ["unblock", "reddit.com", "--for", "30m", "--in", "1h"], stdin: "wrong-password-1\n")
            #expect(temporaryOnPending.status == 1)
            #expect(temporaryOnPending.stderr.contains("reddit.com is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead."), "got: \(temporaryOnPending.stderr)")
            try require(daemon.stateObject()?["failedAttempts"] as? Int == 0, "alreadyPending comes before the password check")
            try daemon.send(.cancelUnblock, domain: "reddit.com").requireOK()

            let scheduled = try cli(daemon, ["unblock", "reddit.com", "--for", "30m", "--in", "1h"], stdin: "\(password)\n")
            #expect(scheduled.status == 0, "stderr: \(scheduled.stderr)")
            let permanentOnTemporary = try cli(daemon, ["unblock", "reddit.com"], stdin: "wrong-password-1\n")
            #expect(permanentOnTemporary.status == 1)
            #expect(permanentOnTemporary.stderr.contains("reddit.com has a temporary unblock. Keep it blocked first if you want to unblock it for good."), "got: \(permanentOnTemporary.stderr)")
            let secondTemporary = try cli(daemon, ["unblock", "reddit.com", "--for", "15m", "--in", "2h"], stdin: "wrong-password-1\n")
            #expect(secondTemporary.status == 1)
            #expect(secondTemporary.stderr.contains("reddit.com already has a temporary unblock."), "got: \(secondTemporary.stderr)")
            #expect(daemon.stateObject()?["failedAttempts"] as? Int == 0, "none of the three counted a wrong password")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com")?.windowSeconds == 1800, "the first temporary unblock is untouched")
            #expect(try daemon.status().blocked.first { $0.domain == "reddit.com" }?.unblockSecondsRemaining == nil)
        }
    }

    // `cancel` of something that has neither kind of unblock, or of an unknown site, is a refusal (exit 1).
    @Test func cancelWithNothingToCancelExitsWithOne() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.addPath, domain: "youtube.com/shorts").requireOK()
            #expect(try cli(daemon, ["cancel", "reddit.com"]).status == 1)
            #expect(try cli(daemon, ["cancel", "youtube.com/shorts"]).status == 1)
            #expect(try cli(daemon, ["cancel", "nowhere.example"]).status == 1)
        }
    }

    // `cancel` needs no password and reads none: it works with nothing on standard input.
    @Test func cancelReadsNoPassword() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.sendTemporary(domain: "reddit.com", seconds: 600, startSeconds: 600).requireOK()
            let result = try cli(daemon, ["cancel", "reddit.com"], stdin: nil)
            #expect(result.status == 0 && !result.timedOut, "stderr: \(result.stderr)")
            #expect(try daemon.temporaryStatus(ofSite: "reddit.com") == nil)
        }
    }

    // The usage text shows the new forms, so a person finds them with `siteblock help`.
    @Test func theHelpTextShowsTheTemporaryUnblockOptionsAndCancel() throws {
        let result = try runCLI(["help"], socket: "/tmp/does-not-exist.sock")
        #expect(result.status == 0)
        #expect(result.stdout.contains("--for") && result.stdout.contains("--in") && result.stdout.contains("cancel"), "got: \(result.stdout)")
        // 03 § 7 gives these two usage lines; they must be there as the design writes them.
        let lines = result.stdout.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains { $0.hasPrefix("siteblock unblock <site> --for <duration> [--in <duration>]") }, "got: \(result.stdout)")
        #expect(lines.contains { $0.hasPrefix("siteblock cancel <site>") }, "got: \(result.stdout)")
        #expect(!result.stdout.contains("--reason"), "there is no such option")
    }

    // 03 § 7: exit code 2 when the daemon is not running, for the new form too, and the usage errors are still found first (a bad option is 64 even with no daemon, because it is never sent).
    @Test func noDaemonIsExitTwoAndABadOptionIsStillAUsageError() throws {
        let socket = "/tmp/sb-none-\(UInt32.random(in: 0...UInt32.max)).sock"
        let missing = try runCLI(["unblock", "reddit.com", "--for", "30m"], socket: socket, stdin: "\(password)\n")
        #expect(missing.status == 2, "stderr: \(missing.stderr)")
        let bad = try runCLI(["unblock", "reddit.com", "--for", "abc"], socket: socket, stdin: "\(password)\n")
        #expect(bad.status == 64)
        let cancel = try runCLI(["cancel", "reddit.com"], socket: socket)
        #expect(cancel.status == 2)
    }
}

import Foundation
import SiteBlockCore
import Testing

// What survives a daemon restart: lockout, failed-attempt count, and running countdowns.
// Design: 01-overview-and-data.md § Fixed Policy Values ("State is saved to disk after every command and at least every 15 seconds while any countdown is running"); 03-daemon-cli-app.md § DaemonRuntime.
@Suite("Restart persistence")
struct RestartTests {
    static let password = SandboxDaemon.password

    // Sends one unblock with a wrong password for reddit.com and returns the reply.
    static func wrongGuess(_ daemon: SandboxDaemon, _ n: Int) throws -> Response {
        try daemon.send(.unblock, domain: "reddit.com", password: "wrong-guess-\(n)")
    }

    // The task's bullet: the lockout survives a daemon restart (graceful stop and kill -9 alike).
    @Test(arguments: StopMethod.allCases)
    func theLockoutSurvivesADaemonRestart(stop: StopMethod) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for n in 1...5 { #expect(try Self.wrongGuess(daemon, n).errorCode == .wrongPassword) }
            let before = try daemon.status()
            try #require(before.lockoutSecondsRemaining != nil, "five wrong passwords must start the lockout")
            daemon.stop(stop)
            try daemon.start()
            // The very first thing after the restart: the right password must still be refused.
            let refused = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
            #expect(refused.ok == false)
            #expect(refused.errorCode == .lockedOut, "a restart must not clear the lockout (\(stop.testDescription))")
            let status = try daemon.status()
            #expect(status.lockoutSecondsRemaining != nil)
            // The lockout then runs out normally and the right password works again.
            let ended = waitUntil(timeout: 4.0, interval: 0.05) { (try? daemon.status().lockoutSecondsRemaining) == nil }
            #expect(ended != nil)
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
        }
    }

    // 01 § Fixed Policy Values: the count of wrong passwords is saved with every command, so restarting between guesses does not reset the count. Four wrong, restart, one more wrong makes five and starts the lockout.
    @Test(arguments: StopMethod.allCases)
    func theWrongPasswordCountSurvivesARestart(stop: StopMethod) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for n in 1...4 { #expect(try Self.wrongGuess(daemon, n).errorCode == .wrongPassword) }
            daemon.stop(stop)
            try daemon.start()
            let fifth = try Self.wrongGuess(daemon, 5)
            #expect(fifth.errorCode == .wrongPassword)
            let status = try daemon.status()
            #expect(status.lockoutSecondsRemaining != nil, "the fifth wrong password in total must lock out; the count was reset by the restart (\(stop.testDescription))")
            let refused = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
            #expect(refused.errorCode == .lockedOut)
        }
    }

    // 01 § Fixed Policy Values: a right password resets the count. Four wrong, one right, then four more wrong must NOT lock out.
    @Test func aRightPasswordResetsTheWrongPasswordCount() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            for n in 1...4 { _ = try Self.wrongGuess(daemon, n) }
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            for n in 5...8 { #expect(try Self.wrongGuess(daemon, n).errorCode == .wrongPassword, "guess \(n)") }
            let status = try daemon.status()
            #expect(status.lockoutSecondsRemaining == nil)
        }
    }

    // MARK: Countdown continuity

    // How a continuity test stops the daemon: graceful (SIGTERM saves), or kill -9 right after a command that forced a save.
    enum Interruption: CaseIterable, CustomTestStringConvertible {
        case sigtermWithoutAnyOtherCommand, sigkillRightAfterAnotherCommand
        var testDescription: String { self == .sigtermWithoutAnyOtherCommand ? "SIGTERM" : "SIGKILL after a saving command" }
    }

    // 05 Integration Tests, fifth bullet: kill the daemon during an unblock countdown, restart it, and the countdown continues from about where it was: not restarted (10 s), not finished early, and it finishes when the remaining time says.
    @Test(arguments: Interruption.allCases)
    func anUnblockCountdownContinuesAfterARestart(interruption: Interruption) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.setDelay, password: Self.password, seconds: 10).requireOK()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            pause(3.0)
            switch interruption {
            case .sigtermWithoutAnyOtherCommand:
                let exit = try #require(daemon.terminate())
                #expect(exit.status == 0 && !exit.killedBySignal)
            case .sigkillRightAfterAnotherCommand:
                // "State is saved to disk after every command": this add saves the countdown as it stands now (about 7 s left); then the kill.
                try daemon.block("keepalive.example.org")
                #expect(daemon.kill9() != nil)
            }
            try daemon.start()
            let reply = try daemon.status()
            let site = try #require(reply.blocked.first { $0.domain == "reddit.com" }, "the site vanished across the restart")
            let remaining = try #require(site.unblockSecondsRemaining, "the pending unblock vanished across the restart")
            let watch = Stopwatch()
            #expect((3...8).contains(remaining), "after 3 s of a 10 s countdown about 7 s should remain; got \(remaining) (10 would mean it restarted)")
            #expect(daemon.hosts().blocks("reddit.com"), "still blocked while the countdown runs")

            // It must end when the remaining time says: not earlier than remaining-1 (the display rounds up) and not much later.
            let ended = waitUntil(timeout: Double(remaining) + 3.0, interval: 0.02) { !daemon.hosts().blocks("reddit.com") }
            let took = watch.elapsed
            #expect(ended != nil, "the countdown never finished after the restart")
            #expect(took >= Double(remaining) - 1.3, "finished after \(took) s, too early for \(remaining) s remaining")
            #expect(took <= Double(remaining) + 1.5, "finished after \(took) s, too late for \(remaining) s remaining")
            let done = try daemon.status()
            #expect(done.blocked.contains { $0.domain == "reddit.com" } == false)
        }
    }

    // 01 § Fixed Policy Values: while a countdown runs, the state is saved at least every 15 seconds. So a kill -9 with no command for 17 s loses at most the last 15 s of progress, not all of it.
    @Test func aKill9DuringALongCountdownLosesAtMostFifteenSecondsOfProgress() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.setDelay, password: Self.password, seconds: 30).requireOK()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            pause(17.0)
            #expect(daemon.kill9() != nil)
            try daemon.start()
            let reply = try daemon.status()
            let remaining = try #require(reply.blocked.first?.unblockSecondsRemaining)
            // 17 s have passed since the last command. A save after 15 s leaves about 15 s (30 - 15); restarting from the command-time save would show 30.
            #expect((10...16).contains(remaining), "got \(remaining) s; 30 would mean no periodic save happened in 17 s")
        }
    }

    // 02 § Models (Countdown): a pending uninstall, delay change and recovery are stored as time remaining, so they also continue rather than restart. Checked here for a pending delay change across a graceful restart.
    @Test func aPendingDelayChangeContinuesAfterARestart() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.setDelay, password: Self.password, seconds: 20).requireOK()
            try daemon.send(.setDelay, password: Self.password, seconds: 5).requireOK()
            pause(3.0)
            daemon.terminate()
            try daemon.start()
            let status = try daemon.status()
            #expect(status.delaySeconds == 20)
            let pending = try #require(status.pendingDelay, "the pending delay change vanished across the restart")
            #expect(pending.newDelaySeconds == 5)
            #expect((14...18).contains(pending.secondsRemaining), "20 s wait, 3 s elapsed: about 17 s should remain; got \(pending.secondsRemaining)")
        }
    }
}

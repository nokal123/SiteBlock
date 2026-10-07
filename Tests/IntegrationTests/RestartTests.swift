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

    // The longest time after the restarted daemon began that the first checks may take for the "still locked out" expectation to be certain. The lockout under --policy-fast lasts 2 s and a restarted daemon continues it from the saved remaining time, so only the time since the new process started can use it up.
    static let latestMeaningfulCheck = 1.5

    // The task's bullet: the lockout survives a daemon restart (graceful stop and kill -9 alike). The time from starting the new daemon to the first checks is measured: when a very slow machine let more than 1.5 s of the 2 s lockout pass, the expectation would not be certain any more, so the round is repeated (up to three times) instead of asserting something that depends on the machine's speed.
    @Test(arguments: StopMethod.allCases)
    func theLockoutSurvivesADaemonRestart(stop: StopMethod) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            var checked = false
            for round in 1...3 where !checked {
                for n in 1...5 { #expect(try Self.wrongGuess(daemon, n).errorCode == .wrongPassword, "round \(round), guess \(n)") }
                let before = try daemon.status()
                try #require(before.lockoutSecondsRemaining != nil, "five wrong passwords must start the lockout")
                daemon.stop(stop)
                let sinceStart = Stopwatch()
                try daemon.start()
                // The very first thing after the restart: the right password must still be refused.
                let refused = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
                let status = try daemon.status()
                let elapsed = sinceStart.elapsed
                if elapsed < Self.latestMeaningfulCheck {
                    #expect(refused.ok == false)
                    #expect(refused.errorCode == .lockedOut, "a restart must not clear the lockout (\(stop.testDescription)); asked \(elapsed) s after the new daemon was started")
                    let left = try #require(status.lockoutSecondsRemaining, "the lockout vanished across the restart (\(stop.testDescription))")
                    #expect((1...2).contains(left), "the 2 s lockout continues, it does not restart or stretch: \(left)")
                    checked = true
                }
                // The lockout then runs out normally and the right password works again (setDelay to the current delay is a harmless password-checked command that also resets the wrong-password count for the next round).
                let ended = waitUntil(timeout: 4.0, interval: 0.05) { (try? daemon.status().lockoutSecondsRemaining) == nil }
                #expect(ended != nil, "the lockout never ended after the restart (\(stop.testDescription))")
                try daemon.send(.setDelay, password: Self.password, seconds: 2).requireOK()
            }
            #expect(checked, "all three restarts took longer than \(Self.latestMeaningfulCheck) s to answer, so the machine is too slow for this check")
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
            // The stopwatch starts BEFORE the status request, so the daemon read the remaining time after the stopwatch started.
            let watch = Stopwatch()
            let reply = try daemon.status()
            let site = try #require(reply.blocked.first { $0.domain == "reddit.com" }, "the site vanished across the restart")
            let remaining = try #require(site.unblockSecondsRemaining, "the pending unblock vanished across the restart")
            #expect((3...8).contains(remaining), "after 3 s of a 10 s countdown about 7 s should remain; got \(remaining) (10 would mean it restarted)")
            #expect(daemon.hosts().blocks("reddit.com"), "still blocked while the countdown runs")

            // The display rounds up, so the true time left when the daemon read it was more than `remaining - 1` seconds, and the site cannot go before that much time has passed since the stopwatch started. It must also not be much later than `remaining`.
            let ended = waitUntil(timeout: Double(remaining) + 3.0, interval: 0.02) { !daemon.hosts().blocks("reddit.com") }
            let took = watch.elapsed
            #expect(ended != nil, "the countdown never finished after the restart")
            #expect(took >= Double(remaining) - 1.0, "finished after \(took) s, too early for \(remaining) s remaining")
            #expect(took <= Double(remaining) + 1.5, "finished after \(took) s, too late for \(remaining) s remaining")
            let done = try daemon.status()
            #expect(done.blocked.contains { $0.domain == "reddit.com" } == false)
        }
    }

    // 01 § Fixed Policy Values: while a countdown runs, the state is saved at least every 15 seconds. So a kill -9 with no command for 15 seconds loses at most the last 15 s of progress, not all of it. The state file is polled instead of sleeping a fixed time: the wait ends the moment the periodic save has happened (the earliest it can, since the period is 15 s), and the restarted daemon must show the progress that was saved. The first save after the command is the periodic one, because every command saves at once and nothing else saves while a countdown runs.
    @Test func aKill9DuringALongCountdownLosesAtMostFifteenSecondsOfProgress() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.setDelay, password: Self.password, seconds: 30).requireOK()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let watch = Stopwatch()
            // The unblock saved the countdown at the full 30 s; a smaller saved value means a later save happened.
            func savedRemaining() -> Double? {
                let site = (daemon.stateObject()?["blocked"] as? [[String: Any]])?.first
                return (site?["pendingUnblock"] as? [String: Any])?["remainingSeconds"] as? Double
            }
            let saved = waitUntil(timeout: 17.5, interval: 0.05) { (savedRemaining() ?? 30) < 29.5 }
            let savedAt = watch.elapsed
            try #require(saved != nil, "the state file still held the command-time countdown after \(savedAt) s: no periodic save happened")
            #expect(savedAt <= 16.5, "the first save after the command came after \(savedAt) s, later than the design's 15 s")
            #expect(daemon.kill9() != nil)
            try daemon.start()
            let reply = try daemon.status()
            let remaining = try #require(reply.blocked.first?.unblockSecondsRemaining)
            // The save was seen at `savedAt` (it happened at most a fraction of a second earlier), so about 30 - savedAt seconds were saved. Restarting from the command-time save would show 30.
            let expected = 30.0 - savedAt
            #expect(abs(Double(remaining) - expected) <= 1.5, "got \(remaining) s; about \(expected) s were saved, 30 would mean the periodic save was lost")
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

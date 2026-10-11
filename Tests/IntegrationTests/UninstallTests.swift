import Foundation
import SiteBlockCore
import Testing

// Uninstall in sandbox mode, and the `uninstalling` flag in the state file.
// Design: 03-daemon-cli-app.md § DaemonRuntime (startup step 3), § Uninstaller (sandbox note), § LaunchdGuard and Watchdog; 01-overview-and-data.md § Data Model.
@Suite("Uninstall and the uninstalling flag")
struct UninstallTests {
    static let password = SandboxDaemon.password

    // 05 Integration Tests, last bullet: after the delay (2 s) the managed section is gone and the daemon exits with code 0. Before the delay is over it must still be running and blocking. The request is sent at a random point of the 0.2 s tick cycle and the stopwatch starts BEFORE it is sent, so the exit can never be seen before 2.0 s (03 § DaemonRuntime "Before every command": a countdown never finishes early).
    @Test func uninstallAfterTheDelayRemovesTheHostsSectionAndTheDaemonExitsWithZero() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            let reply = try daemon.send(.uninstall, password: Self.password).requireOK()
            let remaining = try #require(reply.status?.uninstallSecondsRemaining)
            // Design change: an uninstall waits max(policy.minUninstallSeconds, delaySeconds). Under --policy-fast both are 2 s, so the timing of this test is the 2 s it always was.
            #expect((1...2).contains(remaining), "the uninstall waits 2 s (the fast policy's minimum and its delay), got \(remaining)")
            pause(1.0 - watch.elapsed)
            #expect(daemon.isRunning, "the daemon must keep running during the countdown (request sent \(phase) s into a tick)")
            #expect(daemon.hostsText() == blocked, "blocks stay in place during the countdown")

            let exit = daemon.waitForExit(timeout: 5.0)
            let took = watch.elapsed
            let info = try #require(exit, "the daemon never exited after the uninstall delay")
            #expect(info.status == 0 && !info.killedBySignal, "exit code must be 0, got \(info.status) (signal: \(info.killedBySignal))")
            #expect(took >= 2.0, "exited \(took) s after the request, before the 2 s delay was over (request sent \(phase) s into a tick)")
            #expect(took < 4.0, "exited only after \(took) s")
            #expect(daemon.hostsText() == StandardHosts.text, "03 § Uninstaller step 2: the managed section is removed and the user's lines stay")
            #expect(!FileManager.default.fileExists(atPath: daemon.socketPath), "03 § Uninstaller (sandbox): the socket file is deleted")
            let saved = try #require(daemon.stateObject())
            #expect(saved["uninstalling"] as? Bool == true, "03 § Uninstaller step 1: the state is saved with uninstalling = true")
        }
    }

    // 03 § DaemonRuntime "Before every command": every countdown is brought up to date before a command runs, and a countdown that finished is applied as a tick would apply it. With a tick that never fires, the only thing that can finish the uninstall countdown is the catch-up before the next command, so a command sent after the delay must make the daemon uninstall and exit with code 0, with the section gone and the file staying clean. Not one second early: the daemon must still be there at 1.0 s.
    @Test func anUninstallCountdownFinishedByTheCatchUpBeforeACommandStillUninstalls() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let watch = Stopwatch()
            try daemon.send(.uninstall, password: Self.password).requireOK()
            pause(1.0 - watch.elapsed)
            #expect(daemon.isRunning)
            #expect(daemon.hostsText() == blocked)
            pause(2.2 - watch.elapsed)
            // The reply to this command is not specified once the uninstall has begun (the daemon may answer or hang up), so only what is left behind is checked.
            _ = try? daemon.send(.status)
            let exit = try #require(daemon.waitForExit(timeout: 4.0), "the countdown ran out but no command made the daemon notice")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.hostsText() == StandardHosts.text, "the section is gone and the status poll did not write the blocks back")
            #expect(!FileManager.default.fileExists(atPath: daemon.socketPath))
            let saved = try #require(daemon.stateObject())
            #expect(saved["uninstalling"] as? Bool == true)
        }
    }

    // Design change (01 § Commands, uninstall; § Fixed Policy Values; 02 § Engine): the wait is max(policy.minUninstallSeconds, delaySeconds), and --policy-fast sets the minimum to 2 s. With the delay raised to 5 s (a longer delay applies at once) the uninstall must wait 5 s, not the 2 s minimum: the stopwatch starts before the request, so an exit before 5.0 s cannot be an artefact of timing. The sites stay blocked all along.
    @Test func anUninstallWaitsForTheDelayWhenTheDelayIsLongerThanTheTwoSecondMinimum() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let raised = try daemon.send(.setDelay, password: Self.password, seconds: 5).requireOK()
            try require(raised.status?.delaySeconds == 5, "premise: a longer delay applies at once")
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            let reply = try daemon.send(.uninstall, password: Self.password).requireOK()
            let remaining = try #require(reply.status?.uninstallSecondsRemaining)
            #expect((4...5).contains(remaining), "the uninstall waits the 5 s delay, got \(remaining)")
            pause(3.0 - watch.elapsed)
            #expect(daemon.isRunning, "the daemon ended after 3 s although the wait is 5 s (request sent \(phase) s into a tick)")
            #expect(daemon.hostsText() == blocked, "blocks stay in place during the whole wait")
            let exit = daemon.waitForExit(timeout: 6.0)
            let took = watch.elapsed
            let info = try #require(exit, "the daemon never exited after the uninstall delay")
            #expect(info.status == 0 && !info.killedBySignal, "exit code must be 0, got \(info.status) (signal: \(info.killedBySignal))")
            #expect(took >= 5.0, "exited \(took) s after the request, before the 5 s delay was over (request sent \(phase) s into a tick)")
            #expect(took < 8.0, "exited only after \(took) s")
            #expect(daemon.hostsText() == StandardHosts.text)
        }
    }

    // Same design change, other direction: lowering the delay to 1 s (it takes effect after the old 2 s) leaves the minimum of 2 s as the wait. The old rule (wait = delay) would end the daemon after 1 s, so the exit must not come before 2.0 s and the daemon must still be there at 1.3 s.
    @Test func anUninstallAfterTheDelayWasLoweredBelowTheMinimumStillWaitsTheMinimum() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.setDelay, password: Self.password, seconds: 1).requireOK()
            let lowered = waitUntil(timeout: 6.0, interval: 0.02) { (try? daemon.status().delaySeconds) == 1 }
            try require(lowered != nil, "premise: the delay of 1 s never took effect")
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            let reply = try daemon.send(.uninstall, password: Self.password).requireOK()
            let remaining = try #require(reply.status?.uninstallSecondsRemaining)
            #expect((1...2).contains(remaining), "the uninstall waits the 2 s minimum, got \(remaining)")
            pause(1.3 - watch.elapsed)
            #expect(daemon.isRunning, "the daemon ended after 1.3 s although the minimum wait is 2 s (request sent \(phase) s into a tick)")
            #expect(daemon.hostsText() == blocked)
            let exit = daemon.waitForExit(timeout: 5.0)
            let took = watch.elapsed
            let info = try #require(exit, "the daemon never exited after the uninstall wait")
            #expect(info.status == 0 && !info.killedBySignal)
            #expect(took >= 2.0, "exited \(took) s after the request, before the 2 s minimum was over (request sent \(phase) s into a tick)")
            #expect(took < 4.0, "exited only after \(took) s")
            #expect(daemon.hostsText() == StandardHosts.text)
        }
    }

    // After a finished uninstall the state says uninstalling = true with a finished countdown, so starting the daemon again finishes the uninstall at once (the crash-in-the-middle case, startup step 3) instead of serving.
    @Test func startingAgainAfterAFinishedUninstallFinishesItInsteadOfServing() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.uninstall, password: Self.password).requireOK()
            try #require(daemon.waitForExit(timeout: 6.0) != nil)
            try daemon.start(serve: false)
            let exit = try #require(daemon.waitForExit(timeout: 4.0), "the restarted daemon kept running although an uninstall had finished")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.hostsText() == StandardHosts.text)
        }
    }

    // 01 § Commands: the uninstall needs the password, and a refused attempt starts no countdown.
    @Test func uninstallWithTheWrongPasswordIsRefusedAndStartsNothing() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let reply = try daemon.send(.uninstall, password: "nope-nope-nope")
            #expect(reply.errorCode == .wrongPassword)
            let status = try daemon.status()
            #expect(status.uninstallSecondsRemaining == nil)
            pause(3.0)
            #expect(daemon.isRunning)
            #expect(daemon.hosts().blocks("reddit.com"))
        }
    }

    // 01 § Commands: cancelUninstall needs no password and stops the uninstall for good; with nothing pending it fails with nothingPending.
    @Test func cancellingAnUninstallKeepsTheDaemonRunningAndBlocking() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let nothing = try daemon.send(.cancelUninstall)
            #expect(nothing.errorCode == .nothingPending)
            try daemon.send(.uninstall, password: Self.password).requireOK()
            pause(0.5)
            try daemon.send(.cancelUninstall).requireOK()
            let status = try daemon.status()
            #expect(status.uninstallSecondsRemaining == nil)
            pause(3.0)
            #expect(daemon.isRunning, "the cancelled uninstall still ended the daemon")
            // Alive means answering, not just a live process.
            let later = try daemon.status()
            #expect(later.blocked.map(\.domain) == ["reddit.com"])
            #expect(later.uninstallSecondsRemaining == nil)
            #expect(daemon.hosts().blocks("reddit.com"))
            let saved = try #require(daemon.stateObject())
            #expect(saved["uninstalling"] as? Bool == false)
        }
    }

    // MARK: The hand-set flag

    // How the flag is set by hand while the daemon is stopped.
    enum HandEdit: CaseIterable, CustomTestStringConvertible {
        case flagOnly
        case flagWithARunningCountdown
        var testDescription: String { self == .flagOnly ? "uninstalling=true only" : "uninstalling=true with an unfinished countdown" }

        // Edits a state file's top-level keys.
        func edit(_ object: inout [String: Any]) {
            object["uninstalling"] = true
            if self == .flagWithARunningCountdown { object["pendingUninstall"] = ["remainingSeconds": 100.0, "totalSeconds": 100.0] }
        }
    }

    // The task's third extra bullet (03 § DaemonRuntime startup step 3): `uninstalling: true` set by hand without a finished pendingUninstall is ignored on restart: the daemon keeps running and keeps blocking, and the flag is set back to false in both state files.
    @Test(arguments: HandEdit.allCases)
    func aHandSetUninstallingFlagWithoutAFinishedCountdownIsIgnoredOnRestart(edit: HandEdit) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.terminate()
            for path in [daemon.statePath, daemon.stateBackupPath] { try editJSONObject(at: path) { edit.edit(&$0) } }
            try daemon.start()
            pause(1.0)
            #expect(daemon.isRunning, "the daemon obeyed a hand-set uninstalling flag (\(edit.testDescription))")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com"])
            #expect(daemon.hosts().blocks("reddit.com"))
            if edit == .flagWithARunningCountdown {
                let left = try #require(status.uninstallSecondsRemaining, "the unfinished countdown itself stays")
                #expect(left <= 100 && left >= 90)
            } else {
                #expect(status.uninstallSecondsRemaining == nil)
            }
            let flagCleared = waitUntil(timeout: 1.0, interval: 0.02) {
                readJSONObject(daemon.statePath)?["uninstalling"] as? Bool == false && readJSONObject(daemon.stateBackupPath)?["uninstalling"] as? Bool == false
            }
            #expect(flagCleared != nil, "the flag must be saved back as false in state.json and in the backup")
            // The daemon is really "running normally": it still repairs tampering.
            try writeText(StandardHosts.text, to: daemon.hostsPath)
            let repaired = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hosts().blocks("reddit.com") }
            #expect(repaired != nil)
        }
    }

    // The same flag edited while the daemon runs: the in-memory state wins, the file is rewritten within a tick, and the daemon neither uninstalls nor stops blocking.
    @Test func aHandSetUninstallingFlagWhileTheDaemonRunsIsUndoneAndIgnored() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try editJSONObject(at: daemon.statePath) { $0["uninstalling"] = true; $0["pendingUninstall"] = ["remainingSeconds": 0.0, "totalSeconds": 2.0] }
            let undone = waitUntil(timeout: 1.0, interval: 0.01) { readJSONObject(daemon.statePath)?["uninstalling"] as? Bool == false }
            #expect(undone != nil, "state.json still says uninstalling")
            pause(1.5)
            #expect(daemon.isRunning)
            let status = try daemon.status()
            #expect(status.uninstallSecondsRemaining == nil)
            #expect(daemon.hosts().blocks("reddit.com"))
        }
    }

    // The control for the two tests above: a flag that IS backed by a finished countdown (a real crash in the middle of an uninstall) makes the daemon finish the uninstall and exit 0 at startup. This proves the ignore path is not just a broken uninstall path.
    @Test func theFlagWithAFinishedCountdownMakesTheDaemonFinishTheUninstallAtStartup() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.terminate()
            for path in [daemon.statePath, daemon.stateBackupPath] {
                try editJSONObject(at: path) { $0["uninstalling"] = true; $0["pendingUninstall"] = ["remainingSeconds": 0.0, "totalSeconds": 2.0] }
            }
            try daemon.start(serve: false)
            let exit = try #require(daemon.waitForExit(timeout: 4.0), "the daemon kept running although the uninstall countdown had finished")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.hostsText() == StandardHosts.text, "the managed section must be removed")
        }
    }

    // 03 § DaemonRuntime step 3 says the daemon "logs it". The wording is not fixed, so only the topic is checked.
    @Test func ignoringAHandSetFlagIsLogged() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.terminate()
            for path in [daemon.statePath, daemon.stateBackupPath] { try editJSONObject(at: path) { $0["uninstalling"] = true } }
            try daemon.start()
            let logged = waitUntil(timeout: 1.5, interval: 0.02) { daemon.logText().lowercased().contains("uninstalling") }
            #expect(logged != nil, "log was:\n\(daemon.logText())")
        }
    }

    // 03 § Uninstaller step 1: if the save with uninstalling = true fails, the uninstall stops and the daemon exits with a non-zero code. Nothing else has been done at that point, so the blocks stay in the hosts file. After the fault is gone, a restart retries the uninstall and finishes it.
    @Test func anUninstallWhoseFirstSaveFailsStopsWithoutTouchingTheBlocksAndTheRetryFinishes() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = daemon.hostsText()
            try daemon.send(.uninstall, password: Self.password).requireOK()
            // A state folder that cannot be written makes every save fail, as a full disk would.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: daemon.stateDir)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemon.stateDir) }
            let first = try #require(daemon.waitForExit(timeout: 6.0), "the daemon neither finished nor stopped the uninstall")
            #expect(first.killedBySignal == false && first.status != 0, "a failed first save must end the daemon with a non-zero exit code, got \(first.status). Log:\n\(daemon.logText())")
            #expect(daemon.hostsText() == blocked, "the uninstall must not run half-way: the hosts section is still there")

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemon.stateDir)
            try daemon.start(serve: false)
            let second = try #require(daemon.waitForExit(timeout: 8.0), "the retried uninstall never finished")
            #expect(second.status == 0 && !second.killedBySignal)
            #expect(daemon.hostsText() == StandardHosts.text)
        }
    }
}

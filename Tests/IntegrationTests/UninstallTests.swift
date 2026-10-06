import Foundation
import SiteBlockCore
import Testing

// Uninstall in sandbox mode, and the `uninstalling` flag in the state file.
// Design: 03-daemon-cli-app.md § DaemonRuntime (startup step 3), § Uninstaller (sandbox note), § LaunchdGuard and Watchdog; 01-overview-and-data.md § Data Model.
@Suite("Uninstall and the uninstalling flag")
struct UninstallTests {
    static let password = SandboxDaemon.password

    // 05 Integration Tests, last bullet: after the delay (2 s) the managed section is gone and the daemon exits with code 0. Before the delay is over it must still be running and blocking.
    @Test func uninstallAfterTheDelayRemovesTheHostsSectionAndTheDaemonExitsWithZero() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let reply = try daemon.send(.uninstall, password: Self.password).requireOK()
            let watch = Stopwatch()
            let remaining = try #require(reply.status?.uninstallSecondsRemaining)
            #expect((1...2).contains(remaining), "the uninstall waits the 2 s delay, got \(remaining)")
            pause(1.0 - watch.elapsed)
            #expect(daemon.isRunning, "the daemon must keep running during the countdown")
            #expect(daemon.hostsText() == blocked, "blocks stay in place during the countdown")

            let exit = daemon.waitForExit(timeout: 5.0)
            let took = watch.elapsed
            let info = try #require(exit, "the daemon never exited after the uninstall delay")
            #expect(info.status == 0 && !info.killedBySignal, "exit code must be 0, got \(info.status) (signal: \(info.killedBySignal))")
            #expect(took >= 1.8, "exited after only \(took) s of a 2 s delay")
            #expect(daemon.hostsText() == StandardHosts.text, "03 § Uninstaller step 2: the managed section is removed and the user's lines stay")
            #expect(!FileManager.default.fileExists(atPath: daemon.socketPath), "03 § Uninstaller (sandbox): the socket file is deleted")
            let saved = try #require(daemon.stateObject())
            #expect(saved["uninstalling"] as? Bool == true, "03 § Uninstaller step 1: the state is saved with uninstalling = true")
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

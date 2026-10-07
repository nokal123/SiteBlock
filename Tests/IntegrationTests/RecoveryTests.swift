import Foundation
import SiteBlockCore
import Testing

// The forgotten-password reset (recovery) over the real socket.
// Design: 01-overview-and-data.md § Commands (recoveryStart: only accepted when the connecting process runs as root, checked with LOCAL_PEERCRED; when the countdown finishes the password is cleared and setup works again; blocked sites stay blocked; recoveryCancel needs no password); 02-core-components.md § Engine ("recoveryStart: fail notRoot unless peerUID == 0. Fail notSetUp if no password is set", "Tick rule" for a finished recovery, cancel commands fail with nothingPending when there is none).
// The test process is not root, so a real recovery cannot be started over the socket; a recovery that is about to finish is put into the state files while the daemon is stopped.
@Suite("Recovery")
struct RecoveryTests {
    static let password = SandboxDaemon.password

    // Stops the daemon and puts a recovery countdown (and any other top-level change) into both state files, the way a recovery started earlier would look on disk.
    static func forgeRecovery(_ daemon: SandboxDaemon, remaining: Double, total: Double, _ more: ((inout [String: Any]) -> Void)? = nil) throws {
        daemon.terminate()
        for path in [daemon.statePath, daemon.stateBackupPath] {
            try editJSONObject(at: path) { object in
                object["recovery"] = ["remainingSeconds": remaining, "totalSeconds": total]
                more?(&object)
            }
        }
    }

    // 01 § Commands and 02 § Engine: recoveryStart from a process that is not root gets errorCode notRoot exactly, on the wire, and starts nothing. The check comes before "no password set": a daemon that has no password yet still answers notRoot.
    @Test(.enabled(if: geteuid() != 0))
    func recoveryStartFromANonRootProcessIsRefusedWithNotRoot() throws {
        try withDaemon { daemon in
            let beforeSetup = try rawExchange(try requestLine(["command": "recoveryStart"]), socketPath: daemon.socketPath)
            #expect(beforeSetup.ok == false)
            #expect(beforeSetup.errorCode == "notRoot", "got: \(beforeSetup.text.prefix(200))")
            try daemon.prepare(blocking: "reddit.com")
            let raw = try rawExchange(try requestLine(["command": "recoveryStart"]), socketPath: daemon.socketPath)
            #expect(raw.errorCode == "notRoot", "got: \(raw.text.prefix(200))")
            #expect((raw.json?["error"] as? String)?.isEmpty == false, "a human-readable sentence is present")
            let typed = try daemon.send(.recoveryStart)
            #expect(typed.ok == false && typed.errorCode == .notRoot)
            let status = try daemon.status()
            #expect(status.recoverySecondsRemaining == nil, "a refused recoveryStart must not start a countdown")
            #expect(status.passwordSet)
        }
    }

    // 02 § Engine: cancel commands fail with nothingPending when nothing is running.
    @Test func recoveryCancelWithNothingRunningFailsWithNothingPending() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let reply = try daemon.send(.recoveryCancel)
            #expect(reply.ok == false)
            #expect(reply.errorCode == .nothingPending)
            let raw = try rawExchange(try requestLine(["command": "recoveryCancel"]), socketPath: daemon.socketPath)
            #expect(raw.errorCode == "nothingPending", "got: \(raw.text.prefix(200))")
        }
    }

    // 01 § Commands (recoveryCancel): stops a running recovery, with no password. A recovery with 100 s left is shown in the status, cancelled, and then cancelling again is nothingPending. The password is still set afterwards.
    @Test func recoveryCancelStopsARunningRecoveryWithoutAPassword() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try Self.forgeRecovery(daemon, remaining: 100, total: 100)
            try daemon.start()
            let running = try daemon.status()
            let left = try #require(running.recoverySecondsRemaining, "the recovery in the state file was not picked up")
            #expect((90...100).contains(left))
            #expect(running.passwordSet)
            try daemon.send(.recoveryCancel).requireOK()
            let after = try daemon.status()
            #expect(after.recoverySecondsRemaining == nil)
            #expect(after.passwordSet)
            #expect(try daemon.send(.recoveryCancel).errorCode == .nothingPending)
            let saved = try #require(daemon.stateObject())
            #expect(saved["recovery"] == nil || saved["recovery"] is NSNull, "the cancelled recovery is saved as gone")
        }
    }

    // 01 § Commands (recoveryStart), 02 § Engine "Tick rule": when the recovery countdown finishes in a running daemon, the password is cleared (status passwordSet false), the failed-attempt count and lockout are reset, the recovery is cleared, the blocks stay (hosts file unchanged), and setup works again with a new password. Not earlier than its 1.5 s: it is still running right after the start.
    @Test func aRecoveryThatFinishesInARunningDaemonClearsThePasswordKeepsTheBlocksAndLetsSetupWorkAgain() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let blocked = daemon.hostsText()
            // failedAttempts 4: if finishing the recovery did not reset it, the first wrong guess after the new setup would be the fifth and start a lockout.
            try Self.forgeRecovery(daemon, remaining: 1.5, total: 3.0) { $0["failedAttempts"] = 4 }
            let watch = Stopwatch()
            try daemon.start()
            let running = try daemon.status()
            if watch.elapsed < 1.2 {
                #expect(running.passwordSet, "the password was cleared \(watch.elapsed) s into a 1.5 s recovery")
                let left = try #require(running.recoverySecondsRemaining)
                #expect((1...2).contains(left))
            }
            let cleared = waitUntil(timeout: 4.0, interval: 0.02) { (try? daemon.status().passwordSet) == false }
            let clearedAt = watch.elapsed
            #expect(cleared != nil, "the password was never cleared")
            #expect(clearedAt >= 1.5, "the recovery finished \(clearedAt) s after the daemon was started, before its 1.5 s were over")
            let after = try daemon.status()
            #expect(after.passwordSet == false)
            #expect(after.recoverySecondsRemaining == nil)
            #expect(after.lockoutSecondsRemaining == nil)
            #expect(after.blocked.map(\.domain) == ["reddit.com"], "blocked sites stay blocked after a recovery")
            #expect(daemon.hostsText() == blocked, "the hosts file must keep the blocks")
            let clearedOnDisk = waitUntil(timeout: 1.5, interval: 0.02) {
                guard let saved = daemon.stateObject() else { return false }
                return (saved["passwordHash"] == nil || saved["passwordHash"] is NSNull) && (saved["recovery"] == nil || saved["recovery"] is NSNull)
            }
            #expect(clearedOnDisk != nil, "the cleared password and recovery were not saved")

            // Without a password a NEW site cannot be added, but setup works again.
            #expect(try daemon.send(.add, domain: "youtube.com").errorCode == .notSetUp)
            try daemon.setUp(password: "a-whole-new-one")
            let status = try daemon.status()
            #expect(status.passwordSet)
            // The old password no longer works; four wrong guesses (the count was reset) do not lock out; the new password works.
            for attempt in 1...4 {
                let reply = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
                #expect(reply.errorCode == .wrongPassword, "guess \(attempt) after the new setup: \(reply.errorCode?.rawValue ?? "ok")")
            }
            try daemon.send(.add, domain: "youtube.com").requireOK()
            try daemon.send(.unblock, domain: "reddit.com", password: "a-whole-new-one").requireOK()
        }
    }
}

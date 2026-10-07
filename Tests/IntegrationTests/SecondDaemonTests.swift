import Foundation
import SiteBlockCore
import Testing

// A second siteblockd started on a sandbox that already has a live daemon.
// Design: 03-daemon-cli-app.md § DaemonRuntime "Second daemon": "at startup the socket server first tries to connect to an existing socket file. If a live daemon answers, the new process exits with code 1 and leaves the socket alone. Only a socket nobody answers on (left by a killed daemon) is removed and replaced."
@Suite("Second daemon")
struct SecondDaemonTests {
    // 03 § DaemonRuntime "Second daemon": the new process exits with code 1 (it does not keep running), the socket file is the very same file as before (not removed and bound again), and the first daemon still answers with its state intact.
    @Test func aSecondDaemonOnTheSameSandboxExitsWithOneAndLeavesTheFirstOneServing() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let socketBefore = try #require(identity(of: daemon.socketPath), "the socket file is missing")
            let firstPid = try #require(daemon.pid)
            let second = try runDaemonProgram(["--daemon", "--sandbox", daemon.root, "--tick", "0.2", "--policy-fast"], timeout: 8)
            #expect(!second.timedOut, "the second daemon kept running. stderr: \(second.stderr)")
            #expect(second.status == 1 && !second.killedBySignal, "the second daemon exited with \(second.status). stderr: \(second.stderr)")

            #expect(daemon.isRunning && daemon.pid == firstPid, "the first daemon must not be disturbed")
            #expect(identity(of: daemon.socketPath) == socketBefore, "the second daemon removed or replaced the live socket")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com"])
            #expect(status.passwordSet)
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com")))
            // Commands still work end to end through the original socket.
            try daemon.send(.add, domain: "youtube.com").requireOK()
            #expect(daemon.hosts().blocks("youtube.com"))
        }
    }

    // 03 § DaemonRuntime "Second daemon": "Only a socket nobody answers on (left by a killed daemon) is removed and replaced." The control for the test above: after kill -9 the stale socket file is still there, and a new daemon takes it over and serves.
    @Test func aSocketLeftByAKilledDaemonIsReplacedByTheNextDaemon() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let before = try #require(identity(of: daemon.socketPath))
            daemon.kill9()
            #expect(identity(of: daemon.socketPath) == before, "kill -9 should leave the socket file behind")
            try daemon.start()
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com"])
            #expect(identity(of: daemon.socketPath) != before, "the stale socket file should have been replaced by a new one")
        }
    }
}

import Foundation
import SiteBlockCore
import Testing

// What the enforcement pass does and reports about the hosts file.
// Design: 03-daemon-cli-app.md § HostsEnforcer ("returns true when the file is correct after the pass", step 2: "If the result equals the current text, return true without writing"); 01-overview-and-data.md § Wire Protocol (`hostsFileHealthy`: true when the last enforcement pass found or left the hosts file in the right state); 02-core-components.md § Engine ("Hosts health").
@Suite("Hosts enforcement")
struct HostsEnforcementTests {
    // 03 § HostsEnforcer step 2: a pass that finds the file already right does not write it. The daemon runs a pass every 0.2 s; over 1.5 s (about seven passes) neither the inode nor the last-modified time of the hosts file may change, so a daemon that rewrote an unchanged file (even with identical text) is caught. A hand edit afterwards is repaired, which shows the passes really were running.
    @Test func aPassThatFindsTheFileAlreadyRightDoesNotWriteIt() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = daemon.hostsText()
            // Let every pass caused by the commands above finish before taking the first reading.
            pause(0.5)
            let first = try #require(identity(of: daemon.hostsPath), "the hosts file is missing")
            let watch = Stopwatch()
            var changedAt: Double?
            while watch.elapsed < 1.5 {
                if identity(of: daemon.hostsPath) != first {
                    changedAt = watch.elapsed
                    break
                }
                pause(0.02)
            }
            #expect(changedAt == nil, "the hosts file was rewritten \(String(describing: changedAt)) s into the check although it was already correct")
            #expect(daemon.hostsText() == expected)
            #expect(daemon.isRunning)

            // The passes are alive: a bypass line added by hand is removed, which rewrites the file.
            try writeText("151.101.1.140 reddit.com\n" + expected, to: daemon.hostsPath)
            let repaired = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(repaired != nil, "the daemon stopped enforcing; file now:\n\(daemon.hostsText())")
        }
    }

    // The same, for a file the user keeps tidy in their own way: user comments and unrelated lines around a correct section are not rewritten either.
    @Test func aCorrectFileWithTheUsersOwnLinesIsLeftUntouchedByEveryPass() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let edited = "# my notes about reddit.com\n10.0.0.5 intranet.example\n" + daemon.hostsText()
            try writeText(edited, to: daemon.hostsPath)
            pause(0.5)
            let first = try #require(identity(of: daemon.hostsPath))
            pause(1.5)
            #expect(identity(of: daemon.hostsPath) == first, "an already-correct file was rewritten")
            #expect(daemon.hostsText() == edited)
        }
    }

    // 01 § Wire Protocol (`hostsFileHealthy`) and 03 § HostsEnforcer: when the daemon cannot make the hosts file right, the status says so. The folder is made read-only (0555), so no temp file can be created, and the hosts file is made read-only too (0444), so it cannot be written in place either; both ways of writing are closed. The file is then changed through a handle opened beforehand, so the change arrives only when both locks are already in place. Within 1.5 s the status reports false. After the permissions are restored the daemon repairs the file and reports true again. The permissions are restored in a defer so a failure cannot leave an undeletable folder behind.
    @Test(.enabled(if: geteuid() != 0))
    func hostsFileHealthyIsFalseWhileTheFileCannotBeFixedAndTrueAgainOnceItCan() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            #expect(try daemon.status().hostsFileHealthy, "healthy before anything is wrong")
            let expected = daemon.hostsText()
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: daemon.hostsPath))
            defer {
                try? handle.close()
                try? chmodPath(daemon.root, 0o755)
                try? chmodPath(daemon.hostsPath, 0o644)
            }
            try chmodPath(daemon.hostsPath, 0o444)
            try chmodPath(daemon.root, 0o555)
            // Now damage the file through the handle that was opened while writing was still allowed.
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(StandardHosts.text.utf8))
            try handle.synchronize()
            try #require(daemon.hostsText() == StandardHosts.text, "the damage did not arrive")

            let unhealthy = waitUntil(timeout: 1.5, interval: 0.02) { (try? daemon.status().hostsFileHealthy) == false }
            #expect(unhealthy != nil, "hostsFileHealthy never turned false although the file could not be repaired for 1.5 s")
            #expect(daemon.hostsText() == StandardHosts.text, "nothing could have been written")
            #expect(daemon.isRunning)

            try chmodPath(daemon.root, 0o755)
            try chmodPath(daemon.hostsPath, 0o644)
            let repaired = waitUntil(timeout: 2.0, interval: 0.02) { daemon.hostsText() == expected }
            #expect(repaired != nil, "the file was not repaired after the permissions came back; file now:\n\(daemon.hostsText())")
            let healthy = waitUntil(timeout: 1.5, interval: 0.02) { (try? daemon.status().hostsFileHealthy) == true }
            #expect(healthy != nil, "hostsFileHealthy stayed false after the file was repaired")
            #expect(daemon.logContains("hosts file repaired", within: 1.0))
        }
    }
}

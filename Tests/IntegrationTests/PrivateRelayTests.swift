import Foundation
import SiteBlockCore
import Testing

// The two iCloud Private Relay names the daemon always keeps in its hosts section.
// Design: 01-overview-and-data.md § How Blocking Works (the Adult content filter paragraph: the filter is always on, so `mask.icloud.com` and `mask-h2.icloud.com` are always written into the section, even with no site on the block list); 02-core-components.md § Engine (`privateRelayHosts`, `hostsToWrite`: includes the names whenever `adultFilterActive`, which is always); 03-daemon-cli-app.md § HostsEnforcer (the runtime writes `hostsToWrite`).
// Design change: these tests used to expect the names only while a site was blocked, and no section at all otherwise.
// The names are spelled out literally here, not read from the code.
@Suite("iCloud Private Relay names")
struct PrivateRelayTests {
    static let relayNames = ["mask.icloud.com", "mask-h2.icloud.com"]
    static let password = SandboxDaemon.password

    // Even with nothing blocked, both relay names have an IPv4 line and an IPv6 line, each exactly once. With one site blocked they still do, and the file is exactly the site's hosts plus the two names.
    @Test func bothPrivateRelayNamesAreBlockedInBothAddressFamiliesBeforeAndAfterBlockingASite() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.setUp()
            let beforeAnyBlock = daemon.hosts()
            for name in Self.relayNames {
                #expect(beforeAnyBlock.count(of: "0.0.0.0 \(name)") == 1, "\(name) must be blocked even while nothing is blocked")
                #expect(beforeAnyBlock.count(of: ":: \(name)") == 1)
            }
            try daemon.send(.add, domain: "reddit.com").requireOK()
            // Read at once: only the command path (the tick never fires) can have written it.
            let hosts = daemon.hosts()
            for name in Self.relayNames {
                #expect(hosts.count(of: "0.0.0.0 \(name)") == 1, "0.0.0.0 \(name)")
                #expect(hosts.count(of: ":: \(name)") == 1, ":: \(name)")
            }
            #expect(hosts.text == ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com")))
            let status = try daemon.status()
            #expect(status.blocked.first?.hosts == ExpectedHosts.expand("reddit.com"), "the relay names belong to the section, not to any one site's host list")
        }
    }

    // A second blocked site does not write the relay names a second time: the file holds exactly one IPv4 line and one IPv6 line for each name.
    @Test func twoBlockedSitesStillShareOnePairOfRelayLines() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "youtube.com")
            let hosts = daemon.hosts()
            for name in Self.relayNames {
                #expect(hosts.count(of: "0.0.0.0 \(name)") == 1)
                #expect(hosts.count(of: ":: \(name)") == 1)
            }
            #expect(hosts.text == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["reddit.com", "youtube.com"])))
        }
    }

    // The relay names stay while an unblock is still counting down (the site is still blocked), and they stay after the LAST site is gone after the 2 s delay: the section is then only the two names.
    @Test func relayNamesStayWhileAnUnblockRunsAndAfterTheLastSiteIsUnblocked() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            // Sent at a random point of the 0.2 s tick cycle, with the stopwatch started BEFORE the request: the section may not go before 2.0 s (03 § DaemonRuntime "Before every command").
            let phase = daemon.pauseToRandomTickPhase()
            let watch = Stopwatch()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            pause(1.0 - watch.elapsed)
            let midway = daemon.hosts()
            for name in Self.relayNames { #expect(midway.blocks(name), "\(name) must stay while the countdown runs") }

            let removed = waitUntil(timeout: 3.5, interval: 0.02) { daemon.hostsText() == ExpectedHosts.idleText }
            let took = watch.elapsed
            #expect(removed != nil, "the site's lines did not go away; file:\n\(daemon.hostsText())")
            #expect(took >= 2.0, "the site's lines went \(took) s after the request, before the 2 s delay was over (request sent \(phase) s into a tick)")
            #expect(took < 4.0)
            let after = daemon.hosts()
            for name in Self.relayNames { #expect(after.blocks(name), "\(name) must stay: the adult content filter is always on") }
            #expect(after.beginCount == 1 && after.endCount == 1)
            #expect(!after.blocks("reddit.com"))
        }
    }

    // With two sites blocked, unblocking one keeps the section and the relay names, because a site is still blocked.
    @Test func unblockingOneOfTwoSitesKeepsTheRelayNames() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "youtube.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let afterwards = ExpectedHosts.text(blocking: ExpectedHosts.expand("youtube.com"))
            let took = waitUntil(timeout: 4.0, interval: 0.02) { daemon.hostsText() == afterwards }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
            let hosts = daemon.hosts()
            for name in Self.relayNames { #expect(hosts.blocks(name)) }
        }
    }

    // 02 § HostsFileEditor render step 3 applied to the relay names: while a site is blocked, a user line that points one of them at a real address is a bypass line and is removed (macOS would otherwise use the first match).
    @Test(arguments: [
        "17.0.0.1 mask.icloud.com",
        "17.0.0.1 mask-h2.icloud.com",
        "17.0.0.1\tmask.icloud.com",
        "17.0.0.1 MASK.ICLOUD.COM",
        "17.0.0.1 mask.icloud.com.",
        "17.0.0.1 mask.icloud.com mask-h2.icloud.com",
        "17.0.0.1 mask.icloud.com # keep Private Relay on",
    ])
    func aBypassLineForARelayNameIsRemovedWhileASiteIsBlocked(bypass: String) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            // The first pass of the daemon logged a repair too, so the repair of the bypass line is the NEXT line, not just any line (see waitForLogCount).
            let repairsBefore = daemon.logCount(of: "hosts file repaired")
            try writeText(bypass + "\n" + expected, to: daemon.hostsPath)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "bypass line not removed within 1 s; file now:\n\(daemon.hostsText())")
            #expect(daemon.waitForLogCount(of: "hosts file repaired", atLeast: repairsBefore + 1), "the repair was not logged; log:\n\(daemon.logText())")
        }
    }

    // Design change: the section and the relay names exist even when nothing is blocked, so the same user line is a bypass line then too, and it is removed within a second and logged. (Before, it was left alone while nothing was blocked.)
    @Test(arguments: ["17.0.0.1 mask.icloud.com", "17.0.0.1 mask-h2.icloud.com", "17.0.0.1 mask.icloud.com mask-h2.icloud.com"])
    func aBypassLineForARelayNameIsRemovedEvenWhenNothingIsBlocked(userLine: String) throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let repairsBefore = daemon.logCount(of: "hosts file repaired")
            try writeText(userLine + "\n" + ExpectedHosts.idleText, to: daemon.hostsPath)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == ExpectedHosts.idleText }
            #expect(took != nil, "bypass line not removed within 1 s; file now:\n\(daemon.hostsText())")
            // The daemon renames the repaired file into place first and writes its log line just after, so a test that has seen the file change must wait for the new line before it counts. (The first pass logged a repair too, so a plain "the log contains the line" check is already true and waits for nothing.)
            #expect(daemon.waitForLogCount(of: "hosts file repaired", atLeast: repairsBefore + 1), "the repair was not logged; log:\n\(daemon.logText())")
            #expect(daemon.logCount(of: "hosts file repaired") == repairsBefore + 1)
        }
    }

    // Deleting only the relay lines from the section is repaired within 1 s, like any other hand edit of the section.
    @Test func removingJustTheRelayLinesFromTheSectionIsRepairedWithinOneSecond() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            var damaged = expected
            for name in Self.relayNames {
                damaged = damaged.replacingOccurrences(of: "0.0.0.0 \(name)\n", with: "").replacingOccurrences(of: ":: \(name)\n", with: "")
            }
            try #require(damaged != expected && !damaged.contains("icloud"))
            try writeText(damaged, to: daemon.hostsPath)
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == expected }
            #expect(took != nil, "relay lines not restored within 1 s; file now:\n\(daemon.hostsText())")
        }
    }

    // After a restart the relay names are written again at boot (before any client connects); and a daemon that starts with every state file lost has nothing to block, but the names stay, because the adult content filter is always on.
    @Test func relayNamesComeBackAtBootAndStayWhenTheStateIsLost() throws {
        try withDaemon(tick: BlockingTests.neverTick) { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let expected = daemon.hostsText()
            daemon.terminate()
            try writeText(StandardHosts.text, to: daemon.hostsPath)
            try daemon.start(serve: false)
            let back = waitUntil(timeout: 3.0, interval: 0.02) { daemon.hostsText() == expected }
            #expect(back != nil, "boot pass did not restore the section with the relay names:\n\(daemon.hostsText())")
            try daemon.waitUntilServing()

            daemon.kill9()
            try FileManager.default.removeItem(atPath: daemon.statePath)
            try FileManager.default.removeItem(atPath: daemon.stateBackupPath)
            try daemon.start()
            #expect(daemon.hostsText() == ExpectedHosts.idleText, "no state means nothing blocked, so the section holds only the relay names")
        }
    }
}

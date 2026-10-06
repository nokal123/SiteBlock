import Foundation
import SiteBlockCore
import Testing

// The cap on blocked sites. 02-core-components.md § Engine "Site cap": a new site is refused with `tooManySites` when `policy.maxSites` sites are already blocked; `Policy.fastForTests.maxSites` is 20. Re-adding an existing site is not affected.
// If these fail only because the daemon has no cap yet, they are waiting on the source change.
@Suite("Site cap")
struct SiteCapTests {
    static let password = SandboxDaemon.password

    // Sends `add` as raw JSON and returns the reply, so the error code can be read as a plain string even by a build that does not know the code yet.
    static func rawAdd(_ domain: String, to daemon: SandboxDaemon) throws -> RawReply {
        try rawExchange(try requestLine(["command": "add", "domain": domain]), socketPath: daemon.socketPath)
    }

    // The domain names used to fill the cap.
    static func domain(_ n: Int) -> String { "cap\(n).example.org" }

    // 02 § Engine "Site cap" and 01 § Commands: twenty sites fit, the twenty-first gets tooManySites and changes nothing, and re-adding a blocked site is still alreadyBlocked rather than tooManySites.
    @Test func theTwentyFirstSiteIsRefusedWithTooManySitesAndChangesNothing() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            for n in 1...20 { try daemon.block(Self.domain(n)) }
            let full = (1...20).map(Self.domain)
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand(all: full))
            #expect(daemon.hostsText() == expected)

            let refused = try Self.rawAdd("one-too-many.example.org", to: daemon)
            #expect(refused.ok == false)
            #expect(refused.errorCode == "tooManySites", "got: \(refused.text.prefix(200))")
            #expect(daemon.hostsText() == expected, "a refused add must not touch the hosts file")
            let status = try daemon.status()
            #expect(status.blocked.count == 20)

            let again = try Self.rawAdd(Self.domain(7), to: daemon)
            #expect(again.errorCode == "alreadyBlocked", "re-adding an existing site is not a cap error: \(again.text.prefix(200))")
        }
    }

    // 02 § Engine "Site cap": re-adding a site that has an unblock pending (which cancels the unblock) works even when the cap is reached. Once an unblock finishes, there is room for a new site again.
    @Test func atTheCapAnUnblockCanBeCancelledAndAFinishedUnblockMakesRoom() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            for n in 1...20 { try daemon.block(Self.domain(n)) }
            try daemon.requireTwoSecondDelay()
            try daemon.send(.unblock, domain: Self.domain(1), password: Self.password).requireOK()
            let cancel = try daemon.send(.add, domain: Self.domain(1)).requireOK()
            #expect(cancel.message == "Unblock cancelled; \(Self.domain(1)) stays blocked.")

            try daemon.send(.unblock, domain: Self.domain(2), password: Self.password).requireOK()
            let gone = waitUntil(timeout: 4.0, interval: 0.05) { !daemon.hosts().blocks(Self.domain(2)) }
            #expect(gone != nil)
            let status = try daemon.status()
            #expect(status.blocked.count == 19)
            try daemon.send(.add, domain: "room-now.example.org").requireOK()
            let refused = try Self.rawAdd("full-again.example.org", to: daemon)
            #expect(refused.errorCode == "tooManySites")
        }
    }
}

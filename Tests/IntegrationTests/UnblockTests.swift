import Foundation
import SiteBlockCore
import Testing

// Unblocking, cancelling, lockout and delay rules, against the real siteblockd running with --policy-fast (default delay 2 s, lockout 2 s).
// Design: 01-overview-and-data.md § Commands, § Fixed Policy Values; 02-core-components.md § Engine.
@Suite("Unblock, lockout and delay")
struct UnblockTests {
    static let password = SandboxDaemon.password

    // 05 Integration Tests, fourth bullet (first half): a wrong password is refused and the site stays blocked with no countdown.
    @Test func unblockWithTheWrongPasswordIsRefusedAndStartsNoCountdown() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let before = daemon.hostsText()
            let reply = try daemon.send(.unblock, domain: "reddit.com", password: "not-the-password")
            #expect(reply.ok == false)
            #expect(reply.errorCode == .wrongPassword)
            #expect(reply.error?.isEmpty == false)
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com"])
            #expect(status.blocked.first?.unblockSecondsRemaining == nil)
            pause(0.5)
            #expect(daemon.hostsText() == before)
        }
    }

    // 05 Integration Tests, fourth bullet (second half): with the right password the site stays in the hosts file for the full delay (2 s), then disappears.
    @Test func unblockWithTheRightPasswordKeepsTheSiteBlockedForTheFullDelayThenRemovesIt() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let blocked = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let reply = try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let watch = Stopwatch()
            let remaining = try #require(reply.status?.blocked.first?.unblockSecondsRemaining)
            #expect((1...2).contains(remaining), "the countdown starts at the 2 s delay, got \(remaining)")
            #expect(reply.message?.contains("reddit.com") == true)
            #expect(daemon.hostsText() == blocked, "the hosts file keeps the block while the countdown runs")

            pause(1.0 - watch.elapsed)
            #expect(daemon.hostsText() == blocked, "1 s into a 2 s delay the site must still be blocked")
            let midway = try daemon.status()
            #expect(midway.blocked.map(\.domain) == ["reddit.com"])
            #expect(midway.blocked.first?.unblockSecondsRemaining == 1)

            let removedAfter = waitUntil(timeout: 3.5, interval: 0.02) { daemon.hostsText() == StandardHosts.text }
            let tookTotal = watch.elapsed
            #expect(removedAfter != nil, "the block was not removed within 3.5 s after the 2 s delay; file:\n\(daemon.hostsText())")
            #expect(tookTotal >= 1.8, "the block was removed after only \(tookTotal) s of a 2 s delay")
            let done = try daemon.status()
            #expect(done.blocked.isEmpty)
            #expect(done.passwordSet)
            let saved = try #require(daemon.stateObject())
            #expect((saved["blocked"] as? [Any])?.isEmpty == true, "the finished unblock is saved to state.json")
        }
    }

    // 02 § Engine: a second unblock does not restart the countdown. After 1.1 s of a 2 s delay the second reply must show at most 1 s left.
    @Test func aSecondUnblockDoesNotRestartTheCountdown() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let watch = Stopwatch()
            pause(1.1)
            let second = try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let remaining = try #require(second.status?.blocked.first?.unblockSecondsRemaining)
            #expect(remaining <= 1, "a restarted countdown would show 2; got \(remaining)")
            let removedAfter = waitUntil(timeout: 3.0, interval: 0.02) { daemon.hostsText() == StandardHosts.text }
            #expect(removedAfter != nil)
            #expect(watch.elapsed < 3.2, "the site should be gone about 2 s after the FIRST unblock")
        }
    }

    // 01 § Commands: cancelUnblock needs no password, and the site stays blocked after the delay would have passed.
    @Test func cancelUnblockWithoutAPasswordKeepsTheSiteBlockedPastTheDelay() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            try daemon.send(.cancelUnblock, domain: "reddit.com").requireOK()
            let status = try daemon.status()
            #expect(status.blocked.first?.unblockSecondsRemaining == nil)
            pause(3.2)
            #expect(daemon.hosts().blocks("reddit.com"))
            let later = try daemon.status()
            #expect(later.blocked.map(\.domain) == ["reddit.com"])
        }
    }

    // 02 § Engine: cancelling when nothing is pending fails with nothingPending.
    @Test func cancelUnblockWithNothingPendingFailsWithNothingPending() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let reply = try daemon.send(.cancelUnblock, domain: "reddit.com")
            #expect(reply.ok == false)
            #expect(reply.errorCode == .nothingPending)
        }
    }

    // 02 § Engine: add on a site with a pending unblock cancels the unblock and says so; a plain second add is alreadyBlocked.
    @Test func addOnAPendingSiteCancelsTheUnblockAndKeepsItBlocked() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
            let reply = try daemon.send(.add, domain: "reddit.com").requireOK()
            #expect(reply.message == "Unblock cancelled; reddit.com stays blocked.")
            #expect(reply.status?.blocked.first?.unblockSecondsRemaining == nil)
            pause(3.2)
            #expect(daemon.hosts().blocks("reddit.com"))
            let again = try daemon.send(.add, domain: "reddit.com")
            #expect(again.errorCode == .alreadyBlocked)
        }
    }

    // 02 § Engine: removing a site must keep the host names another blocked site still needs. x.com and twitter.com list each other's names, so twitter.com's names must survive x.com's unblock.
    @Test func unblockingOneSiteKeepsTheHostNamesAnotherBlockedSiteSharesWithIt() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "x.com", "twitter.com")
            try daemon.requireTwoSecondDelay()
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["x.com", "twitter.com"])))
            try daemon.send(.unblock, domain: "x.com", password: Self.password).requireOK()
            let afterwards = ExpectedHosts.text(blocking: ExpectedHosts.expand("twitter.com"))
            let took = waitUntil(timeout: 4.0, interval: 0.02) { daemon.hostsText() == afterwards }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["twitter.com"])
        }
    }

    // MARK: Lockout

    // 01 § Fixed Policy Values: five wrong passwords start a lockout; the sixth attempt is refused with lockedOut even with the right password; the lockout then ends.
    @Test func fiveWrongPasswordsLockOutEvenTheRightPasswordUntilTheLockoutEnds() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for attempt in 1...5 {
                let reply = try daemon.send(.unblock, domain: "reddit.com", password: "wrong-\(attempt)")
                #expect(reply.errorCode == .wrongPassword, "attempt \(attempt)")
            }
            let locked = try daemon.status()
            let lockoutSeconds = try #require(locked.lockoutSecondsRemaining)
            #expect((1...2).contains(lockoutSeconds))
            let refused = try daemon.send(.unblock, domain: "reddit.com", password: Self.password)
            #expect(refused.ok == false)
            #expect(refused.errorCode == .lockedOut)
            let still = try daemon.status()
            #expect(still.blocked.first?.unblockSecondsRemaining == nil, "a password during lockout must not start an unblock")
            let ended = waitUntil(timeout: 4.0, interval: 0.05) { (try? daemon.status().lockoutSecondsRemaining) == nil }
            #expect(ended != nil, "the 2 s lockout did not end")
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
        }
    }

    // 02 § Engine, command rules: unblock finds the site (notBlocked) BEFORE it checks the password, so guessing at unknown names never uses up a try.
    @Test func unblockingASiteThatIsNotBlockedNeverCountsAsAWrongPassword() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            for attempt in 1...12 {
                let reply = try daemon.send(.unblock, domain: "never-blocked.example", password: "wrong-\(attempt)")
                #expect(reply.errorCode == .notBlocked, "attempt \(attempt)")
            }
            let status = try daemon.status()
            #expect(status.lockoutSecondsRemaining == nil)
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
        }
    }

    // MARK: Delay rules

    // 01 § Commands, 01 § Fixed Policy Values: a longer delay applies at once; a shorter one starts a pending change; the limits are enforced.
    @Test func delayChangesFollowTheCommandRules() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            let wrong = try daemon.send(.setDelay, password: "nope-nope", seconds: 300)
            #expect(wrong.errorCode == .wrongPassword)
            for bad in [0, -5, 604_801] {
                let reply = try daemon.send(.setDelay, password: Self.password, seconds: bad)
                #expect(reply.ok == false && reply.errorCode == .invalidDelay, "seconds \(bad)")
            }
            try daemon.send(.setDelay, password: Self.password, seconds: 300).requireOK()
            var status = try daemon.status()
            #expect(status.delaySeconds == 300, "a longer delay applies at once")
            #expect(status.pendingDelay == nil)

            try daemon.send(.setDelay, password: Self.password, seconds: 60).requireOK()
            status = try daemon.status()
            #expect(status.delaySeconds == 300, "a shorter delay must not apply at once")
            #expect(status.pendingDelay?.newDelaySeconds == 60)
            let wait = try #require(status.pendingDelay?.secondsRemaining)
            #expect((299...300).contains(wait), "the shorter delay waits out the CURRENT delay (300 s), got \(wait)")

            try daemon.send(.cancelDelayChange).requireOK()
            status = try daemon.status()
            #expect(status.pendingDelay == nil)
            #expect(status.delaySeconds == 300)
            let nothing = try daemon.send(.cancelDelayChange)
            #expect(nothing.errorCode == .nothingPending)

            try daemon.send(.setDelay, password: Self.password, seconds: 60).requireOK()
            try daemon.send(.setDelay, password: Self.password, seconds: 604_800).requireOK()
            status = try daemon.status()
            #expect(status.delaySeconds == 604_800, "the 7 day maximum is allowed")
            #expect(status.pendingDelay == nil, "a longer delay drops the pending change")
        }
    }
}

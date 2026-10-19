import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § TabRuleMatcher, "Rules for the tab watcher": `StatusSnapshot.watchedPathRules` turns a status snapshot into the list the tab watcher looks for: every path rule except one
// whose own temporary unblock is open, because the browsers' block lists do not hold an open rule. Rules waiting to open or waiting to unblock for good stay in, because they are still blocked. A snapshot from an older daemon with no path
// rules gives an empty list. 03 § TabWatcher adds that a path rule on a site whose whole site is open stays in the list, because the browsers still block that part of the site, and that the daemon's order is kept.

private let waitingStatus = TemporaryUnblockStatus(opensInSeconds: 600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
private let openStatus = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 900, windowSeconds: 1800, isOpen: true)

// A path rule status with the rule text built from its parts, the way the daemon reports it.
private func rule(_ domain: String, _ path: String, pending: Int? = nil, temporary: TemporaryUnblockStatus? = nil) -> BlockedPathStatus {
    BlockedPathStatus(domain: domain, path: path, rule: domain + path, unblockSecondsRemaining: pending, temporaryUnblock: temporary)
}

// A status snapshot holding these sites and rules and nothing else of interest.
private func snapshot(rules: [BlockedPathStatus]?, sites: [BlockedSiteStatus] = []) -> StatusSnapshot {
    StatusSnapshot(version: "1.0.0", passwordSet: true, blocked: sites, delaySeconds: 1800, pendingDelay: nil, uninstallSecondsRemaining: nil, recoverySecondsRemaining: nil, lockoutSecondsRemaining: nil, hostsFileHealthy: true, adultFilterEnabled: true, blockedPaths: rules)
}

@Suite struct WatchedPathRulesTests {
    // A rule whose own temporary unblock is open is allowed for now, so its tabs must be left alone and it is not watched.
    @Test func aRuleWhoseTemporaryUnblockIsOpenIsLeftOut() {
        let watched = snapshot(rules: [rule("youtube.com", "/shorts", temporary: openStatus)]).watchedPathRules
        #expect(watched.isEmpty)
    }

    // Rules that are still blocked stay in: a plain one, one waiting to open, and one waiting to unblock for good.
    @Test func rulesWaitingToOpenOrWaitingToUnblockForGoodStayIn() {
        let rules = [rule("a.example", "/plain"), rule("b.example", "/waiting", temporary: waitingStatus), rule("c.example", "/pending", pending: 600)]
        #expect(snapshot(rules: rules).watchedPathRules == [WatchedPathRule(domain: "a.example", path: "/plain"), WatchedPathRule(domain: "b.example", path: "/waiting"), WatchedPathRule(domain: "c.example", path: "/pending")])
    }

    // 03 § TabWatcher: "A path rule on a site whose whole site is temporarily open stays in the list, because the browsers still block that part of the site."
    @Test func aRuleOnASiteWhoseWholeSiteIsOpenStaysIn() {
        let wholeSite = BlockedSiteStatus(domain: "youtube.com", hosts: ["youtube.com"], unblockSecondsRemaining: nil, temporaryUnblock: openStatus)
        let watched = snapshot(rules: [rule("youtube.com", "/shorts")], sites: [wholeSite]).watchedPathRules
        #expect(watched == [WatchedPathRule(domain: "youtube.com", path: "/shorts")])
    }

    // Only the rule's OWN unblock counts: with the whole site open AND the rule open, the rule is left out; with the rule open and the site waiting, it is left out too.
    @Test func onlyTheRulesOwnTemporaryUnblockDecides() {
        let siteOpen = BlockedSiteStatus(domain: "youtube.com", hosts: ["youtube.com"], unblockSecondsRemaining: nil, temporaryUnblock: openStatus)
        let siteWaiting = BlockedSiteStatus(domain: "youtube.com", hosts: ["youtube.com"], unblockSecondsRemaining: nil, temporaryUnblock: waitingStatus)
        #expect(snapshot(rules: [rule("youtube.com", "/shorts", temporary: openStatus)], sites: [siteOpen]).watchedPathRules.isEmpty)
        #expect(snapshot(rules: [rule("youtube.com", "/shorts", temporary: openStatus)], sites: [siteWaiting]).watchedPathRules.isEmpty)
        #expect(snapshot(rules: [rule("youtube.com", "/shorts", temporary: waitingStatus)], sites: [siteOpen]).watchedPathRules.count == 1)
    }

    // No rules at all gives an empty list, whether the daemon sent an empty list or (an older daemon) no list.
    @Test func aSnapshotWithNoPathRulesGivesAnEmptyList() throws {
        #expect(snapshot(rules: nil).watchedPathRules.isEmpty)
        #expect(snapshot(rules: []).watchedPathRules.isEmpty)
        let older = #"{"blocked":[{"domain":"reddit.com","hosts":["reddit.com"]}],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":true,"version":"0.5.0"}"#
        let decoded = try JSONCoding.decoder.decode(StatusSnapshot.self, from: Data(older.utf8))
        #expect(decoded.watchedPathRules.isEmpty)
    }

    // The daemon's order is kept, with the open rules taken out of the middle and the ends.
    @Test func theOrderOfTheRulesIsKept() {
        let rules = [rule("a.example", "/1", temporary: openStatus), rule("b.example", "/2"), rule("c.example", "/3", temporary: waitingStatus), rule("d.example", "/4", temporary: openStatus), rule("e.example", "/5", pending: 5), rule("f.example", "/6", temporary: openStatus)]
        #expect(snapshot(rules: rules).watchedPathRules.map(\.domain) == ["b.example", "c.example", "e.example"])
        let reversed = Array(rules.reversed())
        #expect(snapshot(rules: reversed).watchedPathRules.map(\.domain) == ["e.example", "c.example", "b.example"])
    }

    // The watcher gets the domain and the path as stored, with the path's letter case kept (paths are case-sensitive), not the joined rule text.
    @Test func eachWatchedRuleCarriesTheDomainAndThePathWithItsCase() {
        let watched = snapshot(rules: [rule("x.com", "/Home"), rule("x.com", "/home")]).watchedPathRules
        #expect(watched == [WatchedPathRule(domain: "x.com", path: "/Home"), WatchedPathRule(domain: "x.com", path: "/home")])
        #expect(watched.count == Set(watched).count, "two rules that differ in case are two rules")
    }

    // A rule whose temporary unblock has a nil status is a plain rule; a status that is not open never removes a rule, whatever its other fields say.
    @Test func onlyTheOpenFlagRemovesARule() {
        let almostOpen = TemporaryUnblockStatus(opensInSeconds: 1, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
        let oddlyOpen = TemporaryUnblockStatus(opensInSeconds: 5, secondsRemaining: 10, windowSeconds: 1800, isOpen: true)
        #expect(snapshot(rules: [rule("a.example", "/x", temporary: almostOpen)]).watchedPathRules.count == 1)
        #expect(snapshot(rules: [rule("a.example", "/x", temporary: oddlyOpen)]).watchedPathRules.isEmpty)
    }

    // From a real engine: the list follows the rule through waiting, open and ended, and the other rules stay all along.
    @Test func aRealEngineSnapshotFollowsARuleThroughItsTemporaryUnblock() {
        let engine = makeEngine(policy: temporaryPolicy)
        for text in ["youtube.com/shorts", "x.com/Home", "reddit.com/r/all"] { expectSuccess(engine.send(.addPath, domain: text)) }
        let all = [WatchedPathRule(domain: "youtube.com", path: "/shorts"), WatchedPathRule(domain: "x.com", path: "/Home"), WatchedPathRule(domain: "reddit.com", path: "/r/all")]
        let without = [all[0], all[2]]
        func watched() -> [WatchedPathRule] { engine.send(.status).status?.watchedPathRules ?? [] }
        #expect(watched() == all)
        expectSuccess(engine.temporarily("x.com/Home", seconds: 600, start: 1800, rule: true))
        #expect(watched() == all, "waiting: still blocked, so still watched")
        _ = engine.tick(elapsed: 1800)
        #expect(watched() == without, "open: left out")
        _ = engine.tick(elapsed: 600)
        #expect(watched() == all, "ended: watched again")
        expectSuccess(engine.send(.unblockPath, domain: "reddit.com/r/all", password: rightPassword))
        #expect(watched() == all, "waiting to unblock for good: still blocked, still watched")
    }
}

import Foundation
import Testing
import SiteBlockCore

// What the daemon writes while a temporary unblock waits, is open and has ended, and what a status reply says about it. Expected values come from
// Design Plans/02-core-components.md § Engine (`blockedHosts`, `hostsToWrite`, "Browser block list", "Status of a temporary unblock"),
// 01-overview-and-data.md § How Blocking Works ("Temporary unblock") and § Wire Protocol (TemporaryUnblockStatus), and 03-daemon-cli-app.md § 9
// (the shortest list that covers every host, built from the sites that are not open). The covering lists are worked out by hand from the design's
// expansion rules (the base name, the common prefixes, the related-names table): a parent domain in the list covers its subdomains.

// The covering list the design gives for reddit.com: the four names that every other reddit name is a subdomain of.
private let redditCover = ["redd.it", "reddit.com", "redditmedia.com", "redditstatic.com"]
// The nine-entry covering list for youtube.com (the same list the path rule tests use).
private let youtubeCover = ["i.ytimg.com", "s.ytimg.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtube.googleapis.com", "youtubei.googleapis.com", "youtubekids.com", "yt3.ggpht.com"]

// The Firefox pattern for a whole-site entry.
private func firefoxSites(_ hosts: [String]) -> [String] { hosts.map { "*://*.\($0)/*" }.sorted() }

// MARK: the hosts file

@Suite struct TemporaryUnblockHostsTests {
    // 02 § Engine, blockedHosts: "Sites whose temporary unblock is waiting ... stay in. Sites whose temporary unblock is open are left out." After it ends they are back.
    @Test func aSitesNamesStayWhileItWaitsLeaveWhenItOpensAndComeBackWhenItEnds() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        let all = engine.blockedHosts
        let reddit = engine.site("reddit.com")?.hosts ?? []
        let example = engine.site("example.com")?.hosts ?? []
        #expect(reddit.contains("redd.it") && reddit.contains("www.reddit.com") && !example.isEmpty)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))

        #expect(engine.blockedHosts == all, "waiting: the site is blocked as usual")
        _ = engine.tick(elapsed: 1799)
        #expect(engine.blockedHosts == all, "one second before it opens it is still fully blocked")
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.blockedHosts == example, "open: only the other site's names are left")
        for name in ["reddit.com", "www.reddit.com", "m.reddit.com", "redd.it", "i.redd.it", "www.redd.it", "redditstatic.com", "redditmedia.com"] { #expect(!engine.blockedHosts.contains(name), "\(name) must not be blocked while the site is open") }
        for name in ["example.com", "www.example.com"] { #expect(engine.blockedHosts.contains(name)) }
        _ = engine.tick(elapsed: 599)
        #expect(engine.blockedHosts == example, "one second before the window ends it is still open")
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.blockedHosts == all, "ended: everything is written back")
    }

    // The runtime writes `hostsToWrite`: the blocked hosts plus the always-blocked names (Private Relay and DNS-over-HTTPS), sorted, no duplicates.
    @Test func theFileKeepsThePrivateRelayAndDoHNamesInEveryPhase() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let reddit = engine.site("reddit.com")?.hosts ?? []
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        #expect(engine.hostsToWrite == Array(Set(reddit + designAlwaysWrittenHosts)).sorted(), "waiting")
        _ = engine.tick(elapsed: 1800)
        #expect(engine.blockedHosts.isEmpty, "the only site is open")
        #expect(engine.hostsToWrite == designAlwaysWrittenHosts, "open: the section still holds the always-written names")
        _ = engine.tick(elapsed: 600)
        #expect(engine.hostsToWrite == Array(Set(reddit + designAlwaysWrittenHosts)).sorted(), "ended")
    }

    // 02 § Engine, blockedHosts: "A host that another blocked site, one that is not open, also lists stays in." x.com and twitter.com share the related-names list, so the names
    // of that list (twitter.com, x.com, api.*, the twimg.com names, and the www. and m. forms) belong to both, while old., new., amp., app. and web. in front of x.com belong to x.com alone.
    @Test func aNameThatAnotherSiteWhichIsNotOpenAlsoListsStaysBlocked() {
        let engine = makeEngine(blocking: ["x.com", "twitter.com"], policy: temporaryPolicy)
        let twitter = engine.site("twitter.com")?.hosts ?? []
        let shared = ["x.com", "twitter.com", "www.x.com", "m.x.com", "mobile.x.com", "mobile.twitter.com", "api.x.com", "api.twitter.com", "pbs.twimg.com", "abs.twimg.com", "video.twimg.com"]
        let onlyX = ["old.x.com", "new.x.com", "amp.x.com", "app.x.com", "web.x.com"]
        for name in shared { #expect(twitter.contains(name), "\(name) is in twitter.com's list by the design's table") }
        for name in onlyX { #expect(!twitter.contains(name), "\(name) is not in twitter.com's list") }
        openTemporaryUnblock(engine, "x.com")
        for name in shared { #expect(engine.blockedHosts.contains(name), "\(name) is shared with twitter.com, which is not open, so it stays blocked") }
        for name in onlyX { #expect(!engine.blockedHosts.contains(name), "\(name) belongs to x.com alone, which is open") }
        #expect(engine.blockedHosts == twitter, "exactly twitter.com's list is left")
    }

    // When both sites are open, the shared names have no blocker left and go too. When one of them is only waiting, the shared names stay.
    @Test func aSharedNameLeavesOnlyWhenEverySiteThatListsItIsOpen() {
        let engine = makeEngine(blocking: ["x.com", "twitter.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("x.com", seconds: 600, start: 1800))
        expectSuccess(engine.temporarily("twitter.com", seconds: 600, start: 7200))
        _ = engine.tick(elapsed: 1800)
        #expect(engine.temporaryUnblock(of: "x.com")?.isOpen == true && engine.temporaryUnblock(of: "twitter.com")?.isOpen == false)
        #expect(engine.blockedHosts.contains("twitter.com") && engine.blockedHosts.contains("x.com"), "twitter.com is only waiting, so its whole list is blocked")
        _ = engine.tick(elapsed: 600)
        _ = engine.tick(elapsed: 7200 - 1800 - 600)
        #expect(engine.temporaryUnblock(of: "twitter.com")?.isOpen == true && engine.temporaryUnblock(of: "x.com") == nil)
        #expect(engine.blockedHosts == engine.site("x.com")?.hosts, "x.com blocked again, twitter.com open: x.com's list is left")

        let both = makeEngine(blocking: ["x.com", "twitter.com"], policy: temporaryPolicy)
        expectSuccess(both.temporarily("x.com", seconds: 600, start: 1800))
        expectSuccess(both.temporarily("twitter.com", seconds: 600, start: 1800))
        _ = both.tick(elapsed: 1800)
        #expect(both.blockedHosts.isEmpty, "both open: no name is left")
    }

    // A site with a permanent unblock waiting is still blocked, so its names keep a shared name blocked just like a plain site does.
    @Test func aSiteWithAPermanentUnblockWaitingStillKeepsASharedNameBlocked() {
        let engine = makeEngine(blocking: ["x.com", "twitter.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("x.com", seconds: 600, start: 1800))
        _ = engine.tick(elapsed: 600)
        // The permanent unblock starts 600 s later, so when x.com opens at second 1800 it still has 600 s to run.
        expectSuccess(engine.send(.unblock, domain: "twitter.com", password: rightPassword))
        #expect(engine.tick(elapsed: 1200) == true)
        #expect(engine.temporaryUnblock(of: "x.com")?.isOpen == true && engine.site("twitter.com")?.pendingUnblock?.remainingSeconds == 600)
        #expect(engine.blockedHosts.contains("x.com") && engine.blockedHosts.contains("api.twitter.com"))
        #expect(!engine.blockedHosts.contains("old.x.com"))
    }

    // Names that belong to a site's subdomain are the subdomain site's own: opening example.com does not open a separate site sub.example.com.
    @Test func aSeparateSubdomainSiteStaysBlockedWhileTheParentIsOpen() {
        let engine = makeEngine(blocking: ["example.com", "sub.example.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine, "example.com")
        let sub = engine.site("sub.example.com")?.hosts ?? []
        #expect(sub.contains("sub.example.com") && sub.contains("www.sub.example.com"))
        #expect(engine.blockedHosts == sub)
        #expect(!engine.blockedHosts.contains("example.com") && !engine.blockedHosts.contains("www.example.com"))
    }

    // Other sites are not affected by a neighbour's temporary unblock in any phase.
    @Test func otherSitesStayBlockedInEveryPhase() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com", "example.org"], policy: temporaryPolicy)
        let others = Set((engine.site("example.com")?.hosts ?? []) + (engine.site("example.org")?.hosts ?? []))
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        #expect(others.isSubset(of: Set(engine.blockedHosts)))
        _ = engine.tick(elapsed: 1800)
        #expect(Set(engine.blockedHosts) == others)
        _ = engine.tick(elapsed: 600)
        #expect(others.isSubset(of: Set(engine.blockedHosts)) && engine.blockedHosts.contains("reddit.com"))
    }

    // A path rule's temporary unblock never touches the hosts file: the hosts file holds whole names only.
    @Test(arguments: ["waiting", "open", "ended"])
    func aPathRulesTemporaryUnblockNeverChangesTheHostsList(phase: String) {
        let engine = makeEngine(blocking: ["example.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        let hosts = engine.hostsToWrite
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 600, start: 1800, rule: true))
        if phase != "waiting" { _ = engine.tick(elapsed: 1800) }
        if phase == "ended" { _ = engine.tick(elapsed: 600) }
        #expect(engine.hostsToWrite == hosts, "\(phase)")
        #expect((engine.temporaryUnblock(ofRule: "youtube.com", "/shorts")?.isOpen ?? false) == (phase == "open"), "\(phase): open only in the open phase")
        #expect((engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == nil) == (phase == "ended"), "\(phase): gone only after the end")
    }
}

// MARK: the browsers' block lists

@Suite struct TemporaryUnblockBrowserListTests {
    // 02 § Engine, Browser block list: "A site whose temporary unblock is waiting stays in the lists." Open: left out. Ended: back. Both browsers' lists.
    @Test func aSitesEntriesStayWhileItWaitsLeaveWhenItOpensAndComeBackWhenItEnds() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        let full = (chrome: (redditCover + ["example.com"]).sorted(), firefox: firefoxSites(redditCover + ["example.com"]))
        #expect(engine.browserBlockEntries.chrome == full.chrome && engine.browserBlockEntries.firefox == full.firefox, "before: the design's covering lists")
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        #expect(engine.browserBlockEntries.chrome == full.chrome && engine.browserBlockEntries.firefox == full.firefox, "waiting")
        _ = engine.tick(elapsed: 1800)
        #expect(engine.browserBlockEntries.chrome == ["example.com"], "open: reddit's entries are gone from the Chrome list")
        #expect(engine.browserBlockEntries.firefox == ["*://*.example.com/*"], "open: and from the Firefox list")
        _ = engine.tick(elapsed: 600)
        #expect(engine.browserBlockEntries.chrome == full.chrome && engine.browserBlockEntries.firefox == full.firefox, "ended")
    }

    // The lists for the one-site case are empty while it is open (the policy files then leave the list key out).
    @Test func theListsAreEmptyWhileTheOnlySiteIsOpen() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine, window: 600)
        #expect(engine.browserBlockEntries.chrome.isEmpty && engine.browserBlockEntries.firefox.isEmpty)
        let lists = engine.browserBlockLists
        #expect(lists.chrome.isEmpty && lists.firefox.isEmpty)
    }

    // The shortest cover is worked out from the sites that are not open. With twitter.com not open, x.com's own entry is still needed, because twitter.com's list contains x.com.
    @Test func theCoverIsBuiltFromTheSitesThatAreNotOpen() {
        let engine = makeEngine(blocking: ["x.com", "twitter.com"], policy: temporaryPolicy)
        let cover = ["abs.twimg.com", "pbs.twimg.com", "twitter.com", "video.twimg.com", "x.com"]
        #expect(engine.browserBlockEntries.chrome == cover)
        openTemporaryUnblock(engine, "x.com", window: 600)
        #expect(engine.browserBlockEntries.chrome == cover, "x.com is open but twitter.com lists x.com, so the entry stays")
        #expect(engine.browserBlockEntries.firefox == firefoxSites(cover))
    }

    // A subdomain site next to its open parent: the parent's entry is gone, so the subdomain's own entry is what is left (not the parent's).
    @Test func aSubdomainSiteKeepsItsOwnEntryWhileTheParentIsOpen() {
        let engine = makeEngine(blocking: ["example.com", "sub.example.com"], policy: temporaryPolicy)
        #expect(engine.browserBlockEntries.chrome == ["example.com"], "the parent covers the subdomain")
        openTemporaryUnblock(engine, "example.com")
        #expect(engine.browserBlockEntries.chrome == ["sub.example.com"])
        #expect(engine.browserBlockEntries.firefox == ["*://*.sub.example.com/*"])
    }

    // A path rule with its own temporary unblock: in the lists while it waits, left out while open, back after.
    @Test func aRulesEntryStaysWhileItsOwnUnblockWaitsLeavesWhenItOpensAndComesBack() {
        let engine = makeEngine(blocking: ["example.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.send(.addPath, domain: "x.com/Home"))
        let both = (chrome: ["example.com", "x.com/Home", "youtube.com/shorts"], firefox: ["*://*.example.com/*", "*://*.x.com/Home*", "*://*.youtube.com/shorts*"])
        #expect(engine.browserBlockEntries.chrome == both.chrome && engine.browserBlockEntries.firefox == both.firefox)
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 600, start: 1800, rule: true))
        #expect(engine.browserBlockEntries.chrome == both.chrome && engine.browserBlockEntries.firefox == both.firefox, "waiting")
        _ = engine.tick(elapsed: 1800)
        #expect(engine.browserBlockEntries.chrome == ["example.com", "x.com/Home"], "open: only the other rule and the site are left")
        #expect(engine.browserBlockEntries.firefox == ["*://*.example.com/*", "*://*.x.com/Home*"])
        _ = engine.tick(elapsed: 600)
        #expect(engine.browserBlockEntries.chrome == both.chrome && engine.browserBlockEntries.firefox == both.firefox, "ended")
    }

    // 01 § How Blocking Works: "a path rule on a site whose whole site is open stays in them, because that rule is what keeps that part of the site blocked."
    // While the whole site waits, the site's covering entries are in the lists and the rule is redundant; while the whole site is open the rule is the only entry; after it ends the rule is redundant again.
    @Test func aRuleOnASiteWhoseWholeSiteIsOpenIsInTheLists() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        #expect(engine.browserBlockEntries.chrome == youtubeCover, "the whole site covers the rule")
        expectSuccess(engine.temporarily("youtube.com", seconds: 600, start: 1800))
        #expect(engine.browserBlockEntries.chrome == youtubeCover, "waiting")
        _ = engine.tick(elapsed: 1800)
        #expect(engine.temporaryUnblock(of: "youtube.com")?.isOpen == true)
        #expect(engine.browserBlockEntries.chrome == ["youtube.com/shorts"], "open: the rule is what still blocks that part of the site")
        #expect(engine.browserBlockEntries.firefox == ["*://*.youtube.com/shorts*"])
        #expect(engine.blockedHosts.isEmpty, "the hosts file has nothing for the open site (it cannot hold a path)")
        _ = engine.tick(elapsed: 600)
        #expect(engine.browserBlockEntries.chrome == youtubeCover, "ended: the whole site covers the rule again")
        #expect(engine.browserBlockEntries.firefox == firefoxSites(youtubeCover))
    }

    // Both the whole site and the rule open at once: nothing is left for that domain, in either list.
    @Test func whenTheWholeSiteAndTheRuleAreBothOpenNothingIsLeft() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        expectSuccess(engine.temporarily("youtube.com", seconds: 600, start: 1800))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 600, start: 1800, rule: true))
        _ = engine.tick(elapsed: 1800)
        #expect(engine.browserBlockEntries.chrome.isEmpty && engine.browserBlockEntries.firefox.isEmpty)
    }

    // A rule whose domain is covered by a whole-site block that is NOT open is redundant, whatever its own unblock does.
    @Test func aRuleCoveredByABlockedSiteStaysRedundantWhateverItsOwnUnblockDoes() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 600, start: 1800, rule: true))
        _ = engine.tick(elapsed: 1800)
        #expect(engine.browserBlockEntries.chrome == youtubeCover)
    }

    // Other rules and sites are not affected by one rule's unblock, and the rule on another domain of the same kind is separate.
    @Test func aRulesTemporaryUnblockDoesNotChangeTheSiteLists() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        openTemporaryUnblock(engine, "youtube.com/shorts", rule: true)
        #expect(engine.browserBlockEntries.chrome == redditCover)
        #expect(engine.blockedHosts.contains("reddit.com"))
    }
}

// MARK: the status reply

@Suite struct TemporaryUnblockStatusTests {
    // 02 § Engine, Status of a temporary unblock: while waiting, `opensInSeconds` is the start wait, `secondsRemaining` is the full window, `windowSeconds` the window, `isOpen` false.
    @Test(arguments: [false, true])
    func aWaitingOneReportsTheStartWaitAndTheFullWindow(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.status == TemporaryUnblockStatus(opensInSeconds: 10, secondsRemaining: 100, windowSeconds: 100, isOpen: false))
        _ = subject.engine.tick(elapsed: 3)
        #expect(subject.status == TemporaryUnblockStatus(opensInSeconds: 7, secondsRemaining: 100, windowSeconds: 100, isOpen: false), "the window length does not change while waiting")
    }

    // 01 § Wire Protocol: "opensInSeconds ... rounded up; nil once it is open". 05 § Unit Tests: "remainders round up, so 0.2 seconds left reports 1".
    @Test(arguments: [(0.0, 10), (0.125, 10), (1.0, 9), (8.875, 2), (9.0, 1), (9.8, 1), (9.875, 1), (9.9, 1)])
    func theStartWaitRoundsUp(elapsed: Double, expected: Int) {
        let subject = TickSubject(rule: false, start: 10, window: 100)
        if elapsed > 0 { _ = subject.engine.tick(elapsed: elapsed) }
        #expect(subject.status?.opensInSeconds == expected, "\(10 - elapsed) s left")
        #expect(subject.status?.isOpen == false)
    }

    // 02 § Engine: "`secondsRemaining` is ... `window.displaySeconds` (rounded up) while open", `opensInSeconds` is nil, `isOpen` true, `windowSeconds` the chosen length.
    @Test(arguments: [(0.0, 100), (0.125, 100), (1.0, 99), (50.5, 50), (99.0, 1), (99.875, 1), (99.9, 1)])
    func anOpenOneReportsTheRestOfTheWindowRoundedUp(into: Double, expected: Int) {
        let subject = TickSubject(rule: false, start: 10, window: 100)
        _ = subject.engine.tick(elapsed: 10 + into)
        #expect(subject.status == TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: expected, windowSeconds: 100, isOpen: true), "\(into) s into the window")
    }

    // The tick that opens it with a surplus: the status is read straight after, with the window reduced by the surplus.
    @Test func theTickThatCrossesTheOpeningReportsTheReducedWindow() {
        let subject = TickSubject(rule: true, start: 10, window: 100)
        _ = subject.engine.tick(elapsed: 40.5)
        #expect(subject.status == TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 70, windowSeconds: 100, isOpen: true), "69.5 s left rounds up to 70")
    }

    // After it ends, the entry reports none, and so does an entry that never had one.
    @Test func afterTheEndAndForEntriesWithoutOneTheStatusIsNil() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: .fastForTests)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.send(.addPath, domain: "x.com/Home"))
        expectSuccess(engine.temporarily("reddit.com", seconds: 5, start: 5))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 5, start: 5, rule: true))
        #expect(engine.temporaryStatus(of: "example.com") == nil && engine.temporaryStatus(ofRule: "x.com/Home") == nil)
        #expect(engine.temporaryStatus(of: "reddit.com") != nil && engine.temporaryStatus(ofRule: "youtube.com/shorts") != nil)
        _ = engine.tick(elapsed: 10)
        #expect(engine.temporaryStatus(of: "reddit.com") == nil && engine.temporaryStatus(ofRule: "youtube.com/shorts") == nil)
        #expect(engine.send(.status).status?.blocked.map(\.domain) == ["reddit.com", "example.com"])
    }

    // The window lengths of the choices all come back as the same number in `windowSeconds`.
    @Test(arguments: [300, 900, 1800, 3600, 7200, 14_400])
    func windowSecondsIsTheChosenWindow(window: Int) {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: window, start: 1800))
        #expect(engine.temporaryStatus(of: "reddit.com")?.windowSeconds == window)
        #expect(engine.temporaryStatus(of: "reddit.com")?.secondsRemaining == window)
        _ = engine.tick(elapsed: 1800 + 100)
        #expect(engine.temporaryStatus(of: "reddit.com")?.windowSeconds == window, "still the chosen length while the time left counts down")
        #expect(engine.temporaryStatus(of: "reddit.com")?.secondsRemaining == window - 100)
    }

    // A temporary unblock is not shown as a permanent unblock countdown, and a permanent one is not shown as a temporary one.
    @Test func theTwoKindsOfUnblockAreReportedInTheirOwnFields() {
        let engine = makeScenarioEngine()
        let status = engine.send(.status).status
        let pending = status?.blocked.first { $0.domain == "pending.example" }
        let temp = status?.blocked.first { $0.domain == "temp.example" }
        let plain = status?.blocked.first { $0.domain == "plain.example" }
        #expect(pending?.unblockSecondsRemaining == 1800 && pending?.temporaryUnblock == nil)
        #expect(temp?.unblockSecondsRemaining == nil && temp?.temporaryUnblock == TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false))
        #expect(plain?.unblockSecondsRemaining == nil && plain?.temporaryUnblock == nil)
        let rules = status?.blockedPaths
        #expect(rules?.first { $0.rule == "rulepending.example/shorts" }?.temporaryUnblock == nil)
        #expect(rules?.first { $0.rule == "ruletemp.example/shorts" }?.temporaryUnblock == TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false))
        #expect(rules?.first { $0.rule == "ruletemp.example/shorts" }?.unblockSecondsRemaining == nil)
    }

    // 01 § Data Model: a temporary unblock is open only while "window.remainingSeconds > 0". A record that is already finished (both countdowns at 0, as a state file can hold before the next tick
    // removes it) is not open: the status says so, and the site's names are still in the block list.
    @Test func aFinishedRecordThatIsStillStoredIsNotReportedOpenAndItsSiteStaysBlocked() {
        let finished = TemporaryUnblock(startsIn: Countdown(remainingSeconds: 0, totalSeconds: 600), window: Countdown(remainingSeconds: 0, totalSeconds: 600))
        let engine = Engine(state: PersistedState(blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], temporaryUnblock: finished)], delaySeconds: 1800), policy: temporaryPolicy)
        #expect(engine.temporaryStatus(of: "reddit.com")?.isOpen == false)
        #expect(engine.blockedHosts == ["reddit.com", "www.reddit.com"], "a finished record does not keep the site open")
    }

    // snapshot(hostsFileHealthy:) builds the same status that the status command carries.
    @Test func theSnapshotMethodCarriesTheSameTemporaryStatusAsTheStatusCommand() {
        let engine = makeScenarioEngine()
        let direct = engine.snapshot(hostsFileHealthy: true)
        #expect(direct.blocked.first { $0.domain == "temp.example" }?.temporaryUnblock == TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false))
        #expect(direct == engine.send(.status).status)
    }
}

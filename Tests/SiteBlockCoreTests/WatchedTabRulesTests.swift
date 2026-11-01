import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § 3b TabRuleMatcher: the `WatchedPathRule` type (`wholeSitePath` is `/`, `isWholeSite`,
// `displayText`), the matching steps, and "Rules for the tab watcher" (`watchedTabRules`, `secondsUntilWatchedRulesChange`), with the host shortening taken
// from 03-daemon-cli-app.md § ChromePolicy `urlBlocklist(for:)` (a host is left out when a parent domain of it, whole labels only, is also in the list),
// the host normalizing from § 1 DomainNormalizer, and the expanded host list of a real site from § 3 DomainExpander. 05-testing-and-operations.md
// § Unit Tests (WatchedTabRulesTests) lists the cases.

private let waitingUnblock = TemporaryUnblockStatus(opensInSeconds: 600, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
private let openUnblock = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 900, windowSeconds: 1800, isOpen: true)

// A blocked site status with the given hosts, the way the daemon reports it.
private func site(_ domain: String, hosts: [String]? = nil, pending: Int? = nil, temporary: TemporaryUnblockStatus? = nil) -> BlockedSiteStatus {
    BlockedSiteStatus(domain: domain, hosts: hosts ?? [domain], unblockSecondsRemaining: pending, temporaryUnblock: temporary)
}

// A path rule status with the rule text built from its parts.
private func pathRule(_ domain: String, _ path: String, pending: Int? = nil, temporary: TemporaryUnblockStatus? = nil) -> BlockedPathStatus {
    BlockedPathStatus(domain: domain, path: path, rule: domain + path, unblockSecondsRemaining: pending, temporaryUnblock: temporary)
}

// A status snapshot that holds these sites and rules, and optionally other countdowns that do not touch the watched rules.
private func status(sites: [BlockedSiteStatus] = [], rules: [BlockedPathStatus]? = [], pendingDelay: PendingDelayStatus? = nil, lockout: Int? = nil) -> StatusSnapshot {
    StatusSnapshot(version: "1.0.0", passwordSet: true, blocked: sites, delaySeconds: 1800, pendingDelay: pendingDelay, uninstallSecondsRemaining: nil, recoverySecondsRemaining: nil, lockoutSecondsRemaining: lockout, hostsFileHealthy: true, adultFilterEnabled: true, blockedPaths: rules)
}

// The whole-site rule for one domain.
private func whole(_ domain: String) -> WatchedPathRule { WatchedPathRule(domain: domain, path: "/") }

// MARK: - WatchedPathRule

@Suite struct WatchedPathRuleWholeSiteTests {
    // The design fixes the whole-site path as "/" alone.
    @Test func theWholeSitePathIsASingleSlash() {
        #expect(WatchedPathRule.wholeSitePath == "/")
    }

    // isWholeSite is true exactly when the path equals "/"; a real path rule, even one that is only one letter long, is not a whole site.
    @Test(arguments: [("/", true), ("/a", false), ("/shorts", false), ("//", false), ("", false), ("/ ", false)])
    func isWholeSiteIsTrueOnlyForTheSingleSlashPath(path: String, expected: Bool) {
        #expect(WatchedPathRule(domain: "x.com", path: path).isWholeSite == expected)
    }

    // displayText is the domain alone for a whole site, and PathRuleParser.display (domain then path, "youtube.com/shorts") for a path rule.
    @Test func displayTextIsTheDomainForAWholeSiteAndTheJoinedRuleOtherwise() {
        #expect(whole("x.com").displayText == "x.com")
        #expect(WatchedPathRule(domain: "youtube.com", path: "/shorts").displayText == "youtube.com/shorts")
        #expect(WatchedPathRule(domain: "x.com", path: "/Home/Feed").displayText == "x.com/Home/Feed")
        #expect(WatchedPathRule(domain: "youtube.com", path: "/shorts").displayText == PathRuleParser.display(domain: "youtube.com", path: "/shorts"))
    }
}

// MARK: - watchedTabRules: which sites and in what order

@Suite struct WatchedTabRulesListTests {
    // Each blocked site gives one whole-site rule with path "/", and the path rules follow.
    @Test func eachBlockedSiteGivesOneWholeSiteRuleFollowedByThePathRules() {
        let snap = status(sites: [site("reddit.com")], rules: [pathRule("youtube.com", "/shorts")])
        #expect(snap.watchedTabRules == [whole("reddit.com"), WatchedPathRule(domain: "youtube.com", path: "/shorts")])
        #expect(snap.watchedTabRules.first?.isWholeSite == true)
        #expect(snap.watchedTabRules.last?.isWholeSite == false)
    }

    // An empty snapshot gives nothing, whether the path list is empty or missing (an older daemon).
    @Test func anEmptySnapshotGivesNoRules() {
        #expect(status().watchedTabRules.isEmpty)
        #expect(status(rules: nil).watchedTabRules.isEmpty)
    }

    // An older daemon's snapshot with sites but no path list still gives the whole-site rules.
    @Test func anOlderSnapshotWithoutPathRulesStillGivesTheSites() throws {
        let older = #"{"blocked":[{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"]}],"delaySeconds":1800,"hostsFileHealthy":true,"passwordSet":true,"version":"0.5.0"}"#
        let decoded = try JSONCoding.decoder.decode(StatusSnapshot.self, from: Data(older.utf8))
        #expect(decoded.watchedTabRules == [whole("reddit.com")])
    }

    // A site whose temporary unblock is open is left out; a site waiting to open and a site waiting to unblock for good are still blocked, so they stay.
    @Test func anOpenSiteIsLeftOutWhileWaitingAndPendingSitesStayIn() {
        let snap = status(sites: [site("open.example", temporary: openUnblock), site("waiting.example", temporary: waitingUnblock), site("pending.example", pending: 600)])
        #expect(snap.watchedTabRules == [whole("pending.example"), whole("waiting.example")])
    }

    // Only the isOpen flag removes a site: a waiting status one second from opening keeps it, and a status marked open removes it whatever its other fields say.
    @Test func onlyTheOpenFlagRemovesASite() {
        let almostOpen = TemporaryUnblockStatus(opensInSeconds: 1, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
        let oddlyOpen = TemporaryUnblockStatus(opensInSeconds: 5, secondsRemaining: 10, windowSeconds: 1800, isOpen: true)
        #expect(status(sites: [site("a.example", temporary: almostOpen)]).watchedTabRules == [whole("a.example")])
        #expect(status(sites: [site("a.example", temporary: oddlyOpen)]).watchedTabRules.isEmpty)
    }

    // The whole-site rules are sorted by domain no matter the daemon's order, and the path rules after them keep the daemon's order.
    @Test func wholeSiteRulesAreSortedAndPathRulesKeepTheirOrder() {
        let sites = [site("zeta.example"), site("alpha.example"), site("mid.example"), site("alpha-b.example")]
        let rules = [pathRule("z.example", "/2"), pathRule("a.example", "/1")]
        let expected = [whole("alpha-b.example"), whole("alpha.example"), whole("mid.example"), whole("zeta.example"), WatchedPathRule(domain: "z.example", path: "/2"), WatchedPathRule(domain: "a.example", path: "/1")]
        #expect(status(sites: sites, rules: rules).watchedTabRules == expected)
        #expect(status(sites: sites.reversed(), rules: rules).watchedTabRules == expected)
    }

    // The tail is exactly watchedPathRules: an open path rule is left out of both, and a path rule on a site whose whole site is open stays (03 § TabWatcher).
    @Test func thePathRulesAfterTheSitesAreExactlyWatchedPathRules() {
        let snap = status(sites: [site("youtube.com", temporary: openUnblock), site("x.com")], rules: [pathRule("youtube.com", "/shorts"), pathRule("r.example", "/open", temporary: openUnblock), pathRule("w.example", "/wait", temporary: waitingUnblock), pathRule("p.example", "/pend", pending: 5)])
        let pathPart = [WatchedPathRule(domain: "youtube.com", path: "/shorts"), WatchedPathRule(domain: "w.example", path: "/wait"), WatchedPathRule(domain: "p.example", path: "/pend")]
        #expect(snap.watchedPathRules == pathPart)
        #expect(snap.watchedTabRules == [whole("x.com")] + pathPart)
    }
}

// MARK: - watchedTabRules: host shortening and normalizing

@Suite struct WatchedTabRulesHostTests {
    // A host whose parent domain is in the list is left out, the way Chrome's URLBlocklist leaves it out, but a sibling that only shares a suffix stays.
    @Test func aSubdomainIsLeftOutWhenItsParentIsListed() {
        let snap = status(sites: [site("example.com", hosts: ["example.com", "m.example.com", "deep.news.example.com", "notexample.com"])])
        #expect(snap.watchedTabRules == [whole("example.com"), whole("notexample.com")])
    }

    // The shortening uses whole labels: "xample.com" is not a parent of "example.com".
    @Test func shorteningMatchesWholeLabelsOnly() {
        let snap = status(sites: [site("xample.com"), site("example.com")])
        #expect(snap.watchedTabRules == [whole("example.com"), whole("xample.com")])
    }

    // A subdomain is shortened away by a parent that comes from a DIFFERENT blocked site too, because the list is built over every still-blocked host.
    @Test func aParentFromAnotherSiteAlsoShortensASubdomain() {
        let snap = status(sites: [site("news.example.com"), site("example.com")])
        #expect(snap.watchedTabRules == [whole("example.com")])
    }

    // The open site is taken out before shortening: its parent host must not hide a subdomain that another, still-blocked site lists.
    @Test func anOpenSitesParentDoesNotHideAStillBlockedSubdomain() {
        let snap = status(sites: [site("example.com", temporary: openUnblock), site("news.example.com")])
        #expect(snap.watchedTabRules == [whole("news.example.com")])
    }

    // Two sites that share a host give it once, and a host shared with an open site stays because the other site still blocks it.
    @Test func aSharedHostIsGivenOnceAndStaysWhileAnySiteBlocksIt() {
        #expect(status(sites: [site("a.example", hosts: ["a.example", "shared.example"]), site("b.example", hosts: ["b.example", "shared.example"])]).watchedTabRules == [whole("a.example"), whole("b.example"), whole("shared.example")])
        #expect(status(sites: [site("a.example", hosts: ["a.example", "shared.example"], temporary: openUnblock), site("b.example", hosts: ["b.example", "shared.example"])]).watchedTabRules == [whole("b.example"), whole("shared.example")])
    }

    // A listed www. name is normalized to the bare domain, so it can equal a normalized tab host; with only the www. name listed the rule is still the bare domain.
    @Test func aWwwHostIsNormalizedToTheBareDomain() {
        #expect(status(sites: [site("example.com", hosts: ["www.example.com"])]).watchedTabRules == [whole("example.com")])
        #expect(status(sites: [site("example.com", hosts: ["www.example.com", "www.other.example"])]).watchedTabRules == [whole("example.com"), whole("other.example")])
    }

    // Upper-case and trailing-dot spellings are normalized, and spellings that become the same name after normalizing are given once.
    @Test func hostsThatNormalizeToTheSameNameAreGivenOnce() {
        let snap = status(sites: [site("example.com", hosts: ["Example.COM", "example.com.", "WWW.EXAMPLE.COM", "example.com"])])
        #expect(snap.watchedTabRules == [whole("example.com")])
    }

    // A non-ASCII host is turned into its Punycode form, the form a normalized tab host has.
    @Test func aNonASCIIHostBecomesItsPunycodeForm() {
        #expect(status(sites: [site("xn--bcher-kva.de", hosts: ["bücher.de"])]).watchedTabRules == [whole("xn--bcher-kva.de")])
    }

    // Hosts the normalizer refuses (an underscore, a reserved name, an IP address, a name with no dot) are dropped, and the good hosts beside them stay.
    @Test func aHostTheNormalizerRefusesIsDropped() {
        let snap = status(sites: [site("good.example", hosts: ["bad_host.test", "localhost", "1.2.3.4", "nodot", "good.example", "printer.local"])])
        #expect(snap.watchedTabRules == [whole("good.example")])
        #expect(status(sites: [site("bad.example", hosts: ["bad_host.test"])]).watchedTabRules.isEmpty)
    }

    // A real site from the engine: youtube.com expands into its prefixes and related names (02 § DomainExpander), and the list keeps only the ones no
    // listed parent covers. Opening its temporary unblock removes all of them and leaves the path rule.
    @Test func aRealEngineSiteGivesItsShortenedHostListAndOpeningItRemovesIt() {
        let engine = makeEngine(blocking: ["youtube.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "x.com/Home"))
        let youtube = ["i.ytimg.com", "s.ytimg.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtube.googleapis.com", "youtubei.googleapis.com", "youtubekids.com", "yt3.ggpht.com"].map(whole)
        let homeRule = WatchedPathRule(domain: "x.com", path: "/Home")
        #expect(engine.send(.status).status?.watchedTabRules == youtube + [homeRule])
        openTemporaryUnblock(engine, "youtube.com")
        #expect(engine.send(.status).status?.watchedTabRules == [homeRule])
    }
}

// MARK: - matching with whole-site rules

@Suite struct WholeSiteRuleMatchingTests {
    private static let xRule = whole("x.com")

    // A whole-site rule matches every http/https path on the host and on its subdomains, with any port, query, fragment or letter case of the host.
    @Test(arguments: ["https://x.com", "https://x.com/", "http://x.com/home?tab=1#top", "https://www.x.com/a/b", "https://api.x.com/", "HTTPS://X.COM/Home", "https://x.com:8443/", "https://user@x.com/", "https://x.com./i/flow", "https://deep.sub.x.com/%E4%BE%8B"])
    func aWholeSiteRuleMatchesEveryPathOnTheSiteAndItsSubdomains(url: String) {
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [Self.xRule]) == Self.xRule)
        #expect(TabRuleMatcher.matches(url: url, rule: Self.xRule))
    }

    // It does not match a look-alike domain, a site that merely ends in the same letters, or a site that only starts with the blocked name.
    @Test(arguments: ["https://notx.com/", "https://x.co/", "https://x.com.evil.example/", "https://xx.com/", "https://evil.example/x.com", "https://evil.example/?u=https://x.com/"])
    func aWholeSiteRuleDoesNotMatchOtherSites(url: String) {
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [Self.xRule]) == nil)
    }

    // Addresses that are not http or https match nothing, even a whole-site rule whose path "/" every path starts with.
    @Test(arguments: ["data:text/html,x.com", "data:text/html;charset=utf-8,%3Ch1%3Ex.com", "file:///x.com/", "file://x.com/", "about:blank", "about:x.com", "chrome://newtab/", "javascript:location='https://x.com/'", "x.com", "//x.com/"])
    func aWholeSiteRuleMatchesNothingOutsideHttpAndHttps(url: String) {
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [Self.xRule]) == nil)
    }

    // With the site and a path rule on it both in watchedTabRules, a tab on the path is reported under the whole-site rule, because whole-site rules come first.
    @Test func aTabOnABlockedPathOfABlockedSiteIsReportedUnderTheWholeSite() {
        let rules = status(sites: [site("x.com")], rules: [pathRule("x.com", "/Home")]).watchedTabRules
        #expect(TabRuleMatcher.matchingRule(url: "https://x.com/Home/1", rules: rules) == whole("x.com"))
        #expect(TabRuleMatcher.matchingRule(url: "https://x.com/Home/1", rules: rules)?.displayText == "x.com")
    }

    // A site listed by its Unicode host is matched by a tab on the Unicode spelling and on the Punycode spelling, both reported under the Punycode rule.
    @Test(arguments: ["https://bücher.de/", "https://xn--bcher-kva.de/x", "https://www.bücher.de/a"])
    func aUnicodeHostIsMatchedInBothSpellings(url: String) {
        let rules = status(sites: [site("xn--bcher-kva.de", hosts: ["bücher.de"])]).watchedTabRules
        #expect(TabRuleMatcher.matchingRule(url: url, rules: rules) == whole("xn--bcher-kva.de"))
    }

    // With the site open, the same tab falls to the path rule, which still blocks that part of the site, and the rest of the site is left alone.
    @Test func withTheSiteOpenTheTabFallsToThePathRule() {
        let rules = status(sites: [site("x.com", temporary: openUnblock)], rules: [pathRule("x.com", "/Home")]).watchedTabRules
        #expect(TabRuleMatcher.matchingRule(url: "https://x.com/Home/1", rules: rules) == WatchedPathRule(domain: "x.com", path: "/Home"))
        #expect(TabRuleMatcher.matchingRule(url: "https://x.com/Explore", rules: rules) == nil)
    }
}

// MARK: - secondsUntilWatchedRulesChange

@Suite struct SecondsUntilWatchedRulesChangeTests {
    // Nothing counting down gives nil: no sites, plain sites, plain path rules.
    @Test func nothingCountingDownGivesNil() {
        #expect(status().secondsUntilWatchedRulesChange == nil)
        #expect(status(rules: nil).secondsUntilWatchedRulesChange == nil)
        #expect(status(sites: [site("a.example"), site("b.example")], rules: [pathRule("c.example", "/x")]).secondsUntilWatchedRulesChange == nil)
    }

    // Countdowns that do not change the watched rules (a pending delay change, a lockout) are not counted.
    @Test func otherCountdownsInTheSnapshotAreNotCounted() {
        let snap = status(sites: [site("a.example")], pendingDelay: PendingDelayStatus(newDelaySeconds: 60, secondsRemaining: 7), lockout: 3)
        #expect(snap.secondsUntilWatchedRulesChange == nil)
    }

    // An open temporary unblock changes the list when its window ends, so its secondsRemaining counts, for a site and for a path rule.
    @Test func anOpenUnblockCountsItsRemainingWindow() {
        let open = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 420, windowSeconds: 1800, isOpen: true)
        #expect(status(sites: [site("a.example", temporary: open)]).secondsUntilWatchedRulesChange == 420)
        #expect(status(rules: [pathRule("a.example", "/x", temporary: open)]).secondsUntilWatchedRulesChange == 420)
    }

    // An open unblock uses its secondsRemaining even when the status also carries an opensInSeconds value.
    @Test func anOpenUnblockIgnoresAStrayOpensInSeconds() {
        let open = TemporaryUnblockStatus(opensInSeconds: 5, secondsRemaining: 300, windowSeconds: 1800, isOpen: true)
        #expect(status(sites: [site("a.example", temporary: open)]).secondsUntilWatchedRulesChange == 300)
    }

    // A waiting unblock changes the list when it opens, so its opensInSeconds counts, not the window length.
    @Test func aWaitingUnblockCountsTheTimeUntilItOpens() {
        let waiting = TemporaryUnblockStatus(opensInSeconds: 75, secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
        #expect(status(sites: [site("a.example", temporary: waiting)]).secondsUntilWatchedRulesChange == 75)
        #expect(status(rules: [pathRule("a.example", "/x", temporary: waiting)]).secondsUntilWatchedRulesChange == 75)
    }

    // A waiting unblock with no opensInSeconds falls back to its secondsRemaining.
    @Test func aWaitingUnblockWithoutOpensInSecondsUsesSecondsRemaining() {
        let waiting = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: 640, windowSeconds: 1800, isOpen: false)
        #expect(status(sites: [site("a.example", temporary: waiting)]).secondsUntilWatchedRulesChange == 640)
    }

    // An unblock for good counts, for a site and for a path rule.
    @Test func anUnblockForGoodCounts() {
        #expect(status(sites: [site("a.example", pending: 1234)]).secondsUntilWatchedRulesChange == 1234)
        #expect(status(rules: [pathRule("a.example", "/x", pending: 99)]).secondsUntilWatchedRulesChange == 99)
    }

    // The answer is the smallest of every countdown, wherever the smallest one is: on a site or a path rule, open, waiting or pending. There are two sites
    // and two path rules with a pending unblock, so the smallest sitting on the SECOND of either pair is found too (indexes 3 and 5).
    @Test(arguments: Array(0...7))
    func theSmallestCountdownWins(smallestAt index: Int) {
        let values = [900, 800, 700, 600, 500, 400, 300, 200].enumerated().map { $0.offset == index ? 7 : $0.element }
        let open = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: values[0], windowSeconds: 1800, isOpen: true)
        let waiting = TemporaryUnblockStatus(opensInSeconds: values[1], secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
        let ruleWaiting = TemporaryUnblockStatus(opensInSeconds: values[6], secondsRemaining: 1800, windowSeconds: 1800, isOpen: false)
        let ruleOpen = TemporaryUnblockStatus(opensInSeconds: nil, secondsRemaining: values[7], windowSeconds: 1800, isOpen: true)
        let sites = [site("a.example", temporary: open), site("b.example", temporary: waiting), site("c.example", pending: values[2]), site("c2.example", pending: values[3])]
        let rules = [pathRule("d.example", "/x", pending: values[4]), pathRule("d2.example", "/x", pending: values[5]), pathRule("e.example", "/y", temporary: ruleWaiting), pathRule("f.example", "/z", temporary: ruleOpen)]
        #expect(status(sites: sites, rules: rules).secondsUntilWatchedRulesChange == 7)
    }

    // A path rule's countdown counts even when it is the only countdown and the site list is empty, and a zero is a real answer, not "none".
    @Test func aZeroCountdownIsReturnedAsZero() {
        #expect(status(rules: [pathRule("a.example", "/x", pending: 0)]).secondsUntilWatchedRulesChange == 0)
        #expect(status(sites: [site("a.example", pending: 50)], rules: [pathRule("a.example", "/x", pending: 0)]).secondsUntilWatchedRulesChange == 0)
    }

    // From a real engine: a waiting temporary unblock reports the start wait, and once open it reports the window.
    @Test func aRealEngineReportsTheStartWaitThenTheWindow() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        #expect(engine.send(.status).status?.secondsUntilWatchedRulesChange == 1800)
        _ = engine.tick(elapsed: 1800)
        #expect(engine.send(.status).status?.secondsUntilWatchedRulesChange == 600)
        _ = engine.tick(elapsed: 600)
        #expect(engine.send(.status).status?.secondsUntilWatchedRulesChange == nil)
    }
}

// MARK: - how often the tab watcher checks

// Expected values come from 02-core-components.md § 3b TabRuleMatcher (WatchedPathRule: `pathRuleCheckSeconds` = 0.5, `wholeSiteCheckSeconds` = 4.0,
// `checkSeconds(for:)` gives the short one when the list holds at least one rule whose path is not `/`, otherwise the long one, including for an empty list)
// and 03-daemon-cli-app.md § TabWatcher "Ownership and scheduling" (0.5 seconds with a path rule, 4 seconds otherwise). The timer itself is app code.
@Suite struct WatchedRulesCheckSecondsTests {
    private static let shorts = WatchedPathRule(domain: "youtube.com", path: "/shorts")

    // The two intervals are the design's numbers.
    @Test func theTwoIntervalsAreHalfASecondAndFourSeconds() {
        #expect(WatchedPathRule.pathRuleCheckSeconds == 0.5)
        #expect(WatchedPathRule.wholeSiteCheckSeconds == 4.0)
    }

    // No rules and only whole-site rules both give 4 seconds, however many whole sites there are.
    @Test(arguments: [0, 1, 2, 50])
    func noPathRuleGivesFourSeconds(wholeSites count: Int) {
        let rules = (0..<count).map { whole("site\($0).example") }
        #expect(WatchedPathRule.checkSeconds(for: rules) == 4.0)
    }

    // One path rule gives 0.5 seconds wherever it sits among many whole sites (first, middle, last), alone, or with other path rules.
    @Test(arguments: [0, 10, 20])
    func onePathRuleAnywhereGivesHalfASecond(at index: Int) {
        var rules = (0..<20).map { whole("site\($0).example") }
        rules.insert(Self.shorts, at: index)
        #expect(WatchedPathRule.checkSeconds(for: rules) == 0.5)
        #expect(WatchedPathRule.checkSeconds(for: [Self.shorts]) == 0.5)
        #expect(WatchedPathRule.checkSeconds(for: [Self.shorts, WatchedPathRule(domain: "x.com", path: "/Home")]) == 0.5)
    }

    // A rule counts as a path rule whenever its path is not "/" alone, even a one-letter path or "//".
    @Test(arguments: ["/a", "//", "/ "])
    func anyPathOtherThanTheSingleSlashCountsAsAPathRule(path: String) {
        #expect(WatchedPathRule.checkSeconds(for: [whole("x.com"), WatchedPathRule(domain: "x.com", path: path)]) == 0.5)
    }

    // On real watchedTabRules output: sites only and nothing blocked give 4 seconds; paths only and sites with paths give 0.5 seconds.
    @Test func realWatchedTabRulesGiveTheIntervalTheirPathRulesCallFor() {
        #expect(WatchedPathRule.checkSeconds(for: status().watchedTabRules) == 4.0)
        #expect(WatchedPathRule.checkSeconds(for: status(sites: [site("reddit.com"), site("x.com", pending: 60)]).watchedTabRules) == 4.0)
        #expect(WatchedPathRule.checkSeconds(for: status(rules: [pathRule("youtube.com", "/shorts")]).watchedTabRules) == 0.5)
        #expect(WatchedPathRule.checkSeconds(for: status(sites: [site("reddit.com"), site("x.com")], rules: [pathRule("youtube.com", "/shorts")]).watchedTabRules) == 0.5)
    }

    // A path rule whose own temporary unblock is open is not watched, so with sites beside it the interval is 4 seconds; while it is only waiting it is 0.5.
    @Test func aSnapshotWhoseOnlyPathRuleIsOpenGivesFourSeconds() {
        #expect(WatchedPathRule.checkSeconds(for: status(sites: [site("reddit.com")], rules: [pathRule("youtube.com", "/shorts", temporary: openUnblock)]).watchedTabRules) == 4.0)
        #expect(WatchedPathRule.checkSeconds(for: status(rules: [pathRule("youtube.com", "/shorts", temporary: openUnblock)]).watchedTabRules) == 4.0)
        #expect(WatchedPathRule.checkSeconds(for: status(sites: [site("reddit.com")], rules: [pathRule("youtube.com", "/shorts", temporary: waitingUnblock)]).watchedTabRules) == 0.5)
    }
}

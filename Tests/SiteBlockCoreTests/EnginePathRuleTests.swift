import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § Engine ("Path rules", "Browser block list", "Site cap"), 01-overview-and-data.md
// § Commands (addPath, unblockPath, cancelUnblockPath) and § Fixed Policy Values (the cap counts sites plus path rules).

// An engine with a password and the given path rules added through the real addPath command.
private func makeEngine(rules: [String], policy: Policy = designPolicy) -> Engine {
    let engine = makeEngine(policy: policy)
    for rule in rules { expectSuccess(engine.send(.addPath, domain: rule)) }
    return engine
}

// The design's covering list for youtube.com alone (the nine entries a Chrome URLBlocklist needs), typed out here.
private let youtubeCoverFromDesign = ["i.ytimg.com", "s.ytimg.com", "youtu.be", "youtube-nocookie.com", "youtube.com", "youtube.googleapis.com", "youtubei.googleapis.com", "youtubekids.com", "yt3.ggpht.com"]

@Suite struct EngineAddPathTests {
    // 01 § Commands (addPath): "adds a path rule at once. No password."
    @Test func addPathStoresTheRuleAndConfirmsItInPlainWords() {
        let engine = makeEngine()
        let response = engine.send(.addPath, domain: "youtube.com/shorts")
        expectSuccess(response)
        #expect(response.message == "youtube.com/shorts is now blocked.")
        #expect(engine.state.blockedPaths == [BlockedPath(domain: "youtube.com", path: "/shorts")])
        #expect(engine.state.blocked.isEmpty, "a path rule is not a whole-site block")
    }

    // 01 § StatusSnapshot: blockedPaths carries domain, path, rule and unblockSecondsRemaining.
    @Test func theSnapshotListsTheRuleWithItsJoinedText() {
        let engine = makeEngine(rules: ["https://www.youtube.com/shorts/abc?x=1", "x.com/Home"])
        let rules = engine.send(.status).status?.blockedPaths
        #expect(rules == [BlockedPathStatus(domain: "youtube.com", path: "/shorts/abc", rule: "youtube.com/shorts/abc", unblockSecondsRemaining: nil), BlockedPathStatus(domain: "x.com", path: "/Home", rule: "x.com/Home", unblockSecondsRemaining: nil)])
    }

    // 02 § Engine: "in the order added" (01 § Data Model).
    @Test func rulesStayInTheOrderTheyWereAdded() {
        let engine = makeEngine(rules: ["z.com/b", "a.com/a", "m.com/c"])
        #expect(engine.state.blockedPaths?.map(\.domain) == ["z.com", "a.com", "m.com"])
    }

    // 01 § How Blocking Works: "The hosts file can only block whole names, so path rules are enforced only through the browsers' own block lists."
    @Test func aPathRuleNeverAddsAnythingToTheHostsFile() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        #expect(engine.blockedHosts.isEmpty)
        #expect(engine.hostsToWrite == designAlwaysWrittenHosts)
    }

    // 02 § Engine, addPath: "(invalidDomain for host errors, invalidPath for path errors and for text with no path)".
    @Test(arguments: ["youtube.com", "youtube.com/", "https://www.youtube.com/", "youtube.com/*", "youtube.com/my shorts", "youtube.com/sho*rts", "youtube.com/ü", String("youtube.com/") + String(repeating: "a", count: 300)])
    func textWithoutAUsablePathIsRefusedWithInvalidPath(text: String) {
        let engine = makeEngine()
        let response = engine.send(.addPath, domain: text)
        expectFailure(response, .invalidPath)
        #expect(engine.state.blockedPaths == nil)
    }

    @Test(arguments: ["1.2.3.4/shorts", "localhost/x", "printer.local/x", "reddit/r/all", "my_site.com/x", "", "   ", "/shorts"])
    func aBadSiteNameIsRefusedWithInvalidDomain(text: String) {
        let engine = makeEngine()
        expectFailure(engine.send(.addPath, domain: text), .invalidDomain)
        #expect(engine.state.blockedPaths == nil)
    }

    // The host problem is named first when both parts are wrong, like the parser does.
    @Test func whenBothPartsAreWrongTheSiteNameProblemIsReported() {
        expectFailure(makeEngine().send(.addPath, domain: "1.2.3.4/a b"), .invalidDomain)
    }

    // 02 § Engine, Argument rule: a missing required argument fails with badRequest.
    @Test func aMissingRuleTextIsABadRequest() {
        expectFailure(makeEngine().send(.addPath), .badRequest)
    }

    // 02 § Engine, addPath: "Otherwise, like add: notSetUp without a password". The text is checked first, like in add.
    @Test func withoutAPasswordTheFirstRuleIsRefusedWithNotSetUp() {
        let engine = makeEngine(password: nil)
        expectFailure(engine.send(.addPath, domain: "youtube.com/shorts"), .notSetUp)
        #expect(engine.state.blockedPaths == nil)
        // Bad text is reported before the missing password, like in add.
        expectFailure(engine.send(.addPath, domain: "youtube.com"), .invalidPath)
    }

    // 02 § Engine, addPath: "If the whole domain is already in blocked, fail alreadyBlocked".
    @Test func whenTheWholeSiteIsAlreadyBlockedTheRuleIsRefusedAsAlreadyBlocked() {
        let engine = makeEngine(blocking: ["youtube.com"])
        let response = engine.send(.addPath, domain: "youtube.com/shorts")
        expectFailure(response, .alreadyBlocked)
        #expect(response.error == "youtube.com is already fully blocked.")
        #expect(engine.state.blockedPaths == nil)
    }

    // The same check works for the www form and an uppercase host, because both name the same domain.
    @Test(arguments: ["www.youtube.com/shorts", "YOUTUBE.COM/shorts", "https://www.YouTube.com/shorts/abc"])
    func theWholeSiteCheckUsesTheNormalizedDomain(text: String) {
        let engine = makeEngine(blocking: ["youtube.com"])
        expectFailure(engine.send(.addPath, domain: text), .alreadyBlocked)
    }

    // "if they exist without one, fail alreadyBlocked" - and nothing changes.
    @Test func theSameRuleTwiceIsAlreadyBlocked() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        let before = engine.state
        expectFailure(engine.send(.addPath, domain: "youtube.com/shorts"), .alreadyBlocked)
        #expect(engine.state == before)
    }

    // Different ways to type the same rule are the same rule.
    @Test(arguments: ["https://www.youtube.com/shorts/", "YouTube.com/shorts*", "www.youtube.com/shorts?x=1#y"])
    func anotherSpellingOfTheSameRuleIsAlreadyBlocked(text: String) {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.addPath, domain: text), .alreadyBlocked)
        #expect(engine.state.blockedPaths?.count == 1)
    }

    // 01 § BlockedPath: "Case is kept, because paths are case-sensitive." So /Shorts and /shorts are two rules, and so are two paths on one site.
    @Test func rulesThatDifferInPathCaseOrPathAreSeparateRules() {
        let engine = makeEngine(rules: ["youtube.com/shorts", "youtube.com/Shorts", "youtube.com/watch", "youtube.com/shorts/live"])
        #expect(engine.state.blockedPaths?.map(\.path) == ["/shorts", "/Shorts", "/watch", "/shorts/live"])
    }

    // 02 § Engine: "Re-adding a rule that is waiting to unblock cancels the unblock, like add."
    @Test func addingARuleThatIsWaitingToUnblockCancelsTheUnblock() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword))
        #expect(engine.state.blockedPaths?.first?.pendingUnblock != nil)
        let response = engine.send(.addPath, domain: "youtube.com/shorts")
        expectSuccess(response)
        #expect(response.message == "Unblock cancelled; youtube.com/shorts stays blocked.")
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == nil)
    }

    // Like `add`, cancelling needs no password: after a finished recovery the password is gone, and re-adding is the way to stop an unblock that was already counting down. The delay is raised to 7 days first, so the rule's countdown outlasts the 48-hour recovery; a new rule still needs a password.
    @Test func cancellingByReAddingWorksEvenAfterARecoveryClearedThePassword() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 604_800))
        expectSuccess(engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword))
        expectSuccess(engine.send(.recoveryStart, uid: 0))
        #expect(engine.tick(elapsed: Double(designPolicy.recoverySeconds)) == true)
        #expect(engine.state.passwordHash == nil)
        #expect(engine.state.blockedPaths?.first?.pendingUnblock != nil, "the rule's 7-day countdown is still running")
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == nil)
        expectFailure(engine.send(.addPath, domain: "x.com/y"), .notSetUp)
    }

    // 02 § Engine: "Adding the whole domain later keeps its path rules (they become redundant while the whole site is blocked, and matter again if the whole site is unblocked)."
    @Test func blockingTheWholeSiteLaterKeepsThePathRules() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        #expect(engine.state.blocked.map(\.domain) == ["youtube.com"])
        #expect(engine.state.blockedPaths == [BlockedPath(domain: "youtube.com", path: "/shorts")])
    }

    // A rule for one site says nothing about another: a whole-site block of a different domain does not refuse it.
    @Test func aWholeSiteBlockOfAnotherDomainDoesNotRefuseTheRule() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
    }
}

@Suite struct EngineUnblockPathTests {
    // 02 § Engine: "unblockPath and cancelUnblockPath follow unblock and cancelUnblock exactly, keyed by domain and path."
    @Test func unblockPathStartsTheCountdownAtTheDelay() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        let response = engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        expectSuccess(response)
        #expect(response.message == "youtube.com/shorts will unblock in 30 minutes. You can cancel any time before then.")
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == Countdown(seconds: 1800))
        #expect(engine.send(.status).status?.blockedPaths?.first?.unblockSecondsRemaining == 1800)
    }

    // The rule text may be typed in any of the ways that mean the same rule.
    @Test(arguments: ["youtube.com/shorts/", "https://www.youtube.com/shorts?x=1", "YouTube.com/shorts*"])
    func unblockPathAcceptsAnotherSpellingOfTheRule(text: String) {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.unblockPath, domain: text, password: rightPassword))
        #expect(engine.state.blockedPaths?.first?.pendingUnblock != nil)
    }

    // "(domain = rule text, password) - notBlocked when no such rule exists." Another path, another case, or only the whole site blocked are not that rule.
    @Test(arguments: ["youtube.com/watch", "youtube.com/Shorts", "x.com/shorts", "youtube.com/shorts/live"])
    func unblockPathOfARuleThatDoesNotExistIsNotBlocked(text: String) {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.unblockPath, domain: text, password: rightPassword), .notBlocked)
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == nil)
    }

    @Test func aWholeSiteBlockIsNotAPathRuleAndUnblockPathDoesNotTouchIt() {
        let engine = makeEngine(blocking: ["youtube.com"])
        expectFailure(engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword), .notBlocked)
        #expect(engine.pendingUnblock(of: "youtube.com") == nil)
    }

    // And the other way round: unblock (whole site) does not find a path rule.
    @Test func unblockOfAWholeSiteDoesNotFindAPathRule() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.unblock, domain: "youtube.com", password: rightPassword), .notBlocked)
    }

    // The password rule is shared: a wrong password counts, five lock the checks, and a right one is refused during a lockout.
    @Test func aWrongPasswordCountsTowardTheSharedLockout() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        let first = engine.send(.unblockPath, domain: "youtube.com/shorts", password: badPassword)
        expectFailure(first, .wrongPassword)
        #expect(engine.state.failedAttempts == 1)
        for _ in 0..<(designPolicy.maxFailedAttempts - 1) { _ = engine.send(.unblockPath, domain: "youtube.com/shorts", password: badPassword) }
        #expect(engine.state.lockout != nil)
        expectFailure(engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword), .lockedOut)
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == nil)
    }

    // The rule is looked up before the password is checked, so asking about a rule that is not there costs no password try.
    @Test func aRuleThatIsNotThereCostsNoPasswordTry() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.unblockPath, domain: "x.com/y", password: badPassword), .notBlocked)
        #expect(engine.state.failedAttempts == 0)
    }

    // 02 § Engine, Argument rule: a missing argument is a badRequest before any password check.
    @Test func aMissingPasswordIsABadRequestAndCostsNoTry() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.unblockPath, domain: "youtube.com/shorts"), .badRequest)
        expectFailure(engine.send(.unblockPath, password: rightPassword), .badRequest)
        #expect(engine.state.failedAttempts == 0)
    }

    @Test func unblockPathWithoutAPathIsInvalidPathAndWithABadSiteIsInvalidDomain() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.unblockPath, domain: "youtube.com", password: rightPassword), .invalidPath)
        expectFailure(engine.send(.unblockPath, domain: "1.2.3.4/x", password: rightPassword), .invalidDomain)
    }

    // 02 § Engine, unblock: "If one is already pending, keep the existing countdown (do not restart it) and report its remaining time."
    @Test func aSecondUnblockPathKeepsTheRunningCountdown() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        _ = engine.tick(elapsed: 600)
        let again = engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        expectSuccess(again)
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
        #expect(again.message == "youtube.com/shorts is already waiting to unblock, in 20 minutes. You can cancel any time before then.")
    }

    // 02 § Engine, Tick: "remove path rules whose unblock finished (a change that must be saved)". Not one tick early.
    @Test func theRuleLeavesOnlyWhenTheFullDelayHasPassedAndTheTickReportsTheChange() {
        let engine = makeEngine(rules: ["youtube.com/shorts", "x.com/Home"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        #expect(engine.tick(elapsed: 1799.9) == false)
        #expect(engine.state.blockedPaths?.count == 2)
        #expect(engine.tick(elapsed: 0.1) == true)
        #expect(engine.state.blockedPaths == [BlockedPath(domain: "x.com", path: "/Home")])
        #expect(engine.tick(elapsed: 1) == false)
    }

    @Test func theLastRuleLeavingEmptiesTheSnapshotAndTheState() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.blockedPaths?.isEmpty ?? true)
        #expect(engine.send(.status).status?.blockedPaths == [])
        #expect(engine.browserBlockEntries.chrome.isEmpty && engine.browserBlockEntries.firefox.isEmpty)
        // And the rule can be added again from scratch.
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
    }

    // A rule that is waiting to unblock is still blocked until its countdown ends, so browsers keep refusing it.
    @Test func aRuleWaitingToUnblockStaysInTheBrowserListsUntilItEnds() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        _ = engine.tick(elapsed: 900)
        #expect(engine.browserBlockEntries.chrome == ["youtube.com/shorts"])
        #expect(engine.browserBlockEntries.firefox == ["*://*.youtube.com/shorts*"])
        _ = engine.tick(elapsed: 900)
        #expect(engine.browserBlockEntries.chrome.isEmpty)
    }

    // Two rules that finish on the same big tick both go.
    @Test(arguments: [1800.0, 1800.5, 5000.0, 864_000.0])
    func severalRulesThatFinishOnOneBigTickAllLeave(elapsed: Double) {
        let engine = makeEngine(rules: ["a.com/x", "b.com/y", "c.com/z"])
        engine.send(.unblockPath, domain: "a.com/x", password: rightPassword)
        engine.send(.unblockPath, domain: "b.com/y", password: rightPassword)
        #expect(engine.tick(elapsed: elapsed) == true)
        #expect(engine.state.blockedPaths == [BlockedPath(domain: "c.com", path: "/z")])
    }

    // Bad clock readings change nothing, like for sites.
    @Test(arguments: [-5.0, 0.0, Double.nan, Double.infinity])
    func badElapsedValuesDoNotTouchARuleCountdown(elapsed: Double) {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        #expect(engine.tick(elapsed: elapsed) == false)
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == Countdown(seconds: 1800))
    }

    @Test func cancelUnblockPathStopsTheCountdownWithoutAPassword() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        let response = engine.send(.cancelUnblockPath, domain: "https://www.youtube.com/shorts/")
        expectSuccess(response)
        #expect(response.message == "Unblock cancelled; youtube.com/shorts stays blocked.")
        #expect(engine.state.blockedPaths?.first?.pendingUnblock == nil)
        _ = engine.tick(elapsed: 5000)
        #expect(engine.state.blockedPaths?.count == 1)
    }

    @Test func cancelUnblockPathWithNothingPendingIsNothingPending() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.cancelUnblockPath, domain: "youtube.com/shorts"), .nothingPending)
    }

    @Test func cancelUnblockPathOfAnUnknownRuleIsNotBlocked() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectFailure(engine.send(.cancelUnblockPath, domain: "youtube.com/watch"), .notBlocked)
        expectFailure(engine.send(.cancelUnblockPath, domain: "youtube.com"), .invalidPath)
        expectFailure(engine.send(.cancelUnblockPath, domain: "1.2.3.4/x"), .invalidDomain)
        expectFailure(engine.send(.cancelUnblockPath), .badRequest)
    }

    // Cancelling one rule leaves the other rule's countdown running.
    @Test func cancellingOneRuleLeavesAnotherRulesCountdownRunning() {
        let engine = makeEngine(rules: ["youtube.com/shorts", "youtube.com/watch"])
        engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword)
        engine.send(.unblockPath, domain: "youtube.com/watch", password: rightPassword)
        expectSuccess(engine.send(.cancelUnblockPath, domain: "youtube.com/shorts"))
        #expect(engine.state.blockedPaths?[0].pendingUnblock == nil)
        #expect(engine.state.blockedPaths?[1].pendingUnblock != nil)
    }
}

// 01 § Fixed Policy Values: "Most blocked sites: 500, counting sites and path rules together." 02 § Engine, Site cap and Path rules: tooManySites when
// blocked.count + blockedPaths.count would exceed maxSites. These tests use a policy with a cap of 5 so the cap is reached with a few commands.
@Suite struct EnginePathRuleCapTests {
    static let smallPolicy: Policy = {
        var policy = designPolicy
        policy.maxSites = 5
        return policy
    }()

    @Test func sitesAndRulesTogetherFillTheCapAndTheNextOfEitherKindIsRefused() {
        let engine = makeEngine(blocking: ["a.com", "b.com", "c.com"], policy: Self.smallPolicy)
        expectSuccess(engine.send(.addPath, domain: "d.com/x"))
        expectSuccess(engine.send(.addPath, domain: "e.com/x"))
        let before = engine.state
        expectFailure(engine.send(.add, domain: "f.com"), .tooManySites)
        expectFailure(engine.send(.addPath, domain: "f.com/x"), .tooManySites)
        #expect(engine.state == before, "a refused command changes nothing")
    }

    @Test func rulesAloneCanFillTheCap() {
        let engine = makeEngine(rules: ["a.com/x", "b.com/x", "c.com/x", "d.com/x", "e.com/x"], policy: Self.smallPolicy)
        expectFailure(engine.send(.addPath, domain: "f.com/x"), .tooManySites)
        expectFailure(engine.send(.add, domain: "f.com"), .tooManySites)
    }

    // 02 § Engine: the cap applies "only to a new site"; cancelling a pending unblock by re-adding is not a new entry.
    @Test func reAddingAnExistingEntryAtTheCapIsNotRefusedAsTooMany() {
        let engine = makeEngine(blocking: ["a.com", "b.com", "c.com"], policy: Self.smallPolicy)
        expectSuccess(engine.send(.addPath, domain: "d.com/x"))
        expectSuccess(engine.send(.addPath, domain: "e.com/x"))
        engine.send(.unblockPath, domain: "d.com/x", password: rightPassword)
        expectSuccess(engine.send(.addPath, domain: "d.com/x"))
        // The same rule again is alreadyBlocked, not tooManySites.
        expectFailure(engine.send(.addPath, domain: "e.com/x"), .alreadyBlocked)
        // And a pending site unblock can be cancelled by add at the cap.
        engine.send(.unblock, domain: "a.com", password: rightPassword)
        expectSuccess(engine.send(.add, domain: "a.com"))
    }

    // A finished unblock frees room for exactly one more.
    @Test func aFinishedRuleUnblockFreesOneSlot() {
        let engine = makeEngine(blocking: ["a.com", "b.com"], policy: Self.smallPolicy)
        for rule in ["c.com/x", "d.com/x", "e.com/x"] { expectSuccess(engine.send(.addPath, domain: rule)) }
        expectFailure(engine.send(.add, domain: "f.com"), .tooManySites)
        engine.send(.unblockPath, domain: "c.com/x", password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        expectSuccess(engine.send(.add, domain: "f.com"))
        expectFailure(engine.send(.addPath, domain: "g.com/x"), .tooManySites)
    }

    // A rule pending its unblock still counts: it is still blocked.
    @Test func aRuleWaitingToUnblockStillCountsTowardTheCap() {
        let engine = makeEngine(blocking: ["a.com", "b.com", "c.com", "d.com"], policy: Self.smallPolicy)
        expectSuccess(engine.send(.addPath, domain: "e.com/x"))
        engine.send(.unblockPath, domain: "e.com/x", password: rightPassword)
        expectFailure(engine.send(.add, domain: "f.com"), .tooManySites)
    }

    // The production cap is 500 for both kinds together (01 § Fixed Policy Values), and the test policy copies the design's other numbers.
    @Test func theProductionCapIs500AndCountsRulesToo() {
        #expect(Policy.production.maxSites == 500)
        var policy = designPolicy
        policy.maxSites = 500
        let engine = makeEngine(policy: policy)
        for index in 0..<250 { expectSuccess(engine.send(.add, domain: "site\(index).example.com")) }
        for index in 0..<250 { expectSuccess(engine.send(.addPath, domain: "rule\(index).example.com/p")) }
        expectFailure(engine.send(.add, domain: "one-too-many.example.com"), .tooManySites)
        expectFailure(engine.send(.addPath, domain: "one-too-many.example.com/p"), .tooManySites)
    }
}

// 02 § Engine, "Browser block list": `browserBlockEntries` builds both browsers' lists. Chrome: the covering host list plus chromeEntry for every
// path rule whose domain is not covered by a whole-site block, sorted. Firefox: `*://*.<host>/*` for every covering host plus firefoxPattern for the
// same path rules, sorted.
@Suite struct EngineBrowserBlockEntriesTests {
    @Test func withNothingBlockedBothListsAreEmpty() {
        let entries = makeEngine().browserBlockEntries
        #expect(entries.chrome.isEmpty && entries.firefox.isEmpty)
    }

    @Test func aWholeSiteGivesItsCoveringHostsAndOneStarPatternPerHost() {
        let entries = makeEngine(blocking: ["youtube.com"]).browserBlockEntries
        #expect(entries.chrome == youtubeCoverFromDesign)
        #expect(entries.firefox == youtubeCoverFromDesign.map { "*://*.\($0)/*" }.sorted())
    }

    @Test func aPlainSiteIsOneEntryInEachList() {
        let entries = makeEngine(blocking: ["example.com"]).browserBlockEntries
        #expect(entries.chrome == ["example.com"])
        #expect(entries.firefox == ["*://*.example.com/*"])
    }

    @Test func aPathRuleAloneGivesOnePathEntryInEachList() {
        let entries = makeEngine(rules: ["youtube.com/shorts"]).browserBlockEntries
        #expect(entries.chrome == ["youtube.com/shorts"])
        #expect(entries.firefox == ["*://*.youtube.com/shorts*"])
    }

    // The path keeps its case in both lists.
    @Test func thePathCaseIsKeptInBothLists() {
        let entries = makeEngine(rules: ["YouTube.com/Shorts/ABC"]).browserBlockEntries
        #expect(entries.chrome == ["youtube.com/Shorts/ABC"])
        #expect(entries.firefox == ["*://*.youtube.com/Shorts/ABC*"])
    }

    // "whose domain is not covered by a whole-site block": the rule's entries drop out of both lists while the whole site is blocked, and come back when it is unblocked.
    @Test func aWholeSiteBlockMakesTheSameDomainsPathEntriesDropOut() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        let entries = engine.browserBlockEntries
        #expect(entries.chrome == youtubeCoverFromDesign, "the path entry must not appear next to the whole-site entry")
        #expect(!entries.firefox.contains("*://*.youtube.com/shorts*"))
        #expect(entries.firefox == youtubeCoverFromDesign.map { "*://*.\($0)/*" }.sorted())
        // The rule is still in the state ("keeps its path rules").
        #expect(engine.state.blockedPaths?.count == 1)

        engine.send(.unblock, domain: "youtube.com", password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        #expect(engine.state.blocked.isEmpty)
        #expect(engine.browserBlockEntries.chrome == ["youtube.com/shorts"], "with the whole site unblocked the rule matters again")
        #expect(engine.browserBlockEntries.firefox == ["*://*.youtube.com/shorts*"])
    }

    // A whole-site block of a parent domain covers a rule for its subdomain: a Chrome entry "youtube.com" already blocks every address on music.youtube.com.
    @Test func aWholeSiteBlockAlsoCoversARuleOnOneOfItsSubdomains() {
        let engine = makeEngine(rules: ["music.youtube.com/playlist"])
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        #expect(engine.browserBlockEntries.chrome == youtubeCoverFromDesign)
    }

    // A related name is covered too: youtube.com expands to youtu.be, so a rule on youtu.be is redundant.
    @Test func aWholeSiteBlockCoversARuleOnOneOfItsRelatedNames() {
        let engine = makeEngine(rules: ["youtu.be/abc"])
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        #expect(engine.browserBlockEntries.chrome == youtubeCoverFromDesign)
    }

    // The reverse is not covered: blocking only a subdomain does not cover a rule on the parent.
    @Test func aWholeSiteBlockOfASubdomainDoesNotCoverARuleOnTheParent() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.add, domain: "music.youtube.com"))
        #expect(engine.browserBlockEntries.chrome.contains("youtube.com/shorts"))
        #expect(engine.browserBlockEntries.chrome.contains("music.youtube.com"))
    }

    // A domain whose name only ends with the blocked name is not covered ("notyoutube.com" is not under "youtube.com").
    @Test func aDomainThatOnlyEndsWithTheBlockedNameIsNotCovered() {
        let engine = makeEngine(rules: ["notyoutube.com/x"])
        expectSuccess(engine.send(.add, domain: "youtube.com"))
        #expect(engine.browserBlockEntries.chrome.contains("notyoutube.com/x"))
    }

    @Test func rulesOnOtherSitesStayNextToTheWholeSiteEntriesAndEverythingIsSorted() {
        let engine = makeEngine(rules: ["youtube.com/shorts", "x.com/Home", "youtube.com/watch"])
        expectSuccess(engine.send(.add, domain: "example.com"))
        let entries = engine.browserBlockEntries
        #expect(entries.chrome == ["example.com", "x.com/Home", "youtube.com/shorts", "youtube.com/watch"])
        #expect(entries.firefox == ["*://*.example.com/*", "*://*.x.com/Home*", "*://*.youtube.com/shorts*", "*://*.youtube.com/watch*"])
        #expect(entries.chrome == entries.chrome.sorted() && entries.firefox == entries.firefox.sorted())
    }

    // The two parts are available separately (so the enforcer can keep whole sites first when it must cut a list), and the plain lists are their sorted union.
    @Test func theSeparateListsHoldWholeSitesAndPathsApartAndTheEntriesAreTheirSortedUnion() {
        let engine = makeEngine(rules: ["youtube.com/shorts"])
        expectSuccess(engine.send(.add, domain: "example.com"))
        let lists = engine.browserBlockLists
        #expect(lists.chromeSites == ["example.com"] && lists.chromePaths == ["youtube.com/shorts"])
        #expect(lists.firefoxSites == ["*://*.example.com/*"] && lists.firefoxPaths == ["*://*.youtube.com/shorts*"])
        #expect(engine.browserBlockEntries.chrome == (lists.chromeSites + lists.chromePaths).sorted())
        #expect(engine.browserBlockEntries.firefox == (lists.firefoxSites + lists.firefoxPaths).sorted())
    }

    // A whole site with a pending unblock stays in the lists until the countdown ends (it stays blocked).
    @Test func aSiteWaitingToUnblockStaysInTheListsUntilItEnds() {
        let engine = makeEngine(blocking: ["example.com"])
        engine.send(.unblock, domain: "example.com", password: rightPassword)
        _ = engine.tick(elapsed: 1799)
        #expect(engine.browserBlockEntries.chrome == ["example.com"])
        _ = engine.tick(elapsed: 1)
        #expect(engine.browserBlockEntries.chrome.isEmpty)
    }

    // Path rules never reach the hosts list, whatever else is blocked.
    @Test func pathRulesNeverChangeWhichHostsAreWritten() {
        let withRules = makeEngine(blocking: ["example.com"])
        let hostsBefore = withRules.hostsToWrite
        expectSuccess(withRules.send(.addPath, domain: "youtube.com/shorts"))
        #expect(withRules.hostsToWrite == hostsBefore)
    }
}

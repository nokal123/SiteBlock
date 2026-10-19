import Foundation
import Testing
import SiteBlockCore

// How a temporary unblock interacts with the other commands. Expected values come from Design Plans/02-core-components.md § Engine ("Command rules" for
// add, unblock, cancelUnblock and cancelUnblockPath; "Path rules" for addPath; "Temporary unblock commands"; the `onTemporaryUnblockEvent` property),
// 01-overview-and-data.md § Wire Protocol (Commands) and § Data Model (TemporaryUnblock: "A site or path rule has at most one unblock of either kind
// at a time"), and 03-daemon-cli-app.md § Daemon Runtime ("Temporary unblock log lines").

private let waitingMessage = "The temporary unblock is cancelled; reddit.com stays blocked."
private let openMessage = "reddit.com is blocked again."

// MARK: cancelUnblock and cancelUnblockPath

@Suite struct TemporaryUnblockCancelTests {
    // 02 § Engine: 'a waiting one says "The temporary unblock is cancelled; reddit.com stays blocked."'. The site stays on the list and fully blocked, with no password.
    @Test func cancelOnAWaitingTemporaryUnblockClearsItAndSaysSo() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        let hostsBefore = engine.blockedHosts
        let response = engine.send(.cancelUnblock, domain: "reddit.com")
        expectSuccess(response)
        #expect(response.message == waitingMessage)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com", "example.com"])
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
        #expect(engine.blockedHosts == hostsBefore, "a waiting site was blocked all along, so cancelling changes no list")
    }

    // 02 § Engine: 'an open one says "reddit.com is blocked again."'. The site's names are back in the block list in the same step.
    @Test func cancelOnAnOpenTemporaryUnblockEndsItAndSaysSo() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine)
        #expect(engine.temporaryUnblock(of: "reddit.com")?.isOpen == true)
        #expect(!engine.blockedHosts.contains("reddit.com"), "open: the site's names are out of the block list")
        let response = engine.send(.cancelUnblock, domain: "reddit.com")
        expectSuccess(response)
        #expect(response.message == openMessage)
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
        #expect(engine.blockedHosts.contains("reddit.com") && engine.blockedHosts.contains("redd.it"), "the block is back at once")
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    // The same two sentences for a path rule, with the rule text in place of the site.
    @Test func cancelPathOnAWaitingAndOnAnOpenTemporaryUnblockUsesTheRuleText() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 1800, start: nil, rule: true))
        let waiting = engine.send(.cancelUnblockPath, domain: "youtube.com/shorts")
        expectSuccess(waiting)
        #expect(waiting.message == "The temporary unblock is cancelled; youtube.com/shorts stays blocked.")
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == nil && engine.pathRule("youtube.com", "/shorts") != nil)
        openTemporaryUnblock(engine, "youtube.com/shorts", rule: true)
        #expect(engine.browserBlockEntries.chrome.isEmpty, "open: the rule is out of the browsers' lists")
        let open = engine.send(.cancelUnblockPath, domain: "https://www.youtube.com/shorts/")
        expectSuccess(open)
        #expect(open.message == "youtube.com/shorts is blocked again.")
        #expect(engine.browserBlockEntries.chrome == ["youtube.com/shorts"])
    }

    // 02 § Engine: "They fail nothingPending only when neither exists." A plain site, a plain rule, and an entry whose temporary unblock was already cancelled.
    @Test func cancelOnAnEntryWithNothingPendingFailsAndChangesNothing() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        let before = engine.state
        expectFailure(engine.send(.cancelUnblock, domain: "reddit.com"), .nothingPending)
        expectFailure(engine.send(.cancelUnblockPath, domain: "youtube.com/shorts"), .nothingPending)
        #expect(engine.state == before)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        expectFailure(engine.send(.cancelUnblock, domain: "reddit.com"), .nothingPending)
    }

    // 02 § Engine: a cancel "clear[s] a pendingUnblock first". An entry with only a permanent unblock loses that one, and no temporary unblock appears.
    @Test func cancelOnAPermanentUnblockStillClearsThatCountdown() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        #expect(engine.site("reddit.com")?.pendingUnblock == nil && engine.temporaryUnblock(of: "reddit.com") == nil)
        expectFailure(engine.send(.cancelUnblock, domain: "reddit.com"), .nothingPending)
    }

    // 02 § Engine: "clear a pendingUnblock first. When there is none, they clear a temporaryUnblock." The commands never make both, but a state file edited by hand could hold both:
    // the first cancel then clears the permanent unblock only, and the second clears the temporary one.
    @Test func ifBothKindsWereEverPresentTheCancelClearsThePermanentOneFirst() {
        let both = BlockedSite(domain: "reddit.com", hosts: ["reddit.com"], pendingUnblock: Countdown(seconds: 600), temporaryUnblock: TemporaryUnblock(startsIn: Countdown(seconds: 600), window: Countdown(seconds: 600)))
        let engine = Engine(state: PersistedState(blocked: [both], delaySeconds: 1800), policy: temporaryPolicy)
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        #expect(engine.site("reddit.com")?.pendingUnblock == nil)
        #expect(engine.temporaryUnblock(of: "reddit.com") != nil, "the first cancel stopped at the permanent unblock")
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
    }

    // 02 § Engine: "Neither needs a password." It works during a lockout and with no password set at all.
    @Test func cancelNeedsNoPasswordNotEvenDuringALockoutOrWithNoPasswordSet() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        exhaustPasswordAttempts(engine, domain: "example.com")
        #expect(engine.state.lockout != nil)
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)

        let temp = TemporaryUnblock(startsIn: Countdown(seconds: 600), window: Countdown(seconds: 600))
        let noPassword = Engine(state: PersistedState(blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com"], temporaryUnblock: temp)], delaySeconds: 1800), policy: temporaryPolicy)
        #expect(noPassword.state.passwordHash == nil)
        expectSuccess(noPassword.send(.cancelUnblock, domain: "reddit.com"))
        #expect(noPassword.temporaryUnblock(of: "reddit.com") == nil)
    }

    // 02 § Engine: "Every reply names the site in its normalized form ... never the text as typed; the same holds for the cancel replies." A rule is named in its display form.
    @Test func theCancelRepliesNameTheNormalizedSiteAndTheRulesDisplayFormAndNotTheTypedText() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 1800, start: 1800, rule: true))
        let site = engine.send(.cancelUnblock, domain: "WWW.REDDIT.COM")
        expectSuccess(site)
        #expect(site.message == waitingMessage)
        let rule = engine.send(.cancelUnblockPath, domain: "https://www.YouTube.com/shorts/?x=1")
        expectSuccess(rule)
        #expect(rule.message == "The temporary unblock is cancelled; youtube.com/shorts stays blocked.")
        let nothing = engine.send(.cancelUnblock, domain: "https://WWW.Reddit.com/r/all")
        expectFailure(nothing, .nothingPending)
        #expect(nothing.error?.contains("reddit.com") == true && nothing.error?.contains("Reddit") == false && nothing.error?.contains("https") == false, "got: \(nothing.error ?? "nil")")
    }

    // A cancel touches only its own entry.
    @Test func cancelLeavesEveryOtherEntryAlone() {
        let engine = makeScenarioEngine()
        let others = engine.state.blocked.filter { $0.domain != "temp.example" }
        let otherRules = (engine.state.blockedPaths ?? []).filter { $0.domain != "ruletemp.example" }
        expectSuccess(engine.send(.cancelUnblock, domain: "temp.example"))
        #expect(engine.state.blocked.filter { $0.domain != "temp.example" } == others)
        #expect((engine.state.blockedPaths ?? []).filter { $0.domain != "ruletemp.example" } == otherRules)
        #expect(engine.temporaryUnblock(ofRule: "ruletemp.example", "/shorts") != nil, "the rule's own temporary unblock is another entry's")
    }

    // The argument and lookup failures of the cancel commands are the ones they already had.
    @Test func cancelWithAMissingOrUnknownSiteFailsAsBefore() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectFailure(engine.send(.cancelUnblock), .badRequest)
        expectFailure(engine.send(.cancelUnblock, domain: "nowhere.example"), .notBlocked)
        expectFailure(engine.send(.cancelUnblockPath), .badRequest)
        expectFailure(engine.send(.cancelUnblockPath, domain: "nowhere.example/shorts"), .notBlocked)
    }

    // Cancelling frees the entry for both kinds of unblock again.
    @Test func afterACancelBothKindsOfUnblockAreAllowedAgain() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        expectSuccess(engine.temporarily("reddit.com", seconds: 900, start: 3600))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
    }
}

// MARK: add and addPath

@Suite struct TemporaryUnblockReAddTests {
    // 02 § Engine, add: "If already blocked with a temporary unblock, waiting or open, clear it and answer with the same sentence the cancel commands give for that case".
    @Test func addOnAWaitingTemporaryUnblockClearsItWithTheCancelSentence() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        let response = engine.add("reddit.com")
        expectSuccess(response)
        #expect(response.message == waitingMessage)
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"], "the same site, not a second copy")
    }

    @Test func addOnAnOpenTemporaryUnblockBlocksTheSiteAgainAtOnce() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine)
        #expect(!engine.blockedHosts.contains("reddit.com"))
        let response = engine.add("www.reddit.com")
        expectSuccess(response)
        #expect(response.message == openMessage)
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil)
        #expect(engine.blockedHosts.contains("reddit.com") && engine.blockedHosts.contains("redd.it"))
    }

    // 02 § Engine, addPath: "If the same domain and path exist with a pending unblock or a temporary unblock, clear it (the same way add does)."
    @Test func addPathOnAWaitingAndOnAnOpenTemporaryUnblockClearsItWithTheRuleText() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 1800, start: nil, rule: true))
        let same = engine.send(.addPath, domain: "youtube.com/shorts")
        expectSuccess(same)
        #expect(same.message == "The temporary unblock is cancelled; youtube.com/shorts stays blocked.")
        openTemporaryUnblock(engine, "youtube.com/shorts", rule: true)
        let open = engine.send(.addPath, domain: "YouTube.com/shorts*")
        expectSuccess(open)
        #expect(open.message == "youtube.com/shorts is blocked again.")
        #expect(engine.state.blockedPaths?.count == 1, "never a second copy of the rule")
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == nil)
    }

    // 02 § Engine, add: "this also works without a password", and the cancel commands never need one. A new site still needs a password.
    @Test func reAddingClearsATemporaryUnblockEvenWithNoPasswordSetOrDuringALockout() {
        let temp = TemporaryUnblock(startsIn: Countdown(seconds: 600), window: Countdown(seconds: 600))
        let engine = Engine(state: PersistedState(blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com"], temporaryUnblock: temp)], delaySeconds: 1800, blockedPaths: [BlockedPath(domain: "youtube.com", path: "/shorts", temporaryUnblock: temp)]), policy: temporaryPolicy)
        #expect(engine.state.passwordHash == nil)
        expectSuccess(engine.add("reddit.com"))
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil && engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == nil)
        expectFailure(engine.add("example.com"), .notSetUp)

        let locked = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(locked.temporarily("reddit.com", seconds: 1800, start: 1800))
        exhaustPasswordAttempts(locked, domain: "example.com")
        expectSuccess(locked.add("reddit.com"))
        #expect(locked.temporaryUnblock(of: "reddit.com") == nil)
    }

    // 02 § Engine, add: "An entry holding both kinds at once (only a hand-edited file can hold that) has both cleared." Afterwards the site is plainly blocked: adding it again is alreadyBlocked.
    @Test func reAddingASiteThatHoldsBothKindsClearsBoth() {
        let temp = TemporaryUnblock(startsIn: Countdown(seconds: 600), window: Countdown(seconds: 600))
        let site = BlockedSite(domain: "reddit.com", hosts: ["reddit.com"], pendingUnblock: Countdown(seconds: 600), temporaryUnblock: temp)
        let engine = Engine(state: PersistedState(blocked: [site], delaySeconds: 1800), policy: temporaryPolicy)
        expectSuccess(engine.add("reddit.com"))
        #expect(engine.site("reddit.com")?.pendingUnblock == nil, "add must clear the permanent unblock")
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil, "add must clear the temporary unblock too")
        expectFailure(engine.add("reddit.com"), .alreadyBlocked)
    }

    // The same for addPath, which clears "the same way add does" (02 § Engine, Path rules).
    @Test func reAddingARuleThatHoldsBothKindsClearsBoth() {
        let temp = TemporaryUnblock(startsIn: Countdown(seconds: 600), window: Countdown(seconds: 600))
        let rule = BlockedPath(domain: "youtube.com", path: "/shorts", pendingUnblock: Countdown(seconds: 600), temporaryUnblock: temp)
        let engine = Engine(state: PersistedState(delaySeconds: 1800, blockedPaths: [rule]), policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        #expect(engine.pathRule("youtube.com", "/shorts")?.pendingUnblock == nil, "addPath must clear the permanent unblock")
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == nil, "addPath must clear the temporary unblock too")
        expectFailure(engine.send(.addPath, domain: "youtube.com/shorts"), .alreadyBlocked)
    }

    // Re-adding a plain site is still alreadyBlocked, whatever else has a temporary unblock.
    @Test func reAddingAPlainSiteIsStillAlreadyBlocked() {
        let engine = makeScenarioEngine()
        let before = engine.state
        expectFailure(engine.add("plain.example"), .alreadyBlocked)
        expectFailure(engine.send(.addPath, domain: "ruleplain.example/shorts"), .alreadyBlocked)
        #expect(engine.state == before)
    }

    // Re-adding one site leaves every other temporary unblock alone.
    @Test func reAddingOneSiteLeavesOtherTemporaryUnblocksAlone() {
        let engine = makeScenarioEngine()
        expectSuccess(engine.add("temp.example"))
        #expect(engine.temporaryUnblock(of: "temp.example") == nil)
        #expect(engine.temporaryUnblock(ofRule: "ruletemp.example", "/shorts") != nil)
    }
}

private extension Engine {
    // add with just a domain.
    @discardableResult
    func add(_ domain: String) -> Response { send(.add, domain: domain) }
}

// MARK: the two kinds of unblock exclude each other

@Suite struct TemporaryUnblockExclusionTests {
    // 02 § Engine, unblock: ("reddit.com has a temporary unblock. Keep it blocked first if you want to unblock it for good.") and it comes before the password check.
    @Test func unblockOnASiteWithATemporaryUnblockIsAlreadyPendingWithTheDocumentedSentence() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        let before = engine.state
        let response = engine.send(.unblock, domain: "reddit.com", password: badPassword)
        expectFailure(response, .alreadyPending)
        #expect(response.error == "reddit.com has a temporary unblock. Keep it blocked first if you want to unblock it for good.")
        #expect(engine.state == before, "no wrong password counted, no countdown started")
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .alreadyPending)
        #expect(engine.site("reddit.com")?.pendingUnblock == nil && engine.state.failedAttempts == 0)
    }

    @Test func unblockPathOnARuleWithATemporaryUnblockIsAlreadyPendingWithTheRuleText() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 1800, start: nil, rule: true))
        let before = engine.state
        let response = engine.send(.unblockPath, domain: "youtube.com/shorts", password: badPassword)
        expectFailure(response, .alreadyPending)
        #expect(response.error == "youtube.com/shorts has a temporary unblock. Keep it blocked first if you want to unblock it for good.")
        #expect(engine.state == before)
    }

    // The same refusal while open: the temporary unblock is still a temporary unblock.
    @Test func unblockOnAnOpenTemporaryUnblockIsAlreadyPendingToo() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine)
        let before = engine.state
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .alreadyPending)
        #expect(engine.state == before)
    }

    // The alreadyPending check also comes before the lockout check, because the lockout belongs to the password rule that follows it.
    @Test func unblockOnATemporaryUnblockDuringALockoutIsStillAlreadyPending() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        exhaustPasswordAttempts(engine, domain: "example.com")
        let before = engine.state
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .alreadyPending)
        #expect(engine.state == before)
    }

    // 02 § Engine, step 4: 'reddit.com is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.' The countdown that was running is not restarted.
    @Test func aTemporaryUnblockOnASiteWithAPermanentUnblockIsAlreadyPendingAndKeepsTheCountdown() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.tick(elapsed: 600) == false)
        let before = engine.state
        let response = engine.temporarily("reddit.com", seconds: 1800, start: 1800)
        expectFailure(response, .alreadyPending)
        #expect(response.error == "reddit.com is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.")
        #expect(engine.state == before, "the permanent countdown keeps its 1200 s")
        #expect(engine.tick(elapsed: 1199.5) == false)
        #expect(engine.tick(elapsed: 0.5), "the permanent unblock still finishes on time")
        #expect(engine.site("reddit.com") == nil)
    }

    @Test func aTemporaryUnblockOnARuleWithAPermanentUnblockNamesTheRule() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword))
        let response = engine.temporarily("youtube.com/shorts", seconds: 1800, start: 1800, rule: true)
        expectFailure(response, .alreadyPending)
        #expect(response.error == "youtube.com/shorts is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.")
    }

    // 02 § Engine, step 4: '"reddit.com already has a temporary unblock."' for a second request, waiting or open, and the first one is not changed.
    @Test func aSecondTemporaryUnblockIsAlreadyPendingWhetherTheFirstWaitsOrIsOpen() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        var before = engine.state
        let waiting = engine.temporarily("reddit.com", seconds: 900, start: 7200)
        expectFailure(waiting, .alreadyPending)
        #expect(waiting.error == "reddit.com already has a temporary unblock.")
        #expect(engine.state == before)
        #expect(engine.tick(elapsed: 3600))
        before = engine.state
        let open = engine.temporarily("reddit.com", seconds: 900, start: 7200)
        expectFailure(open, .alreadyPending)
        #expect(open.error == "reddit.com already has a temporary unblock.")
        #expect(engine.state == before)
    }

    // Once a temporary unblock has ended, the entry is free again for both kinds.
    @Test func afterATemporaryUnblockEndsTheEntryAcceptsBothKindsAgain() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine, window: 300)
        #expect(engine.tick(elapsed: 300))
        expectSuccess(engine.temporarily("reddit.com", seconds: 900, start: 1800))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        expectFailure(engine.temporarily("reddit.com", seconds: 900, start: 1800), .alreadyPending)
    }

    // After a permanent unblock has finished the site is gone from the list, so there is nothing left to open temporarily.
    @Test func afterAPermanentUnblockFinishesATemporaryUnblockOfThatSiteIsNotBlocked() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.tick(elapsed: 1800))
        expectFailure(engine.temporarily("reddit.com", seconds: 1800, start: 1800), .notBlocked)
    }

    // The mutual exclusion holds for a rule on the same domain as a site: the site's unblock and the rule's unblock are separate entries.
    @Test func aSiteAndARuleOnTheSameDomainKeepTheirOwnKindOfUnblock() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.add("youtube.com"))
        expectSuccess(engine.send(.unblockPath, domain: "youtube.com/shorts", password: rightPassword))
        expectSuccess(engine.temporarily("youtube.com", seconds: 1800, start: 1800))
        #expect(engine.pathRule("youtube.com", "/shorts")?.pendingUnblock != nil && engine.pathRule("youtube.com", "/shorts")?.temporaryUnblock == nil)
        #expect(engine.site("youtube.com")?.temporaryUnblock != nil && engine.site("youtube.com")?.pendingUnblock == nil)
    }
}

// MARK: the sentences handed to the log

@Suite struct TemporaryUnblockEventTests {
    // 03 § Daemon Runtime: "temporary unblock approved: opens in 1 hour for 30 minutes".
    @Test func approvalReportsTheApprovedSentenceWithBothDurations() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        #expect(events.lines == [approvedLine(opensIn: "1 hour", window: "30 minutes")])
    }

    // A refused request is not an event.
    @Test func aRefusedRequestReportsNothing() {
        let engine = makeScenarioEngine()
        let events = recordEvents(of: engine)
        for refusal in RefusalCase.all { _ = engine.handle(refusal.request, peerUID: 501) }
        _ = engine.send(.cancelUnblock, domain: "plain.example")
        _ = engine.send(.cancelUnblock, domain: "nowhere.example")
        #expect(events.lines.isEmpty, "got: \(events.lines)")
    }

    @Test func aWaitingOneThatIsCancelledReportsTheCancelledSentence() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 1800))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        #expect(events.lines == [approvedLine(opensIn: "30 minutes", window: "30 minutes"), cancelledLine])
    }

    @Test func anOpenOneThatIsEndedEarlyReportsOpenedThenEndedEarly() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        openTemporaryUnblock(engine, window: 1800)
        #expect(events.lines == [approvedLine(opensIn: "30 minutes", window: "30 minutes"), openedLine])
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        #expect(events.lines.last == endedEarlyLine)
        #expect(events.lines.count == 3)
    }

    // The full run: approved, opened once, ended once, and nothing more however long the clock runs on afterwards.
    @Test func aFullRunReportsApprovedOpenedAndEndedExactlyOnceEach() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        engine.tick(1, times: 1800 + 600 + 50)
        _ = engine.tick(elapsed: 100_000)
        #expect(events.lines == [approvedLine(opensIn: "30 minutes", window: "10 minutes"), openedLine, endedLine])
    }

    // 02 § Engine, tick rule: "a gap that covers both reports only the ending."
    @Test func aGapThatCoversTheWholeStartWaitAndWindowReportsOnlyTheEnding() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        #expect(engine.tick(elapsed: 5000))
        #expect(events.lines == [approvedLine(opensIn: "30 minutes", window: "10 minutes"), endedLine])
    }

    // The sentences are the same for a path rule, and no sentence names the site or the rule (03 § Daemon Runtime: "No line names the site or rule").
    @Test func aPathRuleReportsTheSameSentencesAndNoSentenceNamesTheSiteOrTheRule() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        let events = recordEvents(of: engine)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 600, start: 1800, rule: true))
        _ = engine.tick(elapsed: 1800)
        _ = engine.tick(elapsed: 600)
        let expected = [approvedLine(opensIn: "30 minutes", window: "10 minutes"), approvedLine(opensIn: "30 minutes", window: "10 minutes"), openedLine, openedLine, endedLine, endedLine]
        #expect(events.lines == expected)
        for line in events.lines { #expect(!line.lowercased().contains("reddit") && !line.lowercased().contains("youtube") && !line.contains("shorts"), "\(line)") }
    }

    // 02 § Engine, onTemporaryUnblockEvent: a request that the password check refuses (wrong password, a lockout, no password set) is not approved, so no approved sentence is reported.
    @Test func aValidRequestThatThePasswordCheckRefusesReportsNoApproval() {
        let wrong = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let wrongEvents = recordEvents(of: wrong)
        expectFailure(wrong.temporarily("reddit.com", password: badPassword, seconds: 1800, start: 1800), .wrongPassword)
        #expect(wrongEvents.lines.isEmpty, "wrong password: \(wrongEvents.lines)")

        let locked = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        exhaustPasswordAttempts(locked, domain: "example.com")
        let lockedEvents = recordEvents(of: locked)
        expectFailure(locked.temporarily("reddit.com", seconds: 1800, start: 1800), .lockedOut)
        #expect(lockedEvents.lines.isEmpty, "lockout: \(lockedEvents.lines)")

        let none = Engine(state: PersistedState(blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com"])], delaySeconds: 1800), policy: temporaryPolicy)
        let noneEvents = recordEvents(of: none)
        expectFailure(none.temporarily("reddit.com", seconds: 1800, start: 1800), .notSetUp)
        #expect(noneEvents.lines.isEmpty, "no password set: \(noneEvents.lines)")

        // Positive control: the same engine reports the approval once the password check passes.
        let right = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let rightEvents = recordEvents(of: right)
        expectSuccess(right.temporarily("reddit.com", seconds: 1800, start: 1800))
        #expect(rightEvents.lines == [approvedLine(opensIn: "30 minutes", window: "30 minutes")])
    }

    // `add` and `addPath` clear a temporary unblock the same way the cancel commands do, and report it the same way: waiting gives [approved, cancelled], open gives [approved, opened, ended early].
    @Test(arguments: [false, true])
    func reAddingAWaitingTemporaryUnblockReportsItCancelled(rule: Bool) {
        let engine = makeEngine(blocking: rule ? [] : ["reddit.com"], policy: temporaryPolicy)
        if rule { expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts")) }
        let events = recordEvents(of: engine)
        let name = rule ? "youtube.com/shorts" : "reddit.com"
        expectSuccess(engine.temporarily(name, seconds: 600, start: 1800, rule: rule))
        expectSuccess(engine.send(rule ? .addPath : .add, domain: name))
        #expect(events.lines == [approvedLine(opensIn: "30 minutes", window: "10 minutes"), cancelledLine])
    }

    @Test(arguments: [false, true])
    func reAddingAnOpenTemporaryUnblockReportsItEndedEarly(rule: Bool) {
        let engine = makeEngine(blocking: rule ? [] : ["reddit.com"], policy: temporaryPolicy)
        if rule { expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts")) }
        let events = recordEvents(of: engine)
        let name = rule ? "youtube.com/shorts" : "reddit.com"
        openTemporaryUnblock(engine, name, window: 600, rule: rule)
        expectSuccess(engine.send(rule ? .addPath : .add, domain: name))
        #expect(events.lines == [approvedLine(opensIn: "30 minutes", window: "10 minutes"), openedLine, endedEarlyLine])
    }

    // The direct cancel of a rule reports the same two sentences as the cancel of a site.
    @Test func cancelUnblockPathReportsCancelledWhileWaitingAndEndedEarlyWhileOpen() {
        let engine = makeEngine(policy: temporaryPolicy)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        let events = recordEvents(of: engine)
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 600, start: 1800, rule: true))
        expectSuccess(engine.send(.cancelUnblockPath, domain: "youtube.com/shorts"))
        openTemporaryUnblock(engine, "youtube.com/shorts", window: 600, rule: true)
        expectSuccess(engine.send(.cancelUnblockPath, domain: "youtube.com/shorts"))
        let approved = approvedLine(opensIn: "30 minutes", window: "10 minutes")
        #expect(events.lines == [approved, cancelledLine, approved, openedLine, endedEarlyLine])
    }

    // A permanent unblock is not a temporary unblock event.
    @Test func aPermanentUnblockReportsNoTemporaryUnblockEvent() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com"))
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        _ = engine.tick(elapsed: 5000)
        #expect(events.lines.isEmpty)
    }
}

// MARK: generated command sequences

@Suite struct TemporaryUnblockInvariantTests {
    // Checks every rule of the data model that must hold after any command or tick (01 § Data Model, TemporaryUnblock; 02 § Engine, tick rule, `blockedHosts`).
    // Returns a description of the first rule that is broken, or nil.
    private func firstViolation(_ engine: Engine) -> String? {
        var entries: [(name: String, pending: Countdown?, temp: TemporaryUnblock?)] = engine.state.blocked.map { ($0.domain, $0.pendingUnblock, $0.temporaryUnblock) }
        entries += (engine.state.blockedPaths ?? []).map { ($0.domain + $0.path, $0.pendingUnblock, $0.temporaryUnblock) }
        for entry in entries {
            if entry.pending != nil && entry.temp != nil { return "\(entry.name) has both kinds of unblock" }
            guard let temp = entry.temp else { continue }
            if temp.isFinished { return "\(entry.name) keeps a finished temporary unblock" }
            if temp.startsIn.remainingSeconds < 0 || temp.window.remainingSeconds < 0 { return "\(entry.name) has a countdown below zero" }
            if temp.startsIn.remainingSeconds > 0 && temp.window.remainingSeconds != temp.window.totalSeconds { return "\(entry.name) counted its window down before it opened" }
            if temp.startsIn.remainingSeconds > temp.startsIn.totalSeconds || temp.window.remainingSeconds > temp.window.totalSeconds { return "\(entry.name) has more time left than it started with" }
        }
        // 02 § Engine, blockedHosts: every host of every site that is not open, and nothing else.
        let expectedHosts = Set(engine.state.blocked.filter { $0.temporaryUnblock?.isOpen != true }.flatMap(\.hosts))
        if Set(engine.blockedHosts) != expectedHosts { return "blockedHosts is not the hosts of the sites that are not open" }
        return nil
    }

    // Random commands and ticks on three sites and two rules, with valid and invalid arguments and right and wrong passwords. After every step the data model rules hold, and no site or rule
    // disappears unless it had a permanent unblock (a temporary unblock only ever ends; it never removes the site).
    @Test(arguments: Array(0..<24))
    func randomSequencesKeepTheDataModelRules(seed: Int) {
        var generator = FuzzGenerator(seed: UInt64(seed) &+ 7_000)
        let engine = makeEngine(blocking: ["a.example", "b.example", "c.example"], policy: policyWithDelay(60))
        for rule in ["d.example/x", "e.example/y"] { expectSuccess(engine.send(.addPath, domain: rule)) }
        let sites = ["a.example", "b.example", "c.example", "nowhere.example"]
        let rules = ["d.example/x", "e.example/y", "nowhere.example/z"]
        for step in 0..<300 {
            let survivors = engine.state.blocked.filter { $0.pendingUnblock == nil }.map(\.domain)
            let ruleSurvivors = (engine.state.blockedPaths ?? []).filter { $0.pendingUnblock == nil }.map { $0.domain + $0.path }
            let useRule = Bool.random(using: &generator)
            let target = useRule ? rules.randomElement(using: &generator)! : sites.randomElement(using: &generator)!
            let password = Int.random(in: 0..<10, using: &generator) == 0 ? badPassword : rightPassword
            let operation = Int.random(in: 0..<7, using: &generator)
            let label: String
            switch operation {
            case 0, 1:
                let seconds = [299, 300, 600, 14_400, 14_401].randomElement(using: &generator)!
                let start = [nil, 59, 60, 120, 3600, 604_800, 604_801].randomElement(using: &generator)!
                label = "temporarily \(target) window \(seconds) start \(String(describing: start))"
                engine.temporarily(target, password: password, seconds: seconds, start: start, rule: useRule)
            case 2:
                label = "unblock \(target)"
                engine.send(useRule ? .unblockPath : .unblock, domain: target, password: password)
            case 3:
                label = "cancel \(target)"
                engine.send(useRule ? .cancelUnblockPath : .cancelUnblock, domain: target)
            case 4:
                label = "add \(target)"
                engine.send(useRule ? .addPath : .add, domain: target)
            default:
                let elapsed = [0.125, 1, 30, 59.875, 60, 61, 300, 3600, 20_000].randomElement(using: &generator)!
                label = "tick \(elapsed)"
                _ = engine.tick(elapsed: elapsed)
            }
            #expect(firstViolation(engine) == nil, "seed \(seed), step \(step) (\(label)): \(firstViolation(engine) ?? "")")
            for name in survivors { #expect(engine.site(name) != nil, "seed \(seed), step \(step) (\(label)): \(name) vanished without a permanent unblock") }
            for name in ruleSurvivors { #expect((engine.state.blockedPaths ?? []).contains { $0.domain + $0.path == name }, "seed \(seed), step \(step) (\(label)): rule \(name) vanished without a permanent unblock") }
        }
    }
}

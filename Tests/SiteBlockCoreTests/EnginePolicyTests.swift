import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § Engine (Properties, "Who may set up", "Site cap", "Command rules",
// "Hosts health") and 01-overview-and-data.md § Fixed Policy Values, § Commands (setup, add) and § Data Model (delaySeconds).

@Suite struct PolicyValueTests {
    // 02-core-components.md § Engine: "Policy.production must hold exactly 1800, 60, 604800, 172800, 900, 5, 210000 and 500."
    // The design lists them in the order of the fields: defaultDelaySeconds, minDelaySeconds, maxDelaySeconds, recoverySeconds,
    // lockoutSeconds, maxFailedAttempts, pbkdf2Iterations, maxSites. Each field is checked on its own so a failure names the field.
    @Test func productionPolicyHoldsExactlyTheDesignsNumbersFieldByField() {
        let production = Policy.production
        #expect(production.defaultDelaySeconds == 1800, "default unblock delay is 30 minutes")
        #expect(production.minDelaySeconds == 60, "the shortest delay setDelay accepts is 60 seconds")
        #expect(production.maxDelaySeconds == 604_800, "the longest delay setDelay accepts is 7 days")
        #expect(production.recoverySeconds == 172_800, "recovery waits 48 hours")
        #expect(production.lockoutSeconds == 900, "a lockout lasts 15 minutes")
        #expect(production.maxFailedAttempts == 5, "five wrong passwords trigger a lockout")
        #expect(production.pbkdf2Iterations == 210_000)
        #expect(production.maxSites == 500)
    }

    @Test func productionPolicyEqualsAPolicyBuiltFromTheDesignsNumbers() {
        let fromDesign = Policy(defaultDelaySeconds: 1800, minDelaySeconds: 60, maxDelaySeconds: 604_800, recoverySeconds: 172_800, lockoutSeconds: 900, maxFailedAttempts: 5, pbkdf2Iterations: 210_000, maxSites: 500)
        #expect(Policy.production == fromDesign)
    }

    // 02-core-components.md § Engine, Site cap: "Policy.fastForTests.maxSites is 20, so tests can reach the cap quickly."
    @Test func theFastTestPolicyHasASiteCapOfTwenty() {
        #expect(Policy.fastForTests.maxSites == 20)
    }

    // The test helper's policy is the production policy with only the hashing cost lowered, so the cap in it is the production cap.
    @Test func theSuiteSharedDesignPolicyUsesTheProductionNumbersExceptTheHashingCost() {
        var production = Policy.production
        production.pbkdf2Iterations = designPolicy.pbkdf2Iterations
        #expect(designPolicy == production)
    }

    // 01-overview-and-data.md § Data Model: "delaySeconds ... Default 1800 (30 minutes)". A fresh install, the production policy and the
    // engine built from them must all agree on that number.
    @Test func aFreshStateAndTheProductionPolicyAgreeOnTheDefaultDelay() {
        #expect(PersistedState.fresh().delaySeconds == 1800)
        #expect(PersistedState.fresh().delaySeconds == Policy.production.defaultDelaySeconds)
        let engine = Engine(state: PersistedState.fresh(delaySeconds: Policy.production.defaultDelaySeconds), policy: .production)
        #expect(engine.send(.status).status?.delaySeconds == 1800)
    }

    // The production policy drives the real behavior, not just a constant: the delay range and the 30 minute default are used by a
    // real engine. (setup is skipped because it would run 210,000 hashing rounds; a cheaper policy with the same ranges is used.)
    @Test func anEngineBuiltFromTheProductionRangesAcceptsTheEdgesAndRejectsOneOutside() {
        var policy = Policy.production
        policy.pbkdf2Iterations = 1000
        let engine = makeEngine(policy: policy)
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: 59), .invalidDelay)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 604_800))
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: 604_801), .invalidDelay)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 60))
        #expect(engine.state.pendingDelayChange?.countdown == Countdown(seconds: 604_800))
    }
}

@Suite struct EngineSiteCapTests {
    // A fast-test engine (cap 20, delay 2 s) holding exactly 20 sites.
    private func engineAtTheCap() -> Engine {
        makeEngine(blocking: (0..<20).map { "site\($0).example.com" }, policy: .fastForTests)
    }

    // 02-core-components.md § Engine, Site cap: "adding a new site when policy.maxSites sites are already blocked fails with tooManySites."
    @Test func theTwentyFirstNewSiteFailsWithTooManySitesAndChangesNothing() {
        let engine = engineAtTheCap()
        #expect(engine.state.blocked.count == 20)
        let before = engine.state
        let hostsBefore = engine.blockedHosts
        expectFailure(engine.send(.add, domain: "one-too-many.example.com"), .tooManySites)
        #expect(engine.state == before)
        #expect(engine.blockedHosts == hostsBefore)
        #expect(engine.state.blocked.count == 20)
    }

    @Test func theTwentiethSiteIsStillAccepted() {
        let engine = makeEngine(blocking: (0..<19).map { "site\($0).example.com" }, policy: .fastForTests)
        expectSuccess(engine.send(.add, domain: "site19.example.com"))
        #expect(engine.state.blocked.count == 20)
        expectFailure(engine.send(.add, domain: "site20.example.com"), .tooManySites)
    }

    // "Re-adding an existing site (to cancel its unblock) is not affected."
    @Test func reAddingASiteWithAPendingUnblockAtTheCapStillCancelsTheUnblock() {
        let engine = engineAtTheCap()
        expectSuccess(engine.send(.unblock, domain: "site7.example.com", password: rightPassword))
        #expect(engine.pendingUnblock(of: "site7.example.com") != nil)
        let response = engine.send(.add, domain: "site7.example.com")
        expectSuccess(response)
        #expect(response.message == "Unblock cancelled; site7.example.com stays blocked.")
        #expect(engine.pendingUnblock(of: "site7.example.com") == nil)
        #expect(engine.state.blocked.count == 20)
        // The cap itself is still in force afterwards.
        expectFailure(engine.send(.add, domain: "one-too-many.example.com"), .tooManySites)
    }

    // A site waiting to unblock still counts toward the cap, because it is still blocked.
    @Test func aSiteWaitingToUnblockStillCountsTowardTheCap() {
        let engine = engineAtTheCap()
        expectSuccess(engine.send(.unblock, domain: "site0.example.com", password: rightPassword))
        expectFailure(engine.send(.add, domain: "one-too-many.example.com"), .tooManySites)
    }

    // An existing site with nothing pending gets alreadyBlocked, the same answer as below the cap.
    @Test func reAddingAnExistingSiteWithNothingPendingAtTheCapIsAlreadyBlocked() {
        let engine = engineAtTheCap()
        expectFailure(engine.send(.add, domain: "site3.example.com"), .alreadyBlocked)
        expectFailure(engine.send(.add, domain: "https://www.site3.example.com/path"), .alreadyBlocked)
    }

    // An invalid name is refused as invalid whether or not the list is full: normalizing comes first.
    @Test func anInvalidNameAtTheCapIsStillInvalidDomain() {
        let engine = engineAtTheCap()
        expectFailure(engine.send(.add, domain: "1.2.3.4"), .invalidDomain)
        expectFailure(engine.send(.add, domain: ""), .invalidDomain)
    }

    // When an unblock finishes its slot is free again, so the list can be refilled to the cap and no further.
    @Test func aFinishedUnblockFreesASlotForOneNewSite() {
        let engine = engineAtTheCap()
        expectSuccess(engine.send(.unblock, domain: "site5.example.com", password: rightPassword))
        #expect(engine.tick(elapsed: 2) == true)
        #expect(engine.state.blocked.count == 19)
        expectSuccess(engine.send(.add, domain: "replacement.example.com"))
        #expect(engine.state.blocked.count == 20)
        expectFailure(engine.send(.add, domain: "another.example.com"), .tooManySites)
    }

    // The production cap through the engine's default policy: 500 sites fit and the 501st does not.
    @Test func theProductionCapIsFiveHundredSites() {
        let engine = makeEngine(blocking: (0..<500).map { "s\($0).example.com" })
        #expect(engine.state.blocked.count == 500)
        expectFailure(engine.send(.add, domain: "s500.example.com"), .tooManySites)
        #expect(engine.state.blocked.count == 500)
    }

    // The cap is the policy's number, not a constant: any other value moves the line.
    @Test(arguments: [1, 3, 7])
    func theCapFollowsThePolicysMaxSites(cap: Int) {
        var policy = designPolicy
        policy.maxSites = cap
        let engine = makeEngine(blocking: (0..<cap).map { "s\($0).example.com" }, policy: policy)
        expectFailure(engine.send(.add, domain: "extra.example.com"), .tooManySites)
        #expect(engine.state.blocked.count == cap)
    }

    // A state loaded from disk can hold more sites than the cap (an older version, or a hand edit). Nothing more may be added then.
    @Test func aLoadedStateAlreadyOverTheCapAcceptsNoNewSite() throws {
        var state = PersistedState.fresh(delaySeconds: 2)
        state.passwordHash = try PasswordHasher.make(password: rightPassword, iterations: 1000)
        state.blocked = (0..<25).map { BlockedSite(domain: "old\($0).example.com", hosts: DomainExpander.expand("old\($0).example.com")) }
        let engine = Engine(state: state, policy: .fastForTests)
        expectFailure(engine.send(.add, domain: "new.example.com"), .tooManySites)
        #expect(engine.state.blocked.count == 25)
    }
}

@Suite struct EngineSetupAccessTests {
    // A fresh engine with no password whose console user is the given uid (nil means nobody is known to be at the screen).
    private func setupEngine(console: uid_t?) -> Engine {
        let engine = makeEngine(password: nil)
        engine.consoleUID = { console }
        return engine
    }

    // 02-core-components.md § Engine, "Who may set up": with a console user known, setup succeeds for peerUID 0 and for that user.
    @Test(arguments: [uid_t(501), uid_t(0)])
    func setupSucceedsForRootAndForTheConsoleUser(peer: uid_t) {
        let engine = setupEngine(console: 501)
        let response = engine.send(.setup, password: rightPassword, uid: peer)
        expectSuccess(response)
        #expect(engine.state.passwordHash != nil)
    }

    @Test(arguments: [uid_t(502), uid_t(1), uid_t(500), uid_t(65_534), UInt32.max])
    func setupFromAnyOtherUserFailsWithNotAllowedAndSetsNoPassword(peer: uid_t) {
        let engine = setupEngine(console: 501)
        let before = engine.state
        expectFailure(engine.send(.setup, password: rightPassword, uid: peer), .notAllowed)
        #expect(engine.state == before)
        #expect(engine.send(.status).status?.passwordSet == false)
    }

    // "The check comes before alreadySetUp": a caller who may not set up learns nothing about whether a password exists.
    @Test func notAllowedIsCheckedBeforeAlreadySetUp() {
        let engine = setupEngine(console: 501)
        expectSuccess(engine.send(.setup, password: rightPassword, uid: 501))
        expectFailure(engine.send(.setup, password: "another-pass", uid: 502), .notAllowed)
        expectFailure(engine.send(.setup, password: "another-pass", uid: 501), .alreadySetUp)
        expectFailure(engine.send(.setup, password: "another-pass", uid: 0), .alreadySetUp)
    }

    // With the default consoleUID (nil), anyone may set up; that is what sandbox runs and tests rely on.
    @Test(arguments: [uid_t(0), uid_t(501), uid_t(502), uid_t(65_534)])
    func withTheDefaultConsoleUIDAnyCallerMaySetUp(peer: uid_t) {
        let engine = makeEngine(password: nil)
        #expect(engine.consoleUID() == nil)
        expectSuccess(engine.send(.setup, password: rightPassword, uid: peer))
    }

    @Test(arguments: [uid_t(0), uid_t(501), uid_t(502)])
    func whenTheConsoleUserIsNotKnownAnyCallerMaySetUp(peer: uid_t) {
        expectSuccess(setupEngine(console: nil).send(.setup, password: rightPassword, uid: peer))
    }

    // This is the attack the rule exists for: right after a recovery clears the password, another account must not claim it.
    @Test func afterAFinishedRecoveryAnotherAccountCannotClaimThePasswordButTheConsoleUserCan() {
        let engine = setupEngine(console: 501)
        expectSuccess(engine.send(.setup, password: rightPassword, uid: 501))
        expectSuccess(engine.send(.add, domain: "reddit.com", uid: 501))
        expectSuccess(engine.send(.recoveryStart, uid: 0))
        #expect(engine.tick(elapsed: 172_800) == true)
        #expect(engine.state.passwordHash == nil)
        expectFailure(engine.send(.setup, password: "attacker-pass", uid: 502), .notAllowed)
        #expect(engine.state.passwordHash == nil)
        expectSuccess(engine.send(.setup, password: "owner-new-pass", uid: 501))
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: "owner-new-pass", uid: 501))
    }

    // Only setup is restricted. Every other command works for any user, as before.
    @Test func otherUsersCanStillUseEveryCommandThatIsNotSetup() {
        let engine = setupEngine(console: 501)
        expectSuccess(engine.send(.setup, password: rightPassword, uid: 501))
        expectSuccess(engine.send(.status, uid: 502))
        expectSuccess(engine.send(.add, domain: "reddit.com", uid: 502))
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword, uid: 502))
        expectSuccess(engine.send(.cancelUnblock, domain: "reddit.com", uid: 502))
        expectFailure(engine.send(.recoveryStart, uid: 502), .notRoot)
    }

    // The runtime installs a function that reads /dev/console, so the answer must be looked up on every setup, not remembered.
    @Test func theConsoleUserIsAskedAtEverySetupAndNotRemembered() {
        let engine = makeEngine(password: nil)
        var console: uid_t? = 501
        engine.consoleUID = { console }
        expectFailure(engine.send(.setup, password: rightPassword, uid: 502), .notAllowed)
        console = 502
        expectSuccess(engine.send(.setup, password: rightPassword, uid: 502))
    }

    // At the login window the console belongs to root, so a user account has no more right to set up than any other non-root account.
    @Test func whenTheConsoleOwnerIsRootOnlyRootMaySetUp() {
        let blocked = setupEngine(console: 0)
        expectFailure(blocked.send(.setup, password: rightPassword, uid: 501), .notAllowed)
        expectSuccess(blocked.send(.setup, password: rightPassword, uid: 0))
    }
}

@Suite struct EngineAddWithoutAPasswordTests {
    // The state after a finished recovery: a site that was already counting down to unblock, and no password any more.
    // The recipe from 02-core-components.md § Engine (add): start recovery, tick 172700, unblock, tick 100.
    private func engineWhoseRecoveryFinishedMidUnblock() -> Engine {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.recoveryStart, uid: 0))
        _ = engine.tick(elapsed: 172_700)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.tick(elapsed: 100) == true, "the recovery finishes on this tick")
        return engine
    }

    // "This works even when no password is set, because after a finished recovery add is the only way to stop an unblock that was
    // already counting down."
    @Test func addCancelsAPendingUnblockEvenWhenNoPasswordIsSet() {
        let engine = engineWhoseRecoveryFinishedMidUnblock()
        #expect(engine.state.passwordHash == nil)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1700, totalSeconds: 1800))
        let response = engine.send(.add, domain: "reddit.com")
        expectSuccess(response)
        #expect(response.message == "Unblock cancelled; reddit.com stays blocked.")
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
        #expect(response.status?.passwordSet == false)
        #expect(engine.tick(elapsed: 100_000) == false)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    @Test func addCancelsThePendingUnblockWhateverWayTheSiteIsWritten() {
        let engine = engineWhoseRecoveryFinishedMidUnblock()
        expectSuccess(engine.send(.add, domain: "HTTPS://WWW.Reddit.com/r/swift"))
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
    }

    // The same call on a site with nothing pending is alreadyBlocked, never notSetUp: the site is blocked and there is nothing to add.
    @Test func addOfAnAlreadyBlockedSiteWithNothingPendingIsAlreadyBlockedEvenWithNoPassword() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.recoveryStart, uid: 0))
        _ = engine.tick(elapsed: 172_800)
        #expect(engine.state.passwordHash == nil)
        expectFailure(engine.send(.add, domain: "reddit.com"), .alreadyBlocked)
        expectFailure(engine.send(.add, domain: "www.reddit.com"), .alreadyBlocked)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    // Only a new site needs a password to exist.
    @Test func addOfANewSiteWithNoPasswordStillFailsWithNotSetUp() {
        let engine = engineWhoseRecoveryFinishedMidUnblock()
        expectFailure(engine.send(.add, domain: "example.com"), .notSetUp)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
        #expect(engine.pendingUnblock(of: "reddit.com") != nil, "a refused add must not cancel anything")
    }

    // A pending unblock on one site is not cancelled by adding a different site, and adding it still leaves the first one counting down.
    @Test func addOfADifferentSiteDoesNotCancelAnotherSitesPendingUnblock() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        expectSuccess(engine.send(.add, domain: "example.com"))
        #expect(engine.pendingUnblock(of: "reddit.com") != nil)
        #expect(engine.pendingUnblock(of: "example.com") == nil)
    }
}

@Suite struct EngineHostsHealthTests {
    // 02-core-components.md § Engine, "Hosts health": setHostsHealthy records the result of the runtime's last enforcement pass, and
    // every snapshot built by handle reports it as hostsFileHealthy. It starts as true.
    @Test func hostsHealthStartsTrueAndSetHostsHealthyFalseShowsInStatus() {
        let engine = makeEngine(blocking: ["reddit.com"])
        #expect(engine.send(.status).status?.hostsFileHealthy == true)
        engine.setHostsHealthy(false)
        #expect(engine.send(.status).status?.hostsFileHealthy == false)
        engine.setHostsHealthy(true)
        #expect(engine.send(.status).status?.hostsFileHealthy == true)
    }

    @Test func everySuccessfulCommandReportsTheRecordedHealth() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.setHostsHealthy(false)
        let responses = [
            engine.send(.status), engine.send(.add, domain: "example.com"), engine.send(.unblock, domain: "reddit.com", password: rightPassword),
            engine.send(.cancelUnblock, domain: "reddit.com"), engine.send(.setDelay, password: rightPassword, seconds: 3600),
            engine.send(.changePassword, password: rightPassword, newPassword: "brand-new-pass"),
        ]
        for response in responses {
            expectSuccess(response)
            #expect(response.status?.hostsFileHealthy == false, "a success reported the wrong hosts health: \(response.message ?? "no message")")
        }
        engine.setHostsHealthy(true)
        #expect(engine.send(.status).status?.hostsFileHealthy == true)
    }

    // The health set on one engine is not shared with another.
    @Test func hostsHealthBelongsToTheEngineItWasSetOn() {
        let sick = makeEngine()
        let well = makeEngine()
        sick.setHostsHealthy(false)
        #expect(sick.send(.status).status?.hostsFileHealthy == false)
        #expect(well.send(.status).status?.hostsFileHealthy == true)
    }
}

// 02-core-components.md § Engine, Properties: "`static let privateRelayHosts` — [mask-h2.icloud.com, mask.icloud.com]" and "`var hostsToWrite`
// — what the runtime writes into the hosts file: `blockedHosts` plus `privateRelayHosts` when `blockedHosts` is not empty, sorted and
// without duplicates; empty when nothing is blocked."
@Suite struct EngineHostsToWriteTests {
    @Test func theTwoPrivateRelayNamesAreExactlyTheOnesInTheDesign() {
        #expect(Engine.privateRelayHosts == ["mask-h2.icloud.com", "mask.icloud.com"])
    }

    @Test func withNothingBlockedThereIsNothingToWriteSoPrivateRelayIsLeftAlone() {
        let engine = makeEngine()
        #expect(engine.hostsToWrite.isEmpty)
        #expect(makeEngine(password: nil).hostsToWrite.isEmpty)
    }

    @Test func withASiteBlockedTheRelayNamesAreAddedToItsHostsInSortedOrder() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let expected = (DomainExpander.expand("reddit.com") + ["mask-h2.icloud.com", "mask.icloud.com"]).sorted()
        #expect(engine.hostsToWrite == expected)
        #expect(Set(engine.hostsToWrite).count == engine.hostsToWrite.count)
    }

    // blockedHosts is only the blocked sites' own hosts; the relay names are added by hostsToWrite alone.
    @Test func blockedHostsNeverContainsTheRelayNames() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        #expect(!engine.blockedHosts.contains("mask.icloud.com") && !engine.blockedHosts.contains("mask-h2.icloud.com"))
        #expect(engine.blockedHosts == (DomainExpander.expand("reddit.com") + DomainExpander.expand("example.com")).sorted())
    }

    // A user who blocks mask.icloud.com themselves must not make the name appear twice in the hosts file section.
    @Test func aRelayNameThatIsAlsoABlockedHostAppearsOnlyOnce() {
        let engine = makeEngine(blocking: ["mask.icloud.com"])
        #expect(engine.blockedHosts.contains("mask.icloud.com"))
        #expect(engine.hostsToWrite.filter { $0 == "mask.icloud.com" }.count == 1)
        #expect(engine.hostsToWrite.filter { $0 == "mask-h2.icloud.com" }.count == 1)
        #expect(Set(engine.hostsToWrite).count == engine.hostsToWrite.count)
        #expect(engine.hostsToWrite == engine.hostsToWrite.sorted())
    }

    // A site waiting to unblock is still blocked, so the relay names stay; when the last site's wait ends, they go with it.
    @Test func theRelayNamesStayWhileAnUnblockWaitsAndGoWhenTheLastSiteIsRemoved() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.hostsToWrite.contains("mask.icloud.com") && engine.hostsToWrite.contains("mask-h2.icloud.com"))
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.blockedHosts.isEmpty)
        #expect(engine.hostsToWrite.isEmpty)
    }

    // With two sites, finishing one unblock keeps the relay names because the other site is still blocked.
    @Test func theRelayNamesStayWhileAnyOtherSiteIsStillBlocked() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        _ = engine.tick(elapsed: 1800)
        #expect(engine.state.blocked.map(\.domain) == ["example.com"])
        #expect(engine.hostsToWrite == (DomainExpander.expand("example.com") + Engine.privateRelayHosts).sorted())
    }

    // The list goes straight into the hosts file renderer, which writes the two address lines for each name.
    @Test func renderingHostsToWriteWritesTheTwoAddressLinesForEachRelayName() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let result = HostsFileEditor.render(original: "127.0.0.1\tlocalhost\n", blockedHosts: engine.hostsToWrite)
        for name in ["mask-h2.icloud.com", "mask.icloud.com"] {
            #expect(result.contains("\n0.0.0.0 \(name)\n"))
            #expect(result.contains("\n:: \(name)\n"))
        }
        #expect(HostsFileEditor.render(original: result, blockedHosts: engine.hostsToWrite) == result)
    }
}

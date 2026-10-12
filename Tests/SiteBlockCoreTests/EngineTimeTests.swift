import Foundation
import Testing
import SiteBlockCore

// Engine behavior that depends on the passage of time, driven with fake elapsed values through tick(elapsed:).
// Expected values come from Design Plans/02-core-components.md § Engine (Password check rule, Tick rule), § Models and
// Protocol Types (Countdown), 01-overview-and-data.md § Data Model and § Fixed Policy Values, and
// 05-testing-and-operations.md § Unit Tests (EngineTests).

@Suite struct EngineCountdownTests {
    // 05-testing-and-operations.md: unblock finishes only after the full delay and not one tick earlier.
    @Test func anUnblockFinishesOnTheTickThatReachesTheFullDelayAndNotOneSecondEarlier() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(elapsed: 1799) == false)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com", "example.com"])
        #expect(engine.blockedHosts.contains("reddit.com"))
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1, totalSeconds: 1800))
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.state.blocked.map(\.domain) == ["example.com"])
        #expect(!engine.blockedHosts.contains("reddit.com"))
        #expect(!engine.blockedHosts.contains("redd.it"))
    }

    @Test func anUnblockSurvivesAnElapsedTimeJustUnderTheDelayAndEndsWithOneSliceOfMore() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(elapsed: 1799.999) == false)
        #expect(engine.state.blocked.count == 1)
        #expect(engine.send(.status).status?.blocked.first?.unblockSecondsRemaining == 1, "a running countdown must never show 0")
        #expect(engine.tick(elapsed: 0.001) == true)
        #expect(engine.state.blocked.isEmpty)
    }

    @Test func anUnblockDrivenByTheDaemonsTwoSecondTicksEndsOnTheNineHundredthTickExactly() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(2.0, times: 899) == 0)
        #expect(engine.state.blocked.count == 1)
        #expect(engine.tick(elapsed: 2.0) == true)
        #expect(engine.state.blocked.isEmpty)
    }

    @Test func anUnblockDrivenByOneSecondTicksReportsExactlyOneSaveAndEndsOnTheLastTick() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(1.0, times: 1799) == 0)
        #expect(engine.state.blocked.count == 1)
        #expect(engine.tick(elapsed: 1.0) == true)
        #expect(engine.tick(1.0, times: 50) == 0)
    }

    // Tenths of a second are not exact in binary floating point: subtracting 0.1 from 1,800 eighteen thousand times in plain Double
    // arithmetic leaves a residue of about 5.4e-10 s, not zero. That is below the 1e-9 s tolerance in Countdown.advance
    // (02-core-components.md § Models and Protocol Types), so the countdown counts as finished; without the tolerance it would
    // need one more tick. The design measures elapsed real time, so 18,000 ticks of 0.1 s are exactly 1,800 s and the unblock must
    // be done, while 17,999 ticks (1,799.9 s) must not be.
    @Test func anUnblockDrivenByTenthSecondTicksEndsOnTheEighteenThousandthTickAndNotBefore() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        engine.tick(0.1, times: 17_999)
        #expect(engine.state.blocked.count == 1, "1799.9 s have passed, the site must still be blocked")
        engine.tick(0.1, times: 1)
        #expect(engine.state.blocked.isEmpty, "1800.0 s have passed, the site must be unblocked")
    }

    @Test func aTickThatFinishesNothingReturnsFalseAndOnlyTheFinishingTickReturnsTrue() {
        let engine = makeEngine(blocking: ["reddit.com"])
        #expect(engine.tick(elapsed: 5) == false)
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(elapsed: 5) == false)
        #expect(engine.tick(elapsed: 100_000) == true)
        #expect(engine.tick(elapsed: 100_000) == false)
    }

    @Test func twoUnblocksRunIndependentCountdownsFromTheirOwnStartTimes() {
        let engine = makeEngine(blocking: ["a.com", "b.com", "c.com"])
        engine.send(.unblock, domain: "a.com", password: rightPassword)
        _ = engine.tick(elapsed: 600)
        engine.send(.unblock, domain: "b.com", password: rightPassword)
        #expect(engine.pendingUnblock(of: "a.com") == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
        #expect(engine.pendingUnblock(of: "b.com") == Countdown(seconds: 1800))
        #expect(engine.tick(elapsed: 1200) == true)
        #expect(engine.state.blocked.map(\.domain) == ["b.com", "c.com"])
        #expect(engine.pendingUnblock(of: "b.com") == Countdown(remainingSeconds: 600, totalSeconds: 1800))
        #expect(engine.tick(elapsed: 600) == true)
        #expect(engine.state.blocked.map(\.domain) == ["c.com"])
    }

    // 02-core-components.md § Engine, Tick rule: "advance every countdown by elapsed. Then ... remove sites whose unblock finished". Every
    // site whose unblock finished goes in that one tick, not one site per tick. Here "a.com" has 1,200 s left and "b.com" 1,800 s when the
    // tick arrives, and "c.com" has no unblock pending. The elapsed values include the exact end of the later countdown and a huge sleep.
    @Test(arguments: [1800.0, 1800.5, 5000.0, 864_000.0])
    func twoPendingUnblocksThatFinishOnOneBigTickBothLeaveBlockedAndBlockedHostsInThatTick(elapsed: Double) {
        let engine = makeEngine(blocking: ["a.com", "b.com", "c.com"])
        engine.send(.unblock, domain: "a.com", password: rightPassword)
        _ = engine.tick(elapsed: 600)
        engine.send(.unblock, domain: "b.com", password: rightPassword)
        #expect(engine.pendingUnblock(of: "a.com") == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
        #expect(engine.pendingUnblock(of: "b.com") == Countdown(seconds: 1800))
        #expect(engine.tick(elapsed: elapsed) == true)
        #expect(engine.state.blocked.map(\.domain) == ["c.com"])
        #expect(engine.blockedHosts == DomainExpander.expand("c.com"))
        #expect(engine.hostsToWrite == (DomainExpander.expand("c.com") + Engine.privateRelayHosts).sorted())
        for gone in ["a.com", "b.com"] { #expect(!engine.blockedHosts.contains(gone) && !engine.blockedHosts.contains("www.\(gone)")) }
        #expect(engine.send(.status).status?.blocked.map(\.domain) == ["c.com"])
        #expect(engine.tick(elapsed: 1) == false)
    }

    // When every blocked site has an unblock that finishes on the same tick, nothing is blocked afterwards and only the Private Relay names are written (02 § Engine, hostsToWrite: the adult content filter is always on, so the names are always written).
    @Test func everySiteWithAnUnblockThatFinishesOnOneTickLeavesNothingBlockedAndOnlyTheRelayNamesToWrite() {
        let engine = makeEngine(blocking: ["a.com", "b.com", "x.com", "twitter.com"])
        for domain in ["a.com", "b.com", "x.com", "twitter.com"] { engine.send(.unblock, domain: domain, password: rightPassword) }
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.blocked.isEmpty)
        #expect(engine.blockedHosts.isEmpty)
        #expect(engine.hostsToWrite == ["mask-h2.icloud.com", "mask.icloud.com"])
    }

    @Test func aFinishedUnblockRemovesTheSiteSoItCanBeAddedAgainFromScratch() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .notBlocked)
        expectSuccess(engine.send(.add, domain: "reddit.com"))
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
        #expect(engine.blockedHosts == DomainExpander.expand("reddit.com"))
    }

    // Hosts shared with a site that stays blocked must stay in the list; the rest must leave it.
    @Test func finishingOneSiteKeepsTheHostsThatAnotherBlockedSiteStillNeeds() {
        let engine = makeEngine(blocking: ["x.com", "twitter.com"])
        engine.send(.unblock, domain: "x.com", password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        #expect(engine.state.blocked.map(\.domain) == ["twitter.com"])
        #expect(engine.blockedHosts == DomainExpander.expand("twitter.com"))
        #expect(engine.blockedHosts.contains("api.x.com"), "twitter.com's related list still names api.x.com")
        #expect(!engine.blockedHosts.contains("old.x.com"), "only x.com itself asked for old.x.com")
    }

    @Test func aTickWithNothingRunningChangesNothingAndReturnsFalse() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let before = engine.state
        #expect(engine.tick(elapsed: 12_345) == false)
        #expect(engine.state == before)
    }

    // MARK: delay changes

    @Test func aShorterDelayAppliesOnlyAfterTheOldDelayHasPassed() {
        let engine = makeEngine()
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        #expect(engine.tick(elapsed: 1799) == false)
        #expect(engine.state.delaySeconds == 1800)
        #expect(engine.state.pendingDelayChange?.newDelaySeconds == 600)
        #expect(engine.send(.status).status?.pendingDelay == PendingDelayStatus(newDelaySeconds: 600, secondsRemaining: 1))
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.state.delaySeconds == 600)
        #expect(engine.state.pendingDelayChange == nil)
        let status = engine.send(.status).status
        #expect(status?.delaySeconds == 600)
        #expect(status?.pendingDelay == nil)
    }

    @Test func anUnblockRequestedWhileAShorterDelayWaitsStillUsesTheOldDelay() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.setDelay, password: rightPassword, seconds: 60)
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(seconds: 1800))
        _ = engine.tick(elapsed: 1800)
        #expect(engine.state.delaySeconds == 60)
        engine.send(.unblock, domain: "example.com", password: rightPassword)
        #expect(engine.pendingUnblock(of: "example.com") == Countdown(seconds: 60))
    }

    @Test func anUnblockAndADelayChangeThatFinishOnTheSameTickBothApply() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.blocked.isEmpty)
        #expect(engine.state.delaySeconds == 600)
        #expect(engine.state.pendingDelayChange == nil)
    }

    // MARK: bad elapsed values (05-testing-and-operations.md: negative, NaN and infinite elapsed values change nothing)

    @Test(arguments: [-1.0, -1800.0, -0.0, -Double.infinity, Double.infinity, Double.nan, -Double.greatestFiniteMagnitude, 0.0])
    func tickWithANegativeNotANumberOrInfiniteElapsedChangesNothingEvenWhenCountdownsAreAboutToFinish(elapsed: Double) {
        // Design change: an uninstall waits max(policy.minUninstallSeconds, delaySeconds), 172800 s under designPolicy (01-overview-and-data.md
        // § Commands, § Fixed Policy Values). This test needs the uninstall to run out together with the unblock and the delay change after
        // 1800 s, so it uses shortUninstallPolicy, where the uninstall waits the 1800 s delay as before.
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: shortUninstallPolicy)
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        engine.send(.uninstall, password: rightPassword)
        engine.send(.recoveryStart, uid: 0)
        exhaustPasswordAttempts(engine, domain: "example.com")
        // One second left on the unblock, delay change and uninstall, so any wrongly accepted value would finish them.
        _ = engine.tick(elapsed: 1799)
        var uninstallCalls = 0
        engine.onUninstall = { uninstallCalls += 1 }
        let before = engine.state
        #expect(engine.tick(elapsed: elapsed) == false)
        #expect(engine.state == before, "tick(elapsed: \(elapsed)) changed the state")
        #expect(uninstallCalls == 0)
        // And the countdowns still finish on the real, positive elapsed time.
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.state.blocked.map(\.domain) == ["example.com"])
        #expect(uninstallCalls == 1)
    }

    // A long sleep arrives as one big elapsed value; everything that is due must finish in that one tick, in the design's order.
    @Test func oneHugeTickFinishesEveryCountdownAndCallsOnUninstallOnce() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        engine.send(.uninstall, password: rightPassword)
        engine.send(.recoveryStart, uid: 0)
        exhaustPasswordAttempts(engine, domain: "example.com")
        var uninstallCalls = 0
        engine.onUninstall = { uninstallCalls += 1 }
        #expect(engine.tick(elapsed: 10 * 86_400) == true)
        #expect(engine.state.blocked.map(\.domain) == ["example.com"])
        #expect(engine.state.delaySeconds == 600)
        #expect(engine.state.pendingDelayChange == nil)
        #expect(engine.state.lockout == nil)
        #expect(engine.state.failedAttempts == 0)
        #expect(engine.state.passwordHash == nil)
        #expect(engine.state.recovery == nil)
        #expect(engine.state.uninstalling == true)
        #expect(uninstallCalls == 1)
        #expect(engine.tick(elapsed: 86_400) == false)
        #expect(uninstallCalls == 1)
    }
}

@Suite struct EngineLockoutTests {
    // 02-core-components.md § Engine, Password check rule, steps 1-4.
    @Test func fiveWrongPasswordsStartA900SecondLockoutAndResetTheCounter() {
        let engine = makeEngine(blocking: ["reddit.com"])
        for attempt in 1...4 {
            expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword)
            #expect(engine.state.failedAttempts == attempt)
            #expect(engine.state.lockout == nil)
        }
        let fifth = engine.send(.unblock, domain: "reddit.com", password: badPassword)
        expectFailure(fifth, .wrongPassword)
        #expect(engine.state.lockout == Countdown(seconds: 900))
        #expect(engine.state.failedAttempts == 0)
        #expect(engine.send(.status).status?.lockoutSecondsRemaining == 900)
    }

    @Test func duringALockoutEvenTheCorrectPasswordIsRefusedAndNothingIsCounted() {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        let right = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectFailure(right, .lockedOut)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .lockedOut)
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
        #expect(engine.state.failedAttempts == 0)
        #expect(engine.state.lockout == Countdown(seconds: 900))
    }

    @Test(arguments: [Command.unblock, .setDelay, .changePassword, .uninstall])
    func everyCommandThatTakesAPasswordIsRefusedDuringALockoutEvenWithTheRightPassword(command: Command) {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        let before = engine.state
        expectFailure(engine.send(command, domain: "reddit.com", password: rightPassword, newPassword: "brand-new-pass", seconds: 3600), .lockedOut)
        #expect(engine.state == before)
    }

    @Test func theLockedOutSentenceSaysHowManyMinutesAreLeft() {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        #expect(engine.send(.unblock, domain: "reddit.com", password: rightPassword).error?.contains("15") == true)
        _ = engine.tick(elapsed: 60)
        let later = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectFailure(later, .lockedOut)
        #expect(later.error?.contains("14") == true, "840 s left is 14 minutes: \(later.error ?? "")")
        #expect(engine.send(.status).status?.lockoutSecondsRemaining == 840)
    }

    @Test func aLockoutEndsAfterItsFullTimeAndNotOneSecondEarly() {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        #expect(engine.tick(elapsed: 899) == false)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .lockedOut)
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.state.lockout == nil)
        #expect(engine.send(.status).status?.lockoutSecondsRemaining == nil)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
    }

    @Test func afterALockoutTheCounterStartsFromZeroAgain() {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        _ = engine.tick(elapsed: 900)
        for _ in 0..<4 { expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword) }
        #expect(engine.state.lockout == nil)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword)
        #expect(engine.state.lockout == Countdown(seconds: 900))
    }

    // Four wrong, one right, four wrong is not five wrong in a row; the fifth wrong after that does lock.
    @Test func aCorrectPasswordResetsTheCounterSoFourWrongThenRightThenFourWrongDoesNotLockOut() {
        let engine = makeEngine(blocking: ["reddit.com"])
        for _ in 0..<4 { engine.send(.unblock, domain: "reddit.com", password: badPassword) }
        #expect(engine.state.failedAttempts == 4)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.state.failedAttempts == 0)
        for _ in 0..<4 { engine.send(.unblock, domain: "reddit.com", password: badPassword) }
        #expect(engine.state.lockout == nil)
        #expect(engine.state.failedAttempts == 4)
        engine.send(.unblock, domain: "reddit.com", password: badPassword)
        #expect(engine.state.lockout != nil)
    }

    @Test func wrongPasswordsOnDifferentCommandsAddUpToOneLockout() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: badPassword)
        engine.send(.unblock, domain: "reddit.com", password: badPassword)
        engine.send(.uninstall, password: badPassword)
        engine.send(.setDelay, password: badPassword, seconds: 3600)
        #expect(engine.state.failedAttempts == 4)
        #expect(engine.state.lockout == nil)
        engine.send(.changePassword, password: badPassword, newPassword: "brand-new-pass")
        #expect(engine.state.lockout == Countdown(seconds: 900))
        #expect(engine.state.passwordHash != nil)
    }

    @Test func aLockoutFinishedByTheSameTickThatCrossesItsTimeLetsTheNextCommandThrough() {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        _ = engine.tick(elapsed: 450)
        _ = engine.tick(elapsed: 450)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
    }

    // 02-core-components.md § Engine, recoveryStart: "fail notRoot unless peerUID == 0. Fail notSetUp if no password is set. Start recovery."
    // No password is checked, so the lockout, which only refuses password checks, does not stand in its way. This is the way out for
    // an owner who forgot the password and locked themselves out while guessing.
    @Test func recoveryStartFromRootDuringALockoutSucceedsAndStartsTheRecoveryCountdown() {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        let lockout = engine.state.lockout
        #expect(lockout == Countdown(seconds: 900))
        let response = engine.send(.recoveryStart, uid: 0)
        expectSuccess(response)
        #expect(engine.state.recovery == Countdown(seconds: 172_800))
        #expect(response.status?.recoverySecondsRemaining == 172_800)
        #expect(response.status?.lockoutSecondsRemaining == 900, "starting a recovery does not end the lockout")
        #expect(engine.state.lockout == lockout)
        #expect(engine.state.failedAttempts == 0)
        #expect(engine.state.passwordHash != nil)
        // The password commands are still refused while the lockout runs.
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .lockedOut)
    }

    // A caller that is not root gets notRoot during a lockout, not lockedOut: the root check comes first and there is no password check.
    @Test(arguments: [uid_t(501), uid_t(1), UInt32.max])
    func recoveryStartFromANonRootProcessDuringALockoutIsNotRootAndChangesNothing(uid: uid_t) {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        let before = engine.state
        expectFailure(engine.send(.recoveryStart, uid: uid), .notRoot)
        #expect(engine.state == before)
    }

    @Test func theLockoutRulesComeBeforeTheNoPasswordRule() {
        var state = PersistedState.fresh(delaySeconds: 1800)
        state.lockout = Countdown(seconds: 600)
        let engine = Engine(state: state, policy: designPolicy)
        expectFailure(engine.send(.uninstall, password: rightPassword), .lockedOut)
    }
}

@Suite struct EngineRecoveryTests {
    // 05-testing-and-operations.md: after finishing, recovery clears the password but keeps blocks.
    @Test func recoveryFinishesAfterFortyEightHoursClearsThePasswordAndKeepsEveryBlock() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "example.com", password: rightPassword)
        engine.send(.recoveryStart, uid: 0)
        #expect(engine.tick(elapsed: 172_799) == true, "the unblock of example.com finished during this tick")
        #expect(engine.state.passwordHash != nil)
        #expect(engine.state.recovery == Countdown(remainingSeconds: 1, totalSeconds: 172_800))
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.state.passwordHash == nil)
        #expect(engine.state.recovery == nil)
        #expect(engine.state.failedAttempts == 0)
        #expect(engine.state.lockout == nil)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
        #expect(engine.blockedHosts == DomainExpander.expand("reddit.com"))
        let status = engine.send(.status).status
        #expect(status?.passwordSet == false)
        #expect(status?.recoverySecondsRemaining == nil)
    }

    @Test func recoveryDoesNotFinishOneSecondEarly() {
        let engine = makeEngine()
        engine.send(.recoveryStart, uid: 0)
        #expect(engine.tick(elapsed: 172_799) == false)
        #expect(engine.state.passwordHash != nil)
        expectFailure(engine.send(.setup, password: "another-pass"), .alreadySetUp)
    }

    @Test func afterRecoverySetupWorksAgainAndTheOldPasswordIsGone() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 172_800)
        expectSuccess(engine.send(.setup, password: "replacement-pass"))
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .wrongPassword)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: "replacement-pass"))
    }

    @Test func withNoPasswordEveryPasswordCommandFailsWithNotSetUpAndBlocksStayBlocked() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 172_800)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .notSetUp)
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: 3600), .notSetUp)
        expectFailure(engine.send(.changePassword, password: rightPassword, newPassword: "brand-new-pass"), .notSetUp)
        expectFailure(engine.send(.uninstall, password: rightPassword), .notSetUp)
        expectFailure(engine.send(.add, domain: "newsite.org"), .notSetUp)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
        #expect(engine.state.failedAttempts == 0)
    }

    // The design: a finished recovery sets failedAttempts = 0 and lockout = nil, even when the lockout was started
    // after the recovery began and still has time left.
    @Test func recoveryFinishingClearsARunningLockoutAndTheFailedAttemptCounter() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 172_700)
        exhaustPasswordAttempts(engine)
        #expect(engine.state.lockout == Countdown(seconds: 900))
        _ = engine.tick(elapsed: 100)
        #expect(engine.state.passwordHash == nil)
        #expect(engine.state.lockout == nil)
        #expect(engine.state.failedAttempts == 0)

        let counting = makeEngine(blocking: ["reddit.com"])
        counting.send(.recoveryStart, uid: 0)
        for _ in 0..<3 { counting.send(.unblock, domain: "reddit.com", password: badPassword) }
        #expect(counting.state.failedAttempts == 3)
        _ = counting.tick(elapsed: 172_800)
        #expect(counting.state.failedAttempts == 0)
    }

    @Test func aCancelledRecoveryNeverClearsThePasswordNoMatterHowMuchTimePasses() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 100_000)
        expectSuccess(engine.send(.recoveryCancel))
        #expect(engine.tick(elapsed: 1_000_000) == false)
        #expect(engine.state.passwordHash != nil)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
    }

    @Test func recoveryStartedAgainAfterACancelStartsAFreshFortyEightHours() {
        let engine = makeEngine()
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 100_000)
        engine.send(.recoveryCancel)
        engine.send(.recoveryStart, uid: 0)
        #expect(engine.state.recovery == Countdown(seconds: 172_800))
    }
}

// Design change: an uninstall waits max(policy.minUninstallSeconds, delaySeconds) (01-overview-and-data.md § Commands, § Fixed Policy Values;
// 02-core-components.md § Engine). The tests in this suite are about how an uninstall countdown ends (once, flag first, never after a
// cancel), not about how long it is, and they tick through the 1800 s of the default delay, so they run under shortUninstallPolicy. The
// 172800 s length itself is pinned in EngineUninstallWaitTests and EngineHalfSecondBoundaryTests.
@Suite struct EngineUninstallTimeTests {
    @Test func theUninstallCountdownFinishesOnTheFullDelayCallsOnUninstallOnceAndSetsUninstalling() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        engine.send(.uninstall, password: rightPassword)
        #expect(engine.tick(elapsed: 1799) == false)
        #expect(calls == 0)
        #expect(engine.state.uninstalling == false)
        #expect(engine.tick(elapsed: 1) == true)
        #expect(calls == 1)
        #expect(engine.state.uninstalling == true)
    }

    // 05-testing-and-operations.md: uninstall calls onUninstall exactly once, however many ticks follow.
    @Test func onUninstallIsNotCalledAgainByLaterTicks() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        #expect(engine.tick(2.0, times: 500) == 0)
        _ = engine.tick(elapsed: 1_000_000)
        #expect(calls == 1)
        #expect(engine.state.uninstalling == true)
    }

    // The design sets uninstalling = true and then calls onUninstall, so the callback already sees the flag.
    @Test func onUninstallSeesUninstallingAlreadySet() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        var seen: Bool?
        engine.onUninstall = { [unowned engine] in seen = engine.state.uninstalling }
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        #expect(seen == true)
    }

    // Under the 48 hour minimum the 101000 s of ticking below is not enough to finish an uninstall, so this test would pass even with a
    // cancel that did nothing. The short policy makes the countdown 1800 s, so a surviving countdown would be finished by those ticks.
    @Test func aCancelledUninstallNeverCallsOnUninstall() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 1000)
        expectSuccess(engine.send(.cancelUninstall))
        #expect(engine.tick(elapsed: 100_000) == false)
        #expect(calls == 0)
        #expect(engine.state.uninstalling == false)
    }

    @Test func finishingAnUninstallWithNoCallbackSetDoesNotCrash() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        engine.send(.uninstall, password: rightPassword)
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.uninstalling == true)
    }

    @Test func theUninstallCountdownUsesTheDelayThatWasInEffectWhenItWasRequested() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        engine.send(.setDelay, password: rightPassword, seconds: 7200)
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 7199)
        #expect(calls == 0)
        _ = engine.tick(elapsed: 1)
        #expect(calls == 1)
    }
}

@Suite struct EngineSnapshotAndPersistenceTests {
    // Every countdown shown to clients is rounded up so a running countdown never shows 0.
    // Design change: under designPolicy the uninstall countdown would be 172800 s, the same as the recovery countdown, so a snapshot that
    // swapped the two fields could not be told apart. shortUninstallPolicy keeps the uninstall at 1800 s, a figure no other countdown here has.
    @Test func theSnapshotShowsEveryRunningCountdownRoundedUp() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: shortUninstallPolicy)
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        engine.send(.uninstall, password: rightPassword)
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 0.25)
        var status = engine.snapshot(hostsFileHealthy: true)
        #expect(status.blocked.map(\.domain) == ["reddit.com", "example.com"])
        #expect(status.blocked.first?.unblockSecondsRemaining == 1800)
        #expect(status.blocked.dropFirst().first?.unblockSecondsRemaining == nil)
        #expect(status.blocked.count == 2)
        #expect(status.pendingDelay == PendingDelayStatus(newDelaySeconds: 600, secondsRemaining: 1800))
        #expect(status.uninstallSecondsRemaining == 1800)
        #expect(status.recoverySecondsRemaining == 172_800)
        #expect(status.lockoutSecondsRemaining == nil)
        _ = engine.tick(elapsed: 0.75)
        status = engine.snapshot(hostsFileHealthy: false)
        #expect(status.blocked.first?.unblockSecondsRemaining == 1799)
        #expect(status.pendingDelay?.secondsRemaining == 1799)
        #expect(status.uninstallSecondsRemaining == 1799)
        #expect(status.recoverySecondsRemaining == 172_799)
        #expect(status.hostsFileHealthy == false)
        #expect(status.passwordSet == true)
        #expect(status.delaySeconds == 1800)
        exhaustPasswordAttempts(engine, domain: "example.com")
        _ = engine.tick(elapsed: 0.5)
        #expect(engine.snapshot(hostsFileHealthy: true).lockoutSecondsRemaining == 900)
        _ = engine.tick(elapsed: 0.5)
        #expect(engine.snapshot(hostsFileHealthy: true).lockoutSecondsRemaining == 899)
    }

    @Test func everySuccessfulCommandCarriesTheSameSnapshotTheEngineWouldReport() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let response = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(response.status == engine.snapshot(hostsFileHealthy: response.status?.hostsFileHealthy ?? true))
    }

    private static func fullState() -> PersistedState {
        let hash = PasswordHash(algorithm: "pbkdf2-sha256", iterations: 210_000, salt: "c2FsdHNhbHRzYWx0c2FsdA==", hash: "aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g=")
        let reddit = BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], pendingUnblock: Countdown(remainingSeconds: 123.456, totalSeconds: 1800))
        let example = BlockedSite(domain: "example.com", hosts: ["example.com", "www.example.com"])
        return PersistedState(version: 1, passwordHash: hash, blocked: [reddit, example], delaySeconds: 1800, pendingDelayChange: PendingDelayChange(newDelaySeconds: 600, countdown: Countdown(remainingSeconds: 0.1 + 0.2, totalSeconds: 1800)), pendingUninstall: Countdown(remainingSeconds: 42, totalSeconds: 1800), recovery: Countdown(seconds: 172_800), failedAttempts: 3, lockout: Countdown(remainingSeconds: 12.5, totalSeconds: 900), uninstalling: true)
    }

    // 05-testing-and-operations.md: JSON round-trip of the full state.
    @Test func theFullStateSurvivesAJSONRoundTripExactly() throws {
        let state = Self.fullState()
        let data = try JSONCoding.encoder.encode(state)
        let decoded = try JSONCoding.decoder.decode(PersistedState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.pendingDelayChange?.countdown.remainingSeconds == 0.1 + 0.2, "a countdown must come back bit for bit")
        #expect(decoded.blocked.first?.pendingUnblock?.remainingSeconds == 123.456)
    }

    // 01-overview-and-data.md § Data Model: the stored field names are exactly the ones in the design.
    @Test func theStoredJSONUsesExactlyTheFieldNamesFromTheDesign() throws {
        let data = try JSONCoding.encoder.encode(Self.fullState())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "passwordHash", "blocked", "delaySeconds", "pendingDelayChange", "pendingUninstall", "recovery", "failedAttempts", "lockout", "uninstalling"])
        #expect(Set((object["passwordHash"] as? [String: Any])?.keys.map { $0 } ?? []) == ["algorithm", "iterations", "salt", "hash"])
        let sites = try #require(object["blocked"] as? [[String: Any]])
        let site = try #require(sites.first)
        #expect(Set(site.keys) == ["domain", "hosts", "pendingUnblock"])
        #expect(Set((site["pendingUnblock"] as? [String: Any])?.keys.map { $0 } ?? []) == ["remainingSeconds", "totalSeconds"])
        #expect(Set((object["pendingDelayChange"] as? [String: Any])?.keys.map { $0 } ?? []) == ["newDelaySeconds", "countdown"])
        #expect(Set((object["recovery"] as? [String: Any])?.keys.map { $0 } ?? []) == ["remainingSeconds", "totalSeconds"])
        #expect(object["version"] as? Int == 1)
        #expect(object["delaySeconds"] as? Int == 1800)
        #expect(object["uninstalling"] as? Bool == true)
    }

    @Test func aFreshStateHasTheDesignsDefaults() {
        let state = PersistedState.fresh()
        #expect(state.version == 1)
        #expect(state.passwordHash == nil)
        #expect(state.blocked.isEmpty)
        #expect(state.delaySeconds == 1800)
        #expect(state.pendingDelayChange == nil && state.pendingUninstall == nil && state.recovery == nil && state.lockout == nil)
        #expect(state.failedAttempts == 0)
        #expect(state.uninstalling == false)
    }

    // The daemon saves and reloads state across restarts: the password must still verify and a running countdown must continue.
    @Test func anEngineRebuiltFromSavedStateKeepsThePasswordAndContinuesTheCountdown() throws {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        _ = engine.tick(elapsed: 600)
        let data = try JSONCoding.encoder.encode(engine.state)
        let restored = Engine(state: try JSONCoding.decoder.decode(PersistedState.self, from: data), policy: designPolicy)
        #expect(restored.state == engine.state)
        #expect(restored.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
        expectFailure(restored.send(.unblock, domain: "example.com", password: badPassword), .wrongPassword)
        expectSuccess(restored.send(.unblock, domain: "example.com", password: rightPassword))
        #expect(restored.tick(elapsed: 1199) == false)
        #expect(restored.state.blocked.map(\.domain) == ["reddit.com", "example.com"])
        #expect(restored.tick(elapsed: 1) == true)
        #expect(restored.state.blocked.map(\.domain) == ["example.com"])
    }
}

// The Countdown tolerance seen through the Engine. 02-core-components.md § Models and Protocol Types (Countdown.advance): a remainder
// below 1e-9 seconds is set to exactly 0, and a remainder of 1e-6 seconds is still running.
@Suite struct EngineCountdownToleranceTests {
    @Test func anUnblockWithAboutAMicrosecondLeftIsStillRunning() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(elapsed: 1799.999999) == false)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
        let left = engine.pendingUnblock(of: "reddit.com")?.remainingSeconds ?? 0
        #expect(left > 9e-7 && left < 1.1e-6, "about 1e-6 s should be left, got \(left)")
        #expect(engine.send(.status).status?.blocked.first?.unblockSecondsRemaining == 1, "a running countdown never shows 0")
        // The last microsecond finishes it, which also proves the earlier tick did not finish it by accident.
        #expect(engine.tick(elapsed: 0.000001) == true)
        #expect(engine.state.blocked.isEmpty)
    }

    @Test func anUnblockWithAboutTenPicosecondsLeftCountsAsFinished() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.tick(elapsed: 1799.9999999999) == true)
        #expect(engine.state.blocked.isEmpty)
        #expect(engine.blockedHosts.isEmpty)
    }

    // The same two remainders for a countdown that is not an unblock: a recovery with a microsecond left has not cleared the password,
    // and one with ten picoseconds left has.
    @Test(arguments: [(172_799.999999, false), (172_799.9999999999, true)])
    func aRecoveryClearsThePasswordOnlyWhenTheRemainderIsBelowOneNanosecond(elapsed: Double, finished: Bool) {
        let engine = makeEngine()
        engine.send(.recoveryStart, uid: 0)
        #expect(engine.tick(elapsed: elapsed) == finished)
        #expect((engine.state.passwordHash == nil) == finished)
        #expect((engine.state.recovery == nil) == finished)
    }
}

// Every countdown in the design runs for a whole number of seconds, so half a second before the end it must still be running and
// half a second later it must be finished. A boundary that is off by one tick would show up here, and not in the whole-second tests.
enum HalfSecondCountdown: CaseIterable, Sendable, CustomTestStringConvertible {
    case lockout, delayChange, uninstall, recovery, unblock

    // The name shown in the test report.
    var testDescription: String {
        switch self {
        case .lockout: return "lockout"
        case .delayChange: return "delay change"
        case .uninstall: return "uninstall"
        case .recovery: return "recovery"
        case .unblock: return "unblock"
        }
    }
}

@Suite struct EngineHalfSecondBoundaryTests {
    @Test(arguments: HalfSecondCountdown.allCases)
    func aCountdownIsStillRunningHalfASecondBeforeItsEndAndFinishedHalfASecondLater(kind: HalfSecondCountdown) {
        let engine = makeEngine(blocking: ["reddit.com"])
        var uninstallCalls = 0
        engine.onUninstall = { uninstallCalls += 1 }
        let total: Double
        switch kind {
        case .lockout:
            exhaustPasswordAttempts(engine)
            total = 900
        case .delayChange:
            expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 600))
            total = 1800
        case .uninstall:
            expectSuccess(engine.send(.uninstall, password: rightPassword))
            // Design change: with the 30 minute default delay under designPolicy the uninstall waits the 48 hour minimum, 172800 s
            // (01-overview-and-data.md § Fixed Policy Values), not the 1800 s delay.
            total = 172_800
        case .recovery:
            expectSuccess(engine.send(.recoveryStart, uid: 0))
            total = 172_800
        case .unblock:
            expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
            total = 1800
        }

        // Half a second left: nothing has finished, the tick reports nothing to save, and the status still shows one second.
        #expect(engine.tick(elapsed: total - 0.5) == false)
        let running = engine.send(.status).status
        switch kind {
        case .lockout:
            // The correct password is still refused while any lockout time is left.
            expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .lockedOut)
            #expect(engine.state.lockout != nil)
            #expect(running?.lockoutSecondsRemaining == 1)
        case .delayChange:
            #expect(engine.state.delaySeconds == 1800)
            #expect(engine.state.pendingDelayChange?.newDelaySeconds == 600)
            #expect(running?.pendingDelay == PendingDelayStatus(newDelaySeconds: 600, secondsRemaining: 1))
        case .uninstall:
            #expect(engine.state.uninstalling == false)
            #expect(uninstallCalls == 0)
            #expect(running?.uninstallSecondsRemaining == 1)
        case .recovery:
            #expect(engine.state.passwordHash != nil)
            #expect(engine.state.recovery != nil)
            #expect(running?.recoverySecondsRemaining == 1)
        case .unblock:
            #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
            #expect(engine.blockedHosts.contains("reddit.com"))
            #expect(running?.blocked.first?.unblockSecondsRemaining == 1)
        }

        // The last half second finishes it and the tick reports a change to save.
        #expect(engine.tick(elapsed: 0.5) == true)
        let finished = engine.send(.status).status
        switch kind {
        case .lockout:
            #expect(engine.state.lockout == nil)
            #expect(finished?.lockoutSecondsRemaining == nil)
            expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        case .delayChange:
            #expect(engine.state.delaySeconds == 600)
            #expect(engine.state.pendingDelayChange == nil)
            #expect(finished?.delaySeconds == 600)
        case .uninstall:
            #expect(engine.state.uninstalling == true)
            #expect(uninstallCalls == 1)
        case .recovery:
            #expect(engine.state.passwordHash == nil)
            #expect(engine.state.recovery == nil)
            #expect(finished?.passwordSet == false)
        case .unblock:
            #expect(engine.state.blocked.isEmpty)
            #expect(engine.blockedHosts.isEmpty)
        }
    }
}

// 02-core-components.md § Engine, "Lockout wording": the lockout message gives the remaining time in whole minutes rounded up, so 59.5
// seconds left reads "1 minute" and the message never says "0 minutes". And "The wrong-password message says '1 try left' in the singular."
@Suite struct EngineWordingTests {
    // Every "<number> minute(s)" or "<number> try/tries" in the text, written as "N word", so the figure and its unit are judged together.
    private func figures(in text: String, units: Set<String>) -> [String] {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var found: [String] = []
        for (index, word) in words.enumerated() where index > 0 && units.contains(word) {
            if let number = Int(words[index - 1]) { found.append("\(number) \(word)") }
        }
        return found
    }

    // The lockout starts at 900 s; ticking 900 minus the wanted figure leaves exactly that many seconds (all values are binary-exact).
    @Test(arguments: [(900.0, "15 minutes"), (840.0, "14 minutes"), (839.5, "14 minutes"), (780.5, "14 minutes"), (780.0, "13 minutes"), (121.0, "3 minutes"), (120.0, "2 minutes"), (61.0, "2 minutes"), (60.5, "2 minutes"), (60.0, "1 minute"), (59.5, "1 minute")])
    func theLockoutMessageRoundsTheRemainingTimeUpToWholeMinutes(remaining: Double, expected: String) {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        _ = engine.tick(elapsed: 900 - remaining)
        let response = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectFailure(response, .lockedOut)
        #expect(figures(in: response.error ?? "", units: ["minute", "minutes"]) == [expected], "message was \(response.error ?? "nil")")
        #expect(!(response.error ?? "").contains("0 minutes"))
    }

    // Under one minute the design allows seconds, so only the two firm rules are checked: never "0 minutes", and the lockout still holds.
    @Test(arguments: [59.0, 30.0, 1.5, 1.0, 0.5])
    func aLockoutMessageWithUnderAMinuteLeftNeverSaysZeroMinutes(remaining: Double) {
        let engine = makeEngine(blocking: ["reddit.com"])
        exhaustPasswordAttempts(engine)
        _ = engine.tick(elapsed: 900 - remaining)
        let response = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectFailure(response, .lockedOut)
        #expect(!(response.error ?? "").contains("0 minutes"), "message was \(response.error ?? "nil")")
    }

    @Test func theWrongPasswordMessageSaysOneTryLeftInTheSingularAndOtherCountsInThePlural() {
        let engine = makeEngine(blocking: ["reddit.com"])
        var messages: [String] = []
        for _ in 0..<4 {
            let response = engine.send(.unblock, domain: "reddit.com", password: badPassword)
            expectFailure(response, .wrongPassword)
            messages.append(response.error ?? "")
        }
        let expected = ["4 tries", "3 tries", "2 tries", "1 try"]
        for (message, figure) in zip(messages, expected) { #expect(figures(in: message, units: ["try", "tries"]) == [figure], "message was \(message)") }
        #expect(messages[3].contains("1 try left"))
        #expect(!messages[3].contains("1 tries"))
    }
}

@Suite struct EngineFinishedStateTests {
    // 02-core-components.md § Engine, "Finished-but-uncleared lockout": a lockout whose countdown reached 0 but which the next tick has
    // not cleared yet does not block a password check. The check clears it and proceeds.
    private func engineWithAFinishedUncleredLockout() -> Engine {
        var state = makeEngine(blocking: ["reddit.com"]).state
        state.lockout = Countdown(remainingSeconds: 0, totalSeconds: 900)
        state.failedAttempts = 3
        return Engine(state: state, policy: designPolicy)
    }

    @Test(arguments: [Command.unblock, .setDelay, .changePassword, .uninstall])
    func aStoredLockoutAtZeroSecondsDoesNotStopACommandWithTheRightPassword(command: Command) {
        let engine = engineWithAFinishedUncleredLockout()
        let response = engine.send(command, domain: "reddit.com", password: rightPassword, newPassword: "brand-new-pass", seconds: 3600)
        expectSuccess(response)
        #expect(engine.state.lockout == nil, "the check must clear the finished lockout")
        #expect(engine.state.failedAttempts == 0, "a right password resets the counter")
    }

    // The check proceeds for a wrong password too: it is judged and counted like any other wrong password, not refused as locked out.
    @Test func aStoredLockoutAtZeroSecondsLetsAWrongPasswordBeCountedInsteadOfRefusedAsLockedOut() {
        let engine = engineWithAFinishedUncleredLockout()
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword)
        #expect(engine.state.lockout == nil)
        #expect(engine.state.failedAttempts == 4)
    }

    // 02-core-components.md § Engine, cancelUninstall: "also fails nothingPending once the uninstall countdown has finished and
    // uninstalling is true, because removal has already begun."
    // Design change: an uninstall waits max(policy.minUninstallSeconds, delaySeconds), so this test ticks 1800 s under shortUninstallPolicy
    // to finish it (under designPolicy the countdown is 172800 s and 1800 s would leave it running).
    @Test func cancelUninstallAfterTheUninstallCountdownFinishedFailsWithNothingPendingAndChangesNothing() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        engine.send(.uninstall, password: rightPassword)
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.uninstalling == true)
        let before = engine.state
        expectFailure(engine.send(.cancelUninstall), .nothingPending)
        #expect(engine.state == before, "removal has begun, so the cancel must not undo it")
    }

    // Same design change. Under designPolicy the 1799.5 s of ticking would leave 171000 s on the countdown, so the test would no longer be
    // "just before the end"; shortUninstallPolicy puts the end at 1800 s again.
    @Test func cancelUninstallJustBeforeTheCountdownFinishesStillCancels() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 1799.5)
        expectSuccess(engine.send(.cancelUninstall))
        #expect(engine.tick(elapsed: 100) == false)
        #expect(calls == 0 && engine.state.uninstalling == false)
    }
}

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

    // Tenths of a second are not exact in binary floating point, so 18,000 of them can leave a residue of about 1e-12.
    // The design measures elapsed real time, so 18,000 ticks of 0.1 s are exactly 1,800 s and the unblock must be done,
    // while 17,999 ticks (1,799.9 s) must not be.
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
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
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

@Suite struct EngineUninstallTimeTests {
    @Test func theUninstallCountdownFinishesOnTheFullDelayCallsOnUninstallOnceAndSetsUninstalling() {
        let engine = makeEngine()
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
        let engine = makeEngine()
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
        let engine = makeEngine()
        var seen: Bool?
        engine.onUninstall = { [unowned engine] in seen = engine.state.uninstalling }
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 1800)
        #expect(seen == true)
    }

    @Test func aCancelledUninstallNeverCallsOnUninstall() {
        let engine = makeEngine()
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
        let engine = makeEngine()
        engine.send(.uninstall, password: rightPassword)
        #expect(engine.tick(elapsed: 1800) == true)
        #expect(engine.state.uninstalling == true)
    }

    @Test func theUninstallCountdownUsesTheDelayThatWasInEffectWhenItWasRequested() {
        let engine = makeEngine()
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
    @Test func theSnapshotShowsEveryRunningCountdownRoundedUp() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
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

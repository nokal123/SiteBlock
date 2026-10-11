import Foundation
import Testing
import SiteBlockCore

// Command rules for the Engine. Expected values come from Design Plans/02-core-components.md § Engine ("Password check rule",
// "Command rules"), 01-overview-and-data.md § Commands and § Fixed Policy Values, and 05-testing-and-operations.md § Unit Tests.
// Tests that need the passage of time are in EngineTimeTests.swift.

@Suite struct EngineStatusAndSetupTests {
    @Test func statusOnAFreshEngineShowsNoPasswordNothingBlockedAndTheDefaultDelay() {
        let engine = makeEngine(password: nil)
        let response = engine.send(.status)
        expectSuccess(response)
        let status = response.status
        #expect(status?.passwordSet == false)
        #expect(status?.blocked.isEmpty == true)
        #expect(status?.delaySeconds == 1800)
        #expect(status?.pendingDelay == nil)
        #expect(status?.uninstallSecondsRemaining == nil)
        #expect(status?.recoverySecondsRemaining == nil)
        #expect(status?.lockoutSecondsRemaining == nil)
        let version = status?.version ?? ""
        #expect(!version.isEmpty)
    }

    @Test func snapshotCarriesTheHostsFileHealthFlagItIsGiven() {
        let engine = makeEngine()
        #expect(engine.snapshot(hostsFileHealthy: true).hostsFileHealthy == true)
        #expect(engine.snapshot(hostsFileHealthy: false).hostsFileHealthy == false)
    }

    @Test func setupWithAValidPasswordSucceedsAndSetsAPbkdf2HashAtThePolicyIterations() {
        let engine = makeEngine(password: nil)
        let response = engine.send(.setup, password: rightPassword)
        expectSuccess(response)
        #expect(response.status?.passwordSet == true)
        #expect(engine.state.passwordHash?.algorithm == "pbkdf2-sha256")
        #expect(engine.state.passwordHash?.iterations == designPolicy.pbkdf2Iterations)
        #expect(engine.state.failedAttempts == 0)
    }

    // state.json holds only a hash; the plaintext must never appear in anything that gets saved.
    @Test func setupStoresOnlyAHashAndNeverThePlaintextPassword() throws {
        let engine = makeEngine(password: nil)
        engine.send(.setup, password: "plaintext-canary-77")
        let json = String(decoding: try JSONCoding.encoder.encode(engine.state), as: UTF8.self)
        #expect(!json.contains("plaintext-canary-77"))
        #expect(json.contains("pbkdf2-sha256"))
    }

    @Test func setupWhenAPasswordExistsFailsWithAlreadySetUpAndKeepsTheFirstPassword() {
        let engine = makeEngine()
        let hashBefore = engine.state.passwordHash
        expectFailure(engine.send(.setup, password: "second-password"), .alreadySetUp)
        #expect(engine.state.passwordHash == hashBefore)
        engine.send(.add, domain: "reddit.com")
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: "second-password"), .wrongPassword)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
    }

    @Test(arguments: ["", "a", "abcde", "     ", "      ", String(repeating: " ", count: 30)])
    func setupRejectsWeakPasswordsAndLeavesNoPasswordSet(password: String) {
        let engine = makeEngine(password: nil)
        expectFailure(engine.send(.setup, password: password), .weakPassword)
        #expect(engine.state.passwordHash == nil)
        #expect(engine.send(.status).status?.passwordSet == false)
    }

    @Test func setupAcceptsASixCharacterPasswordAndRejectsFiveCharactersOfMultiByteText() {
        let accepted = makeEngine(password: nil)
        expectSuccess(accepted.send(.setup, password: "abcdef"))
        let rejected = makeEngine(password: nil)
        expectFailure(rejected.send(.setup, password: "\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}"), .weakPassword)
    }

    @Test func setupWithoutAPasswordArgumentIsABadRequest() {
        let engine = makeEngine(password: nil)
        expectFailure(engine.send(.setup), .badRequest)
        #expect(engine.state.passwordHash == nil)
    }
}

@Suite struct EngineAddTests {
    @Test func addBlocksTheNormalizedSiteWithItsExpandedHosts() throws {
        let engine = makeEngine()
        let response = engine.send(.add, domain: "https://WWW.Reddit.com/r/swift?x=1")
        expectSuccess(response)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
        let site = try #require(engine.state.blocked.first, "the add did not block anything")
        let hosts = site.hosts
        #expect(hosts == DomainExpander.expand("reddit.com"))
        #expect(hosts.contains("redd.it") && hosts.contains("i.redd.it") && hosts.contains("www.reddit.com"))
        #expect(engine.blockedHosts == hosts)
        #expect(response.status?.blocked.map(\.domain) == ["reddit.com"])
        #expect(response.status?.blocked.first?.hosts == hosts)
        #expect(response.status?.blocked.first?.unblockSecondsRemaining == nil)
        #expect(site.pendingUnblock == nil)
    }

    // 01-overview-and-data.md § Commands: add needs a password to be set up first, so every block can later be undone.
    @Test func addBeforeAPasswordExistsFailsWithNotSetUpAndBlocksNothing() {
        let engine = makeEngine(password: nil)
        expectFailure(engine.send(.add, domain: "reddit.com"), .notSetUp)
        #expect(engine.state.blocked.isEmpty)
        #expect(engine.blockedHosts.isEmpty)
    }

    @Test(arguments: [("1.2.3.4", DomainError.ipAddress), ("", DomainError.empty), ("my_site.com", DomainError.invalidCharacters), ("reddit", DomainError.needsDot), ("printer.local", DomainError.reserved)])
    func addRejectsAnInvalidDomainWithInvalidDomainAndTheNormalizersSentence(input: String, error: DomainError) {
        let engine = makeEngine()
        let response = engine.send(.add, domain: input)
        expectFailure(response, .invalidDomain)
        #expect(response.error == error.errorDescription)
        #expect(engine.state.blocked.isEmpty)
    }

    @Test func addRejectsAnEnormousInputWithoutTroubleAndBlocksNothing() {
        let engine = makeEngine()
        expectFailure(engine.send(.add, domain: String(repeating: "a", count: 200_000) + ".com"), .invalidDomain)
        expectFailure(engine.send(.add, domain: String(repeating: "\u{FC}", count: 100_000) + ".com"), .invalidDomain)
        #expect(engine.state.blocked.isEmpty)
    }

    @Test func addStoresUnicodeNamesAsPunycode() {
        let engine = makeEngine()
        expectSuccess(engine.send(.add, domain: "b\u{FC}cher.de"))
        #expect(engine.state.blocked.map(\.domain) == ["xn--bcher-kva.de"])
        #expect(engine.blockedHosts.contains("www.xn--bcher-kva.de"))
    }

    @Test func addOfASiteThatIsAlreadyBlockedFailsWithAlreadyBlockedEvenWhenWrittenDifferently() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.add, domain: "reddit.com"), .alreadyBlocked)
        expectFailure(engine.send(.add, domain: "www.reddit.com"), .alreadyBlocked)
        expectFailure(engine.send(.add, domain: "HTTPS://REDDIT.COM/x"), .alreadyBlocked)
        #expect(engine.state.blocked.count == 1)
    }

    // 02-core-components.md § Engine, add: clears the pending unblock and says exactly this sentence.
    @Test func addOfASiteWithAPendingUnblockCancelsTheUnblockAndStaysBlocked() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.pendingUnblock(of: "reddit.com") != nil)
        let response = engine.send(.add, domain: "reddit.com")
        expectSuccess(response)
        #expect(response.message == "Unblock cancelled; reddit.com stays blocked.")
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
        #expect(response.status?.blocked.first?.unblockSecondsRemaining == nil)
        #expect(engine.state.blocked.count == 1)
        #expect(engine.tick(elapsed: 100_000) == false)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    @Test func addKeepsSitesInTheOrderTheyWereAdded() {
        let engine = makeEngine(blocking: ["zebra.com", "apple.com", "mango.org", "banana.net"])
        #expect(engine.state.blocked.map(\.domain) == ["zebra.com", "apple.com", "mango.org", "banana.net"])
        #expect(engine.send(.status).status?.blocked.map(\.domain) == ["zebra.com", "apple.com", "mango.org", "banana.net"])
    }

    // x.com and twitter.com share their related names, so the combined list must hold each host once, in sorted order.
    @Test func blockedHostsIsTheSortedUnionWithNoDuplicatesAcrossSites() {
        let engine = makeEngine(blocking: ["x.com", "twitter.com", "reddit.com"])
        let union = Set(DomainExpander.expand("x.com")).union(DomainExpander.expand("twitter.com")).union(DomainExpander.expand("reddit.com"))
        #expect(engine.blockedHosts == union.sorted())
        #expect(Set(engine.blockedHosts).count == engine.blockedHosts.count)
        #expect(engine.blockedHosts.count < DomainExpander.expand("x.com").count + DomainExpander.expand("twitter.com").count + DomainExpander.expand("reddit.com").count)
        #expect(engine.blockedHosts.contains("api.twitter.com") && engine.blockedHosts.contains("api.x.com"))
    }

    @Test func blockedHostsOfAnEmptyEngineIsEmpty() {
        #expect(makeEngine().blockedHosts.isEmpty)
    }

    @Test func addWithoutADomainIsABadRequest() {
        let engine = makeEngine()
        expectFailure(engine.send(.add), .badRequest)
        #expect(engine.state.blocked.isEmpty)
    }
}

@Suite struct EngineUnblockTests {
    @Test func unblockWithTheRightPasswordStartsACountdownOfTheFullDelay() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let response = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectSuccess(response)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(seconds: 1800))
        #expect(response.status?.blocked.first?.unblockSecondsRemaining == 1800)
        // The site stays blocked while it waits.
        #expect(engine.blockedHosts == DomainExpander.expand("reddit.com"))
        // 01-overview-and-data.md gives "reddit.com will unblock in 30 minutes." as an example of the message, not as the
        // whole text, so the check is that the message starts with that sentence (an equality check was too strict).
        #expect(response.message?.hasPrefix("reddit.com will unblock in 30 minutes.") == true, "message was \(response.message ?? "nil")")
    }

    @Test func unblockNormalizesTheDomainTheSameWayAddDoes() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.unblock, domain: "WWW.Reddit.COM/r/swift", password: rightPassword))
        #expect(engine.pendingUnblock(of: "reddit.com") != nil)
    }

    @Test func unblockOfASiteThatIsNotBlockedFailsWithNotBlocked() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.unblock, domain: "example.com", password: rightPassword), .notBlocked)
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
    }

    // The design checks the site before the password, so asking about an unknown site with a wrong password is not a wrong guess.
    @Test func unblockOfAnUnknownSiteWithAWrongPasswordIsNotBlockedAndDoesNotCountAsAFailedAttempt() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.unblock, domain: "example.com", password: badPassword), .notBlocked)
        #expect(engine.state.failedAttempts == 0)
    }

    @Test func unblockWithAnInvalidDomainFailsWithInvalidDomainAndDoesNotCountAsAFailedAttempt() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.unblock, domain: "1.2.3.4", password: badPassword), .invalidDomain)
        #expect(engine.state.failedAttempts == 0)
    }

    @Test func unblockWithAWrongPasswordFailsCountsOneAttemptAndSaysHowManyTriesAreLeft() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let response = engine.send(.unblock, domain: "reddit.com", password: badPassword)
        expectFailure(response, .wrongPassword)
        #expect(engine.state.failedAttempts == 1)
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
        #expect(response.error?.contains("4") == true, "should say 4 tries are left: \(response.error ?? "")")
        let fourth = (0..<2).map { _ in engine.send(.unblock, domain: "reddit.com", password: badPassword) }.last
        #expect(fourth?.error?.contains("2") == true, "after 3 wrong passwords 2 tries are left: \(fourth?.error ?? "")")
    }

    @Test func unblockWithARightPasswordResetsTheFailedAttemptCounter() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        for _ in 0..<3 { engine.send(.unblock, domain: "reddit.com", password: badPassword) }
        #expect(engine.state.failedAttempts == 3)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.state.failedAttempts == 0)
    }

    @Test func unblockWithoutADomainOrWithoutAPasswordIsABadRequest() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.unblock, password: rightPassword), .badRequest)
        expectFailure(engine.send(.unblock, domain: "reddit.com"), .badRequest)
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
    }

    @Test func unblockUsesTheDelayThatIsInEffectWhenItIsRequested() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 3600))
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(seconds: 3600))
    }

    // 05-testing-and-operations.md: a second unblock does not restart the countdown.
    @Test func aSecondUnblockKeepsTheRunningCountdownAndReportsItsRemainingTime() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        _ = engine.tick(elapsed: 600)
        let second = engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectSuccess(second)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
        #expect(second.status?.blocked.first?.unblockSecondsRemaining == 1200)
        #expect(second.message?.contains("20 minutes") == true, "should report the remaining time: \(second.message ?? "")")
    }

    @Test func aSecondUnblockStillNeedsTheRightPasswordAndDoesNotChangeTheCountdown() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        _ = engine.tick(elapsed: 600)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
    }

    @Test func cancelUnblockStopsThePendingUnblockWithoutAPassword() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        let response = engine.send(.cancelUnblock, domain: "reddit.com")
        expectSuccess(response)
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
        #expect(response.status?.blocked.first?.unblockSecondsRemaining == nil)
        #expect(engine.tick(elapsed: 100_000) == false)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    @Test func cancelUnblockWithNothingPendingFailsWithNothingPending() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.cancelUnblock, domain: "reddit.com"), .nothingPending)
    }

    @Test func cancelUnblockForAnUnknownSiteFailsWithNotBlocked() {
        expectFailure(makeEngine(blocking: ["reddit.com"]).send(.cancelUnblock, domain: "example.com"), .notBlocked)
    }

    @Test func cancelUnblockWithAnInvalidOrMissingDomainFails() {
        let engine = makeEngine(blocking: ["reddit.com"])
        expectFailure(engine.send(.cancelUnblock, domain: "1.2.3.4"), .invalidDomain)
        expectFailure(engine.send(.cancelUnblock), .badRequest)
    }

    @Test func cancelUnblockNormalizesTheDomain() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        expectSuccess(engine.send(.cancelUnblock, domain: "https://www.reddit.com/"))
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
    }

    @Test func anUnblockAfterACancelStartsAFreshFullCountdown() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        _ = engine.tick(elapsed: 1000)
        engine.send(.cancelUnblock, domain: "reddit.com")
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(seconds: 1800))
    }

    // 02-core-components.md § Engine, cancel commands: "clear their countdown". Only the named site's. "a.com" is unblocked first and
    // "b.com" 600 s later, so the two countdowns differ (1,200 s and 1,800 s left); cancelling either one, the second as well as the first,
    // must leave the other counting down from where it was, and the cancelled site stays blocked.
    @Test(arguments: ["a.com", "b.com"])
    func cancelUnblockOfOneOfTwoPendingSitesClearsOnlyThatSitesCountdown(cancelled: String) {
        let engine = makeEngine(blocking: ["a.com", "b.com"])
        engine.send(.unblock, domain: "a.com", password: rightPassword)
        _ = engine.tick(elapsed: 600)
        engine.send(.unblock, domain: "b.com", password: rightPassword)
        let other = cancelled == "a.com" ? "b.com" : "a.com"
        let otherBefore = engine.pendingUnblock(of: other)
        #expect(otherBefore != nil)
        let response = engine.send(.cancelUnblock, domain: cancelled)
        expectSuccess(response)
        #expect(engine.pendingUnblock(of: cancelled) == nil)
        #expect(engine.pendingUnblock(of: other) == otherBefore, "cancelling \(cancelled) must not touch \(other)")
        #expect(engine.state.blocked.map(\.domain) == ["a.com", "b.com"])
        let remaining = response.status?.blocked.map(\.unblockSecondsRemaining) ?? []
        #expect(remaining == (cancelled == "a.com" ? [nil, 1800] : [1200, nil]), "status showed \(remaining)")
        // The cancelled site never unblocks; the other one finishes on its own time.
        let otherSeconds = other == "a.com" ? 1200.0 : 1800.0
        #expect(engine.tick(elapsed: otherSeconds - 1) == false)
        #expect(engine.state.blocked.map(\.domain) == ["a.com", "b.com"])
        #expect(engine.tick(elapsed: 1) == true)
        #expect(engine.state.blocked.map(\.domain) == [cancelled])
        #expect(engine.blockedHosts == DomainExpander.expand(cancelled))
        #expect(engine.tick(elapsed: 1_000_000) == false)
        #expect(engine.state.blocked.map(\.domain) == [cancelled])
    }

    @Test func unblockingOneSiteLeavesTheOtherSitesAlone() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        #expect(engine.pendingUnblock(of: "example.com") == nil)
        #expect(engine.pendingUnblock(of: "reddit.com") != nil)
    }
}

@Suite struct EngineDelayTests {
    @Test(arguments: [60, 61, 1800, 3600, 86_400, 604_800])
    func setDelayAcceptsEveryValueInTheAllowedRange(seconds: Int) {
        let engine = makeEngine()
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: seconds))
    }

    // 01-overview-and-data.md § Fixed Policy Values: 60 seconds to 604800 seconds (7 days).
    @Test(arguments: [0, 1, 59, 604_801, 1_000_000, -1, -1800, Int.max, Int.min])
    func setDelayRejectsValuesOutsideTheAllowedRange(seconds: Int) {
        let engine = makeEngine()
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: seconds), .invalidDelay)
        #expect(engine.state.delaySeconds == 1800)
        #expect(engine.state.pendingDelayChange == nil)
    }

    // The range is checked before the password, so a bad number with a bad password is not counted as a wrong guess.
    @Test func setDelayChecksTheRangeBeforeThePassword() {
        let engine = makeEngine()
        expectFailure(engine.send(.setDelay, password: badPassword, seconds: 59), .invalidDelay)
        #expect(engine.state.failedAttempts == 0)
    }

    @Test func setDelayWithAWrongPasswordFailsAndChangesNothing() {
        let engine = makeEngine()
        expectFailure(engine.send(.setDelay, password: badPassword, seconds: 3600), .wrongPassword)
        #expect(engine.state.delaySeconds == 1800)
        #expect(engine.state.pendingDelayChange == nil)
        #expect(engine.state.failedAttempts == 1)
    }

    @Test func setDelayWithoutSecondsOrPasswordIsABadRequest() {
        let engine = makeEngine()
        expectFailure(engine.send(.setDelay, password: rightPassword), .badRequest)
        expectFailure(engine.send(.setDelay, seconds: 3600), .badRequest)
    }

    @Test func aLongerDelayAppliesAtOnce() {
        let engine = makeEngine()
        let response = engine.send(.setDelay, password: rightPassword, seconds: 3600)
        expectSuccess(response)
        #expect(engine.state.delaySeconds == 3600)
        #expect(engine.state.pendingDelayChange == nil)
        #expect(response.status?.delaySeconds == 3600)
        #expect(response.status?.pendingDelay == nil)
    }

    @Test func aLongerDelayDropsAPendingShorterChange() {
        let engine = makeEngine()
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        #expect(engine.state.pendingDelayChange != nil)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 7200))
        #expect(engine.state.delaySeconds == 7200)
        #expect(engine.state.pendingDelayChange == nil)
    }

    // "greater than or equal to the current delay applies at once and clears pendingDelayChange"
    @Test func aDelayEqualToTheCurrentOneAppliesAtOnceAndClearsAPendingChange() {
        let engine = makeEngine()
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        #expect(engine.state.pendingDelayChange?.newDelaySeconds == 600)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 1800))
        #expect(engine.state.delaySeconds == 1800)
        #expect(engine.state.pendingDelayChange == nil)
    }

    @Test func aShorterDelayStartsAPendingChangeWithACountdownEqualToTheCurrentDelay() {
        let engine = makeEngine()
        let response = engine.send(.setDelay, password: rightPassword, seconds: 600)
        expectSuccess(response)
        #expect(engine.state.delaySeconds == 1800)
        #expect(engine.state.pendingDelayChange == PendingDelayChange(newDelaySeconds: 600, countdown: Countdown(seconds: 1800)))
        #expect(response.status?.delaySeconds == 1800)
        #expect(response.status?.pendingDelay == PendingDelayStatus(newDelaySeconds: 600, secondsRemaining: 1800))
    }

    @Test func theShortestAllowedDelayIsStillAPendingChangeWhenItIsBelowTheCurrentOne() {
        let engine = makeEngine()
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 60))
        #expect(engine.state.delaySeconds == 1800)
        #expect(engine.state.pendingDelayChange == PendingDelayChange(newDelaySeconds: 60, countdown: Countdown(seconds: 1800)))
    }

    // A second shorter request replaces the first and starts a fresh countdown equal to the current delay.
    @Test func aSecondShorterRequestReplacesThePendingChangeWithAFreshCountdown() {
        let engine = makeEngine()
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        _ = engine.tick(elapsed: 1000)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 300))
        #expect(engine.state.pendingDelayChange == PendingDelayChange(newDelaySeconds: 300, countdown: Countdown(seconds: 1800)))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 900))
        #expect(engine.state.pendingDelayChange == PendingDelayChange(newDelaySeconds: 900, countdown: Countdown(seconds: 1800)))
    }

    @Test func aDelayIncreaseDoesNotShortenOrRestartAnUnblockThatIsAlreadyRunning() {
        let engine = makeEngine(blocking: ["reddit.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        _ = engine.tick(elapsed: 100)
        engine.send(.setDelay, password: rightPassword, seconds: 7200)
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1700, totalSeconds: 1800))
    }

    @Test func cancelDelayChangeDropsAPendingChangeWithoutAPassword() {
        let engine = makeEngine()
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        let response = engine.send(.cancelDelayChange)
        expectSuccess(response)
        #expect(engine.state.pendingDelayChange == nil)
        #expect(engine.state.delaySeconds == 1800)
        #expect(response.status?.pendingDelay == nil)
    }

    @Test func cancelDelayChangeWithNothingPendingFailsWithNothingPending() {
        expectFailure(makeEngine().send(.cancelDelayChange), .nothingPending)
    }

    @Test func setDelayBeforeAPasswordExistsFailsWithNotSetUp() {
        expectFailure(makeEngine(password: nil).send(.setDelay, password: rightPassword, seconds: 3600), .notSetUp)
    }
}

@Suite struct EngineChangePasswordTests {
    @Test func changePasswordReplacesThePasswordAtOnce() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let oldHash = engine.state.passwordHash
        let response = engine.send(.changePassword, password: rightPassword, newPassword: "brand-new-pass")
        expectSuccess(response)
        #expect(engine.state.passwordHash != oldHash)
        #expect(engine.state.passwordHash?.salt != oldHash?.salt)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .wrongPassword)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: "brand-new-pass"))
    }

    @Test func changePasswordWithAWrongOldPasswordFailsCountsAnAttemptAndKeepsTheOldPassword() {
        let engine = makeEngine()
        let hashBefore = engine.state.passwordHash
        expectFailure(engine.send(.changePassword, password: badPassword, newPassword: "brand-new-pass"), .wrongPassword)
        #expect(engine.state.passwordHash == hashBefore)
        #expect(engine.state.failedAttempts == 1)
    }

    @Test(arguments: ["", "abcde", "     ", "      "])
    func changePasswordRejectsAWeakNewPasswordAndKeepsTheOldOne(newPassword: String) {
        let engine = makeEngine(blocking: ["reddit.com"])
        let hashBefore = engine.state.passwordHash
        expectFailure(engine.send(.changePassword, password: rightPassword, newPassword: newPassword), .weakPassword)
        #expect(engine.state.passwordHash == hashBefore)
        expectSuccess(engine.send(.unblock, domain: "reddit.com", password: rightPassword))
    }

    // The old password is checked first, so a wrong old password with a weak new one reports the wrong password.
    @Test func changePasswordChecksTheOldPasswordBeforeValidatingTheNewOne() {
        let engine = makeEngine()
        expectFailure(engine.send(.changePassword, password: badPassword, newPassword: "abc"), .wrongPassword)
    }

    @Test func changePasswordWithTheRightOldPasswordResetsTheFailedAttemptCounterEvenIfTheNewOneIsWeak() {
        let engine = makeEngine()
        for _ in 0..<3 { engine.send(.changePassword, password: badPassword, newPassword: "brand-new-pass") }
        #expect(engine.state.failedAttempts == 3)
        expectFailure(engine.send(.changePassword, password: rightPassword, newPassword: "abc"), .weakPassword)
        #expect(engine.state.failedAttempts == 0)
    }

    @Test func changePasswordBeforeAPasswordExistsFailsWithNotSetUp() {
        expectFailure(makeEngine(password: nil).send(.changePassword, password: rightPassword, newPassword: "brand-new-pass"), .notSetUp)
    }

    @Test func changePasswordWithAMissingArgumentIsABadRequest() {
        let engine = makeEngine()
        expectFailure(engine.send(.changePassword, newPassword: "brand-new-pass"), .badRequest)
        expectFailure(engine.send(.changePassword, password: rightPassword), .badRequest)
    }

    @Test func changePasswordLeavesBlockedSitesAndRunningCountdownsAlone() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "reddit.com", password: rightPassword)
        _ = engine.tick(elapsed: 300)
        expectSuccess(engine.send(.changePassword, password: rightPassword, newPassword: "brand-new-pass"))
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com", "example.com"])
        #expect(engine.pendingUnblock(of: "reddit.com") == Countdown(remainingSeconds: 1500, totalSeconds: 1800))
    }
}

@Suite struct EngineUninstallAndRecoveryCommandTests {
    // Design change: an uninstall waits max(policy.minUninstallSeconds, delaySeconds) (01-overview-and-data.md § Commands (uninstall), § Fixed
    // Policy Values; 02-core-components.md § Engine, "uninstall"). This test is about the delay side of that maximum, so it runs under
    // shortUninstallPolicy, where the minimum (60 s) is below the 30 minute default delay and the countdown is the delay. Before the change
    // the same engine under designPolicy gave 1800; under the 48 hour minimum it gives 172800 (see EngineUninstallWaitTests).
    @Test func uninstallWithTheRightPasswordStartsACountdownOfTheCurrentDelayWhenTheDelayIsAboveTheMinimum() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        let response = engine.send(.uninstall, password: rightPassword)
        expectSuccess(response)
        #expect(engine.state.pendingUninstall == Countdown(seconds: 1800))
        #expect(response.status?.uninstallSecondsRemaining == 1800)
        #expect(engine.state.uninstalling == false)
    }

    // Same design change. 7200 s is the delay in effect at the request and is above the (lowered) minimum, so it is the countdown.
    @Test func uninstallUsesTheDelayInEffectWhenItIsRequested() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        engine.send(.setDelay, password: rightPassword, seconds: 7200)
        engine.send(.uninstall, password: rightPassword)
        #expect(engine.state.pendingUninstall == Countdown(seconds: 7200))
    }

    @Test func uninstallWithAWrongPasswordFailsAndStartsNothing() {
        let engine = makeEngine()
        expectFailure(engine.send(.uninstall, password: badPassword), .wrongPassword)
        #expect(engine.state.pendingUninstall == nil)
        #expect(engine.state.failedAttempts == 1)
    }

    @Test func uninstallBeforeAPasswordExistsFailsWithNotSetUp() {
        expectFailure(makeEngine(password: nil).send(.uninstall, password: rightPassword), .notSetUp)
    }

    @Test func uninstallWithoutAPasswordArgumentIsABadRequest() {
        expectFailure(makeEngine().send(.uninstall), .badRequest)
    }

    // Design change: the countdown is no longer the 1800 s delay under designPolicy, so this runs under shortUninstallPolicy to keep the
    // original figures (600 s gone of 1800 s) and the same check: a second request does not restart the running countdown.
    @Test func aSecondUninstallKeepsTheRunningCountdown() {
        let engine = makeEngine(policy: shortUninstallPolicy)
        engine.send(.uninstall, password: rightPassword)
        _ = engine.tick(elapsed: 600)
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(remainingSeconds: 1200, totalSeconds: 1800))
    }

    @Test func cancelUninstallStopsAPendingUninstallWithoutAPassword() {
        let engine = makeEngine()
        engine.send(.uninstall, password: rightPassword)
        let response = engine.send(.cancelUninstall)
        expectSuccess(response)
        #expect(engine.state.pendingUninstall == nil)
        #expect(response.status?.uninstallSecondsRemaining == nil)
    }

    @Test func cancelUninstallWithNothingPendingFailsWithNothingPending() {
        expectFailure(makeEngine().send(.cancelUninstall), .nothingPending)
    }

    // 02-core-components.md: recoveryStart fails notRoot unless peerUID == 0, then notSetUp if no password.
    @Test(arguments: [UInt32(1), 501, 502, 65_534, UInt32.max])
    func recoveryStartFromANonRootProcessFailsWithNotRoot(uid: UInt32) {
        let engine = makeEngine()
        expectFailure(engine.send(.recoveryStart, uid: uid), .notRoot)
        #expect(engine.state.recovery == nil)
    }

    @Test func recoveryStartChecksForRootBeforeCheckingForAPassword() {
        let engine = makeEngine(password: nil)
        expectFailure(engine.send(.recoveryStart, uid: 501), .notRoot)
        expectFailure(engine.send(.recoveryStart, uid: 0), .notSetUp)
    }

    @Test func recoveryStartAsRootStartsTheFortyEightHourCountdownWithoutAPassword() {
        let engine = makeEngine(blocking: ["reddit.com"])
        let response = engine.send(.recoveryStart, uid: 0)
        expectSuccess(response)
        #expect(engine.state.recovery == Countdown(seconds: 172_800))
        #expect(response.status?.recoverySecondsRemaining == 172_800)
        #expect(response.status?.passwordSet == true)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    @Test func aSecondRecoveryStartKeepsTheRunningCountdown() {
        let engine = makeEngine()
        engine.send(.recoveryStart, uid: 0)
        _ = engine.tick(elapsed: 100)
        expectSuccess(engine.send(.recoveryStart, uid: 0))
        #expect(engine.state.recovery == Countdown(remainingSeconds: 172_700, totalSeconds: 172_800))
    }

    @Test func recoveryCancelStopsARunningRecoveryWithoutAPasswordForAnyCaller() {
        let engine = makeEngine()
        engine.send(.recoveryStart, uid: 0)
        let response = engine.send(.recoveryCancel, uid: 501)
        expectSuccess(response)
        #expect(engine.state.recovery == nil)
        #expect(response.status?.recoverySecondsRemaining == nil)
        #expect(engine.state.passwordHash != nil)
    }

    @Test func recoveryCancelWithNothingRunningFailsWithNothingPending() {
        expectFailure(makeEngine().send(.recoveryCancel), .nothingPending)
    }

    // The design's two stricter-never-needs-a-password cases that sit behind a locked-out engine.
    @Test func commandsThatOnlyMakeThingsStricterStillWorkDuringALockout() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"])
        engine.send(.unblock, domain: "example.com", password: rightPassword)
        engine.send(.setDelay, password: rightPassword, seconds: 600)
        engine.send(.uninstall, password: rightPassword)
        engine.send(.recoveryStart, uid: 0)
        exhaustPasswordAttempts(engine)
        #expect(engine.state.lockout != nil)
        expectSuccess(engine.send(.status))
        expectSuccess(engine.send(.add, domain: "newsite.org"))
        expectSuccess(engine.send(.cancelUnblock, domain: "example.com"))
        expectSuccess(engine.send(.cancelDelayChange))
        expectSuccess(engine.send(.cancelUninstall))
        expectSuccess(engine.send(.recoveryCancel))
        #expect(engine.state.lockout != nil)
    }
}

@Suite struct EngineContractTests {
    // A state with a password, one site, and every kind of countdown running, to exercise handle() in a busy state.
    private static func busyState() throws -> PersistedState {
        var state = PersistedState.fresh(delaySeconds: 1800)
        state.passwordHash = try PasswordHasher.make(password: rightPassword, iterations: designPolicy.pbkdf2Iterations)
        state.blocked = [BlockedSite(domain: "reddit.com", hosts: DomainExpander.expand("reddit.com"), pendingUnblock: Countdown(seconds: 500)), BlockedSite(domain: "example.com", hosts: DomainExpander.expand("example.com"))]
        state.pendingDelayChange = PendingDelayChange(newDelaySeconds: 600, countdown: Countdown(seconds: 700))
        state.pendingUninstall = Countdown(seconds: 800)
        state.recovery = Countdown(seconds: 900)
        return state
    }

    private static func passwordState() throws -> PersistedState {
        var state = PersistedState.fresh(delaySeconds: 1800)
        state.passwordHash = try PasswordHasher.make(password: rightPassword, iterations: designPolicy.pbkdf2Iterations)
        return state
    }

    // Replays 4,000 generated requests, from every state above, and checks what the design promises for every response:
    // handle never fails, a success carries a status, a failure carries a code and a sentence, and a rejected command
    // changes nothing except the wrong-password counter.
    @Test func handleAlwaysAnswersWithAWellFormedResponseAndRejectionsChangeNothing() throws {
        let templates = [PersistedState.fresh(delaySeconds: 1800), try Self.passwordState(), try Self.busyState()]
        var seed: UInt64 = 7
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let domains: [String?] = [nil, "", "reddit.com", "example.com", "WWW.Reddit.com/x", "bad domain", "1.2.3.4", "localhost", "new-site.org", String(repeating: "a", count: 3000), "b\u{FC}cher.de"]
        let passwords: [String?] = [nil, "", rightPassword, badPassword, "abc", "\u{0}"]
        let numbers: [Int?] = [nil, 0, 59, 60, 600, 1800, 3600, 604_800, 604_801, -1, Int.max, Int.min]
        var kinds = Set<String>()
        for _ in 0..<4000 {
            let template = templates[next(templates.count)]
            let engine = Engine(state: template, policy: designPolicy)
            let command = Command.allCases[next(Command.allCases.count)]
            let uid: uid_t = next(3) == 0 ? 0 : 501
            let response = engine.handle(Request(command: command, domain: domains[next(domains.count)], password: passwords[next(passwords.count)], newPassword: passwords[next(passwords.count)], seconds: numbers[next(numbers.count)]), peerUID: uid)
            if response.ok {
                #expect(response.status != nil, "success without status for \(command)")
                #expect(response.errorCode == nil)
                kinds.insert("ok")
            } else {
                #expect(response.errorCode != nil, "failure without code for \(command)")
                #expect(!(response.error ?? "").isEmpty, "failure without sentence for \(command)")
                kinds.insert(response.errorCode?.rawValue ?? "none")
                if response.errorCode != .wrongPassword { #expect(engine.state == template, "\(command) was rejected with \(String(describing: response.errorCode)) but changed the state") }
            }
        }
        // Guard against a vacuous run: the generator must reach both successes and several different failure codes.
        #expect(kinds.contains("ok"))
        #expect(kinds.count >= 8, "only reached \(kinds.sorted())")
    }

    // The design's Policy is a struct so sandbox mode and tests can shrink the numbers: every field must really be used.
    @Test func everyPolicyFieldChangesTheBehaviorItGoverns() {
        // Design change: minUninstallSeconds is a policy field too (150 here, above the delay of 100 that this test sets, so the minimum is the wait).
        let policy = Policy(defaultDelaySeconds: 50, minDelaySeconds: 5, maxDelaySeconds: 100, recoverySeconds: 3, lockoutSeconds: 7, maxFailedAttempts: 2, pbkdf2Iterations: 1, minUninstallSeconds: 150)
        let engine = makeEngine(blocking: ["reddit.com"], policy: policy)
        #expect(engine.state.passwordHash?.iterations == 1)
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: 4), .invalidDelay)
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: 101), .invalidDelay)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 5))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 100))
        #expect(engine.state.delaySeconds == 100)
        expectSuccess(engine.send(.recoveryStart, uid: 0))
        #expect(engine.state.recovery == Countdown(seconds: 3))
        // The delay is now 100, so an uninstall that followed the delay would wait 100 s; the policy's minimum makes it 150 s.
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 150))
        expectSuccess(engine.send(.cancelUninstall))
        let first = engine.send(.unblock, domain: "reddit.com", password: badPassword)
        expectFailure(first, .wrongPassword)
        #expect(engine.state.lockout == nil)
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: badPassword), .wrongPassword)
        #expect(engine.state.lockout == Countdown(seconds: 7))
        #expect(engine.state.failedAttempts == 0)
    }
}

// The argument a request can leave out, for the argument-rule tests below.
enum RequiredField: String, Sendable {
    case domain, password, newPassword, seconds
}

// One request with exactly one required field left out: the command and the field that is missing.
struct OmittedField: Sendable, CustomTestStringConvertible {
    let command: Command
    let omitted: RequiredField

    // The name shown in the test report.
    var testDescription: String { "\(command.rawValue) without \(omitted.rawValue)" }

    // Every password-taking command with each of its required fields left out in turn. The required fields are the ones listed in
    // 01-overview-and-data.md § Commands: unblock (domain, password), setDelay (seconds, password), changePassword (password, newPassword),
    // uninstall (password).
    static let all: [OmittedField] = [
        OmittedField(command: .unblock, omitted: .domain), OmittedField(command: .unblock, omitted: .password),
        OmittedField(command: .setDelay, omitted: .seconds), OmittedField(command: .setDelay, omitted: .password),
        OmittedField(command: .changePassword, omitted: .password), OmittedField(command: .changePassword, omitted: .newPassword),
        OmittedField(command: .uninstall, omitted: .password),
    ]
}

// The two situations in which a password check would have an effect on the failed-attempt counter or the lockout.
enum ArgumentRuleSetup: Sendable, CustomTestStringConvertible {
    case activeLockout, wrongPassword

    // The name shown in the test report.
    var testDescription: String {
        switch self {
        case .activeLockout: return "during an active lockout"
        case .wrongPassword: return "with a wrong password"
        }
    }
}

// 02-core-components.md § Engine, "Argument rule": "a missing required argument fails with badRequest before any lockout or password check,
// so a malformed request never costs a password attempt. setDelay also checks the range (invalidDelay) before the password." And the
// command rules for unblock: normalize, find the site (notBlocked), and only then check the password.
@Suite struct EngineArgumentRuleTests {
    // An engine with one blocked site, and in the lockout setup already locked out by five wrong passwords.
    private func argumentEngine(for setup: ArgumentRuleSetup) -> Engine {
        let engine = makeEngine(blocking: ["reddit.com"])
        if setup == .activeLockout {
            exhaustPasswordAttempts(engine)
            #expect(engine.state.lockout == Countdown(seconds: 900), "test setup: the engine must be locked out")
            #expect(engine.state.failedAttempts == 0)
        }
        return engine
    }

    // Omitting exactly one required field must give badRequest whatever the password situation is: the lockout, or a wrong password that
    // would otherwise be counted. The rest of the request is complete, and a password that is present is the right one during the
    // lockout (a lockout refuses it anyway) and the wrong one in the other setup (which would cost an attempt if it were checked).
    @Test(arguments: OmittedField.all, [ArgumentRuleSetup.activeLockout, .wrongPassword])
    func aRequestMissingOneRequiredFieldIsABadRequestAndCostsNoPasswordAttempt(case request: OmittedField, setup: ArgumentRuleSetup) {
        let engine = argumentEngine(for: setup)
        let before = engine.state
        let supplied = setup == .activeLockout ? rightPassword : badPassword
        let domain: String? = request.command == .unblock && request.omitted != .domain ? "reddit.com" : nil
        let seconds: Int? = request.command == .setDelay && request.omitted != .seconds ? 3600 : nil
        let newPassword: String? = request.command == .changePassword && request.omitted != .newPassword ? "brand-new-pass" : nil
        let password: String? = request.omitted == .password ? nil : supplied
        let response = engine.send(request.command, domain: domain, password: password, newPassword: newPassword, seconds: seconds)
        expectFailure(response, .badRequest)
        #expect(engine.state == before, "\(request.testDescription) \(setup.testDescription) changed the state")
        #expect(engine.state.failedAttempts == 0, "a malformed request must not count as a wrong password")
        #expect(engine.state.lockout == before.lockout)
        #expect(engine.state.passwordHash == before.passwordHash)
        #expect(engine.pendingUnblock(of: "reddit.com") == nil)
    }

    // The site is looked up before the password is checked, so an unknown site gives notBlocked even in a lockout, which is a different
    // answer from lockedOut, and it changes nothing.
    @Test func unblockOfAnUnknownSiteDuringALockoutIsNotBlockedAndChangesNothing() {
        let engine = argumentEngine(for: .activeLockout)
        let before = engine.state
        expectFailure(engine.send(.unblock, domain: "example.com", password: rightPassword), .notBlocked)
        expectFailure(engine.send(.unblock, domain: "https://www.example.org/x", password: badPassword), .notBlocked)
        #expect(engine.state == before)
        #expect(engine.state.failedAttempts == 0)
        // The blocked site itself still gets the lockout answer, so the notBlocked above was not a general "anything goes in a lockout".
        expectFailure(engine.send(.unblock, domain: "reddit.com", password: rightPassword), .lockedOut)
    }

    // Normalizing comes first of all: an invalid name is invalidDomain in a lockout too.
    @Test(arguments: ["1.2.3.4", "not a site", "reddit", "evil.com\n0.0.0.0 bank.com"])
    func unblockOfAnInvalidNameDuringALockoutIsInvalidDomainAndChangesNothing(input: String) {
        let engine = argumentEngine(for: .activeLockout)
        let before = engine.state
        expectFailure(engine.send(.unblock, domain: input, password: rightPassword), .invalidDomain)
        #expect(engine.state == before)
    }

    // The range is checked before the password, and the password check is where the lockout answer comes from, so a bad range wins.
    @Test(arguments: [59, 0, -1, 604_801, Int.max, Int.min])
    func setDelayWithAnOutOfRangeValueDuringALockoutIsInvalidDelayAndChangesNothing(seconds: Int) {
        let engine = argumentEngine(for: .activeLockout)
        let before = engine.state
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: seconds), .invalidDelay)
        expectFailure(engine.send(.setDelay, password: badPassword, seconds: seconds), .invalidDelay)
        #expect(engine.state == before)
        #expect(engine.state.failedAttempts == 0)
        // A value in range gets the lockout answer, so the invalidDelay above came from the range check.
        expectFailure(engine.send(.setDelay, password: rightPassword, seconds: 60), .lockedOut)
    }
}

import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/01-overview-and-data.md § Commands (uninstall: "48 hours, or the unblock delay if that is longer, so
// uninstalling is never a faster way to unblock everything than unblocking. Every site stays blocked until it ends") and § Fixed Policy Values
// ("Uninstall wait: 172800 seconds (48 hours), or the unblock delay when that is longer"), from 02-core-components.md § Engine (Properties:
// the policy field minUninstallSeconds, 172800 in Policy.production and 2 in Policy.fastForTests; Command rules: uninstall starts pendingUninstall
// at the larger of policy.minUninstallSeconds and delaySeconds unless one is already running; Tick rule) and § Formatting (a duration is written
// with at most the two largest non-zero units, so 172800 s is "2 days").

// The production policy with only the password hashing cost lowered, so that setting a password in a test takes milliseconds.
private let fastHashingProduction: Policy = {
    var policy = Policy.production
    policy.pbkdf2Iterations = 1000
    return policy
}()

// An engine under the production policy (see fastHashingProduction) with a password set, the given sites blocked and, when `delay` is given,
// that unblock delay in effect from the start (otherwise the production default of 30 minutes).
private func productionEngine(delay: Int? = nil, blocking domains: [String] = []) -> Engine {
    var policy = fastHashingProduction
    if let delay { policy.defaultDelaySeconds = delay }
    return makeEngine(blocking: domains, policy: policy)
}

// Every "<number> <duration unit>" pair in the text, written as "N unit", so a figure and its unit are judged together ("12 days" is not "2 days").
private func durationFigures(in text: String) -> [String] {
    let units: Set<String> = ["second", "seconds", "minute", "minutes", "hour", "hours", "day", "days"]
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    var found: [String] = []
    for (index, word) in words.enumerated() where index > 0 && units.contains(word) {
        if let number = Int(words[index - 1]) { found.append("\(number) \(word)") }
    }
    return found
}

@Suite struct EngineUninstallWaitTests {
    // MARK: the rule, with the production policy

    // Design: 30 minutes is below the 48 hour minimum, so the minimum is the wait.
    @Test func underTheProductionPolicyWithTheDefaultThirtyMinuteDelayAnUninstallStartsA172800SecondCountdown() {
        let engine = productionEngine(blocking: ["reddit.com"])
        #expect(engine.state.delaySeconds == 1800, "premise: the production default delay is 30 minutes")
        #expect(engine.policy == fastHashingProduction, "premise: the engine runs the production policy")
        let response = engine.send(.uninstall, password: rightPassword)
        expectSuccess(response)
        #expect(engine.state.pendingUninstall == Countdown(seconds: 172_800))
        #expect(response.status?.uninstallSecondsRemaining == 172_800)
        #expect(engine.snapshot(hostsFileHealthy: true).uninstallSecondsRemaining == 172_800)
        #expect(engine.state.delaySeconds == 1800, "starting an uninstall does not change the unblock delay")
        #expect(engine.state.uninstalling == false)
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
    }

    // Design: 3 days is longer than the minimum, so the delay is the wait. A longer delay applies at once, so no waiting is needed in the test.
    @Test func withAThreeDayDelayAnUninstallStartsA259200SecondCountdown() {
        let engine = productionEngine()
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 259_200))
        #expect(engine.state.delaySeconds == 259_200, "premise: a longer delay applies at once")
        #expect(engine.state.pendingDelayChange == nil)
        let response = engine.send(.uninstall, password: rightPassword)
        expectSuccess(response)
        #expect(engine.state.pendingUninstall == Countdown(seconds: 259_200))
        #expect(response.status?.uninstallSecondsRemaining == 259_200)
    }

    // Design: "the larger of policy.minUninstallSeconds and delaySeconds". Around the 172800 s line, and at both ends of the allowed delay range.
    // The delay is the engine's starting delay here (the policy's default), so 60 s, which setDelay could only reach through a waiting change, is covered.
    // The same figure is also what `Engine.uninstallWaitSeconds` reports before the uninstall is requested.
    @Test(arguments: [(60, 172_800), (1800, 172_800), (86_400, 172_800), (172_799, 172_800), (172_800, 172_800), (172_801, 172_801), (259_200, 259_200), (604_800, 604_800)])
    func theUninstallWaitIsTheLargerOfFortyEightHoursAndTheDelay(delay: Int, wait: Int) {
        let engine = productionEngine(delay: delay)
        #expect(engine.state.delaySeconds == delay, "premise")
        #expect(engine.uninstallWaitSeconds == wait)
        let response = engine.send(.uninstall, password: rightPassword)
        expectSuccess(response)
        #expect(engine.state.pendingUninstall == Countdown(seconds: Double(wait)))
        #expect(response.status?.uninstallSecondsRemaining == wait)
        // The reason for the rule: the countdown that was started is never shorter than the unblock delay.
        #expect((engine.state.pendingUninstall?.totalSeconds ?? 0) >= Double(delay), "uninstalling must never be a faster way to unblock everything than unblocking")
    }

    // Design: the wait is read when the request arrives. A shorter delay that is still counting down does not count yet: 3 days is in effect.
    @Test func aDelayChangeThatIsStillPendingDoesNotShortenTheWait() {
        let engine = productionEngine(delay: 259_200)
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 3600))
        #expect(engine.state.pendingDelayChange?.newDelaySeconds == 3600, "premise: the shorter delay is waiting")
        #expect(engine.state.delaySeconds == 259_200)
        #expect(engine.uninstallWaitSeconds == 259_200)
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 259_200))
    }

    // MARK: the figure comes from the policy, not from a fixed number

    // Design: Policy.minUninstallSeconds is the minimum. The same delay (1800) with different minimums moves the wait, in both directions.
    @Test(arguments: [(5000, 1800, 5000), (100, 1800, 1800), (1799, 1800, 1800), (1800, 1800, 1800), (1801, 1800, 1801), (1, 1800, 1800)])
    func theMinimumComesFromThePolicyField(minimum: Int, delay: Int, wait: Int) {
        var policy = designPolicy
        policy.minUninstallSeconds = minimum
        let engine = makeEngine(policy: policy)
        #expect(engine.state.delaySeconds == delay, "premise")
        #expect(engine.uninstallWaitSeconds == wait)
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: Double(wait)))
    }

    // Design: Policy.fastForTests.minUninstallSeconds is 2, so a sandbox uninstall waits 2 s with the 2 s default delay, and the delay when longer.
    @Test func underTheFastTestPolicyAnUninstallWaitsTwoSecondsOrTheLongerDelay() {
        let engine = makeEngine(policy: .fastForTests)
        let first = engine.send(.uninstall, password: rightPassword)
        expectSuccess(first)
        #expect(engine.state.pendingUninstall == Countdown(seconds: 2))
        #expect(first.status?.uninstallSecondsRemaining == 2)
        expectSuccess(engine.send(.cancelUninstall))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 5))
        #expect(engine.state.delaySeconds == 5, "premise: a longer delay applies at once")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 5))
    }

    // MARK: damaged or hand-edited delays cannot make the uninstall quick

    // The delay in a state file that was damaged or edited by hand may be zero or negative. The wait is still the 48 hour minimum, where the
    // old rule (the delay itself) would have produced a countdown that is already finished.
    @Test(arguments: [0, -1, Int.min, 1])
    func aStoredDelayBelowTheMinimumNeverMakesTheUninstallQuick(delay: Int) {
        var state = productionEngine().state
        state.delaySeconds = delay
        let engine = Engine(state: state, policy: fastHashingProduction)
        #expect(engine.uninstallWaitSeconds == 172_800)
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 172_800))
        #expect(engine.tick(elapsed: 172_799) == false)
        #expect(engine.state.uninstalling == false)
    }

    // MARK: while it counts down

    // Design: "Every site stays blocked until it ends", and the countdown is exactly 172800 s. Half a second short of it nothing has happened and the
    // sites are still blocked; the last half second runs it out. Every step is a whole or half second, so the sums are exact in binary floating point.
    @Test func theSitesStayBlockedAndOnUninstallStaysQuietUntilTheLastHalfSecondOfTheWait() {
        let engine = productionEngine(blocking: ["reddit.com", "example.com"])
        var calls = 0
        engine.onUninstall = { calls += 1 }
        let hostsBefore = engine.blockedHosts
        let writtenBefore = engine.hostsToWrite
        #expect(hostsBefore.contains("reddit.com") && hostsBefore.contains("example.com"), "premise")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        var elapsed = 0.0
        // The running totals are 1, 86400, 172799 and 172799.5 seconds, and all of them are exact in binary floating point.
        for step in [1.0, 86_399.0, 86_399.0, 0.5] {
            #expect(engine.tick(elapsed: step) == false, "nothing finishes \(elapsed + step) s into the wait")
            elapsed += step
            #expect(calls == 0, "onUninstall fired \(elapsed) s into the wait")
            #expect(engine.state.uninstalling == false)
            #expect(engine.state.blocked.map(\.domain) == ["reddit.com", "example.com"], "a site was dropped \(elapsed) s into the wait")
            #expect(engine.blockedHosts == hostsBefore)
        }
        #expect(elapsed == 172_799.5, "premise: the steps add up to half a second short of 48 hours")
        #expect(calls == 0, "onUninstall must not fire 0.5 s before the end")
        #expect(engine.hostsToWrite == writtenBefore)
        #expect(engine.send(.status).status?.uninstallSecondsRemaining == 1, "half a second left shows as one second")

        #expect(engine.tick(elapsed: 0.5) == true, "the last half second finishes the countdown and asks for a save")
        #expect(calls == 1)
        #expect(engine.state.uninstalling == true)
        #expect(engine.tick(elapsed: 100) == false)
        #expect(calls == 1, "onUninstall fires once")
    }

    // MARK: a pending uninstall keeps its countdown

    // Design (Command rules, uninstall): a pending uninstall is "already running", so nothing about it is recomputed. Raising the delay afterwards, so
    // that a new uninstall would wait longer, neither stretches the running countdown nor restarts it; it ends when it would have ended.
    @Test(arguments: [(1800, 259_200, 172_800), (259_200, 604_800, 259_200)])
    func aPendingUninstallKeepsItsCountdownWhenTheDelayIsRaisedAfterwards(start: Int, raised: Int, wait: Int) {
        let engine = productionEngine(delay: start)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: Double(wait)), "premise")
        _ = engine.tick(elapsed: 1000)
        let kept = Countdown(remainingSeconds: Double(wait - 1000), totalSeconds: Double(wait))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: raised))
        #expect(engine.state.delaySeconds == raised, "premise: a longer delay applies at once")
        #expect(engine.state.pendingUninstall == kept)
        #expect(engine.uninstallWaitSeconds == raised, "a new uninstall would now wait for the longer delay")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == kept, "asking again does not restart or stretch the running countdown")
        #expect(engine.tick(elapsed: Double(wait - 1000 - 1)) == false)
        #expect(calls == 0)
        #expect(engine.tick(elapsed: 1) == true, "it ends after the original \(wait) s")
        #expect(calls == 1 && engine.state.uninstalling == true)
    }

    // Design: lowering the delay (it takes effect after the old delay) does not touch a pending uninstall either, and the 48 hour minimum is
    // still the wait for an uninstall that is asked for after the lower delay is in force.
    @Test func aPendingUninstallKeepsItsCountdownWhenTheDelayIsLoweredAndTheLowerDelayTakesEffect() {
        let engine = productionEngine()
        var calls = 0
        engine.onUninstall = { calls += 1 }
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 60))
        #expect(engine.state.pendingDelayChange?.newDelaySeconds == 60, "premise: the lower delay waits for 1800 s")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 172_800))
        #expect(engine.tick(elapsed: 1800) == true, "the delay change finishes")
        #expect(engine.state.delaySeconds == 60)
        #expect(engine.state.pendingDelayChange == nil)
        let kept = Countdown(remainingSeconds: 171_000, totalSeconds: 172_800)
        #expect(engine.state.pendingUninstall == kept)
        #expect(engine.uninstallWaitSeconds == 172_800, "the minimum holds for the lowered delay")
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == kept)
        #expect(engine.tick(elapsed: 170_999) == false)
        #expect(calls == 0)
        #expect(engine.tick(elapsed: 1) == true)
        #expect(calls == 1)
    }

    // Design: "unless one is already running" also covers a countdown that was started before the minimum existed (an upgrade keeps every countdown
    // in the state file): it is left alone, not raised to 172800 s.
    @Test func anUninstallCountdownAlreadyRunningFromBeforeKeepsItsShorterLength() {
        var state = makeEngine().state
        state.pendingUninstall = Countdown(remainingSeconds: 100, totalSeconds: 1800)
        let engine = Engine(state: state, policy: designPolicy)
        var calls = 0
        engine.onUninstall = { calls += 1 }
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(remainingSeconds: 100, totalSeconds: 1800))
        #expect(engine.tick(elapsed: 99) == false)
        #expect(engine.tick(elapsed: 1) == true)
        #expect(calls == 1)
    }

    // Design: a cancelled uninstall is gone, and the next request starts a full new wait from the delay in effect then.
    @Test func anUninstallAskedForAfterACancelStartsAFreshWaitFromTheDelayThenInEffect() {
        let engine = productionEngine()
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        _ = engine.tick(elapsed: 5000)
        expectSuccess(engine.send(.cancelUninstall))
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 172_800), "a full 48 hours again, not what was left")
        expectSuccess(engine.send(.cancelUninstall))
        expectSuccess(engine.send(.setDelay, password: rightPassword, seconds: 259_200))
        expectSuccess(engine.send(.uninstall, password: rightPassword))
        #expect(engine.state.pendingUninstall == Countdown(seconds: 259_200))
    }

    // MARK: the response message

    // Design (Formatting): the message gives the wait the way the CLI and the app write every duration, so 48 hours is "2 days". The design does not
    // fix the sentence, so only the figures in it are judged: it must name the 48 hour wait (as "2 days", or "48 hours" if written out) and no other
    // time, in particular not the 30 minute delay that the old rule used.
    @Test func theResponseMessageNamesTheFortyEightHourWaitAndNotTheThirtyMinuteDelay() {
        let engine = productionEngine()
        let response = engine.send(.uninstall, password: rightPassword)
        expectSuccess(response)
        let message = response.message ?? ""
        let figures = durationFigures(in: message)
        #expect(figures == ["2 days"] || figures == ["48 hours"], "message was: \(message)")
    }

    // Design: with a delay longer than the minimum the message names that wait. 3 days is "3 days" (or "72 hours" written out), not the 2 day minimum.
    @Test func theResponseMessageNamesTheDelayWhenTheDelayIsTheLongerWait() {
        let engine = productionEngine(delay: 259_200)
        let response = engine.send(.uninstall, password: rightPassword)
        expectSuccess(response)
        let message = response.message ?? ""
        let figures = durationFigures(in: message)
        #expect(figures == ["3 days"] || figures == ["72 hours"], "message was: \(message)")
    }

    // The message of a refused request is not a start message: a wrong password names no wait and starts none.
    @Test func aRefusedUninstallNamesNoWaitAndStartsNone() {
        let engine = productionEngine()
        let response = engine.send(.uninstall, password: badPassword)
        expectFailure(response, .wrongPassword)
        #expect(engine.state.pendingUninstall == nil)
        #expect(durationFigures(in: response.error ?? "").allSatisfy { !$0.hasSuffix("days") }, "message was: \(response.error ?? "")")
    }

    // MARK: no reply before the engine is set up

    // The figure is a property of the policy and the delay, not of the password: it is the same before a password exists (the command still fails).
    @Test func theWaitIsReportedBeforeAPasswordExistsAndTheCommandStillFails() {
        let engine = makeEngine(password: nil, policy: fastHashingProduction)
        #expect(engine.uninstallWaitSeconds == 172_800)
        expectFailure(engine.send(.uninstall, password: rightPassword), .notSetUp)
        #expect(engine.state.pendingUninstall == nil)
    }
}

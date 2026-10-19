import Foundation
import Testing
import SiteBlockCore

// How time moves a temporary unblock. Expected values come from Design Plans/02-core-components.md § Engine ("Temporary unblock tick rule": startsIn is
// advanced first, the unused part of `elapsed` is taken off `window`, neither goes below 0, `tick` returns true when one opened or finished, a finished one
// is removed and the site stays, a gap that covers both finishes it in that tick and reports only the ending) and § Models and Protocol Types (Countdown:
// negative or non-finite input is ignored, a remainder below a nanosecond is 0), and from 01-overview-and-data.md § Data Model (isOpen, isFinished).
// Fake elapsed time only: a one-hour wait is a few microseconds here.

// A site or a path rule with a temporary unblock scheduled, so each tick test can run once for a site and once for a rule.
struct TickSubject {
    let engine: Engine
    let rule: Bool

    // The temporary unblock the entry has right now, or nil.
    var temp: TemporaryUnblock? { rule ? engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") : engine.temporaryUnblock(of: "reddit.com") }
    // True while the site or rule is still on the block list.
    var onList: Bool { rule ? engine.pathRule("youtube.com", "/shorts") != nil : engine.site("reddit.com") != nil }
    // The status the engine reports for the entry's temporary unblock.
    var status: TemporaryUnblockStatus? { rule ? engine.temporaryStatus(ofRule: "youtube.com/shorts") : engine.temporaryStatus(of: "reddit.com") }

    // Builds an engine under the given policy, blocks the site or rule, and schedules a temporary unblock with the given start wait and window.
    init(rule: Bool, start: Int, window: Int, policy: Policy = .fastForTests) {
        self.rule = rule
        engine = makeEngine(policy: policy)
        if rule { expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts")) } else { expectSuccess(engine.send(.add, domain: "reddit.com")) }
        expectSuccess(engine.temporarily(rule ? "youtube.com/shorts" : "reddit.com", seconds: window, start: start, rule: rule))
    }
}

@Suite struct TemporaryUnblockTickTests {
    // 02 § Engine, tick rule: "startsIn is advanced first." While the start wait has not run out, the window is not touched and nothing is reported.
    @Test(arguments: [false, true])
    func timeBeforeTheOpeningOnlyShortensTheStartWait(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: 3) == false, "nothing happened that must be saved at once")
        #expect(subject.temp?.startsIn.remainingSeconds == 7)
        #expect(subject.temp?.window.remainingSeconds == 100, "the window waits until the site opens")
        #expect(subject.temp?.isOpen == false)
    }

    // The tick that uses up exactly the start wait opens the site with its whole window left, and reports a change to save.
    @Test(arguments: [false, true])
    func aTickThatEndsTheStartWaitExactlyOpensItWithTheFullWindow(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: 10) == true)
        #expect(subject.temp?.startsIn.remainingSeconds == 0 && subject.temp?.window.remainingSeconds == 100)
        #expect(subject.temp?.isOpen == true)
    }

    // 05 § Unit Tests: "the part it did not use is taken off window". A tick that crosses the opening takes the part after the opening off the window.
    @Test(arguments: [false, true])
    func aTickThatCrossesTheOpeningSplitsItBetweenTheStartWaitAndTheWindow(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: 25) == true)
        #expect(subject.temp?.startsIn.remainingSeconds == 0)
        #expect(subject.temp?.window.remainingSeconds == 85, "15 of the 25 seconds came after the opening")
        #expect(subject.temp?.isOpen == true)
    }

    // The part after the opening can be a tiny fraction.
    @Test(arguments: [false, true])
    func aTickThatBarelyCrossesTheOpeningTakesOnlyTheSurplusOffTheWindow(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: 10.125) == true)
        #expect(subject.temp?.window.remainingSeconds == 99.875)
    }

    // 02 § Engine: "When startsIn was already 0, all of elapsed is taken off window." Ticks while open report nothing, until the one that ends the window.
    @Test(arguments: [false, true])
    func whileOpenAllOfTheTimeComesOffTheWindowAndNothingIsReportedUntilTheEnd(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: 10) == true)
        #expect(subject.engine.tick(elapsed: 30) == false)
        #expect(subject.temp?.window.remainingSeconds == 70 && subject.temp?.startsIn.remainingSeconds == 0)
        #expect(subject.engine.tick(elapsed: 69.875) == false)
        #expect(subject.temp?.window.remainingSeconds == 0.125)
        #expect(subject.temp?.isOpen == true, "a window with time left is still open")
        #expect(subject.engine.tick(elapsed: 0.125) == true, "the tick that empties the window reports a change to save")
    }

    // 02 § Engine: "A finished one is removed by setting temporaryUnblock to nil, and the site or rule stays on the block list."
    @Test(arguments: [false, true])
    func theEndingRemovesTheTemporaryUnblockButNotTheSiteOrRule(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        _ = subject.engine.tick(elapsed: 10)
        #expect(subject.engine.tick(elapsed: 100) == true)
        #expect(subject.temp == nil)
        #expect(subject.onList, "the entry stays on the block list")
        #expect(subject.status == nil)
        #expect(rule ? subject.engine.browserBlockEntries.chrome == ["youtube.com/shorts"] : subject.engine.blockedHosts.contains("reddit.com"), "blocked again")
    }

    // A tick longer than what is left of the window ends it just the same, and the surplus is lost without going below zero or into anything else.
    @Test(arguments: [false, true])
    func aTickLongerThanTheRestOfTheWindowEndsItInThatTick(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        _ = subject.engine.tick(elapsed: 10)
        _ = subject.engine.tick(elapsed: 90)
        #expect(subject.temp?.window.remainingSeconds == 10)
        #expect(subject.engine.tick(elapsed: 500) == true)
        #expect(subject.temp == nil && subject.onList)
    }

    // 02 § Engine: "When one long gap, such as the Mac asleep, covers both the opening and the end, the temporary unblock simply finishes in that tick."
    @Test(arguments: [(110.0, false), (110.125, false), (500.0, false), (604_800.0, false), (110.0, true), (1_000_000.0, true)])
    func aGapCoveringTheWholeStartWaitAndWindowFinishesItInOneTick(gap: Double, rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: gap) == true)
        #expect(subject.temp == nil)
        #expect(subject.onList)
        #expect(subject.engine.tick(elapsed: 5) == false, "nothing is left to report")
    }

    // One tick short of covering the whole thing is open, with a sliver of window left.
    @Test(arguments: [false, true])
    func aGapJustShortOfTheWholeStartWaitAndWindowLeavesItOpen(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: 109.875) == true, "it opened in this tick")
        #expect(subject.temp?.isOpen == true && subject.temp?.window.remainingSeconds == 0.125)
    }

    // Nothing in a tick can push a countdown below zero or add time, and nothing is reported, for the input the clock must never be able to cause.
    @Test(arguments: [-1.0, -1000.0, -0.0, 0.0, Double.nan, Double.infinity, -Double.infinity])
    func negativeZeroAndNonFiniteElapsedTimeChangesNothing(elapsed: Double) {
        let subject = TickSubject(rule: false, start: 10, window: 100)
        let before = subject.engine.state
        #expect(subject.engine.tick(elapsed: elapsed) == false)
        #expect(subject.engine.state == before)
        _ = subject.engine.tick(elapsed: 10)
        let open = subject.engine.state
        #expect(subject.engine.tick(elapsed: elapsed) == false)
        #expect(subject.engine.state == open, "an open window does not move on bad input either")
    }

    // The largest finite time is just a very long gap.
    @Test(arguments: [1e15, 1e300, Double.greatestFiniteMagnitude])
    func anAbsurdlyLongGapJustFinishesIt(gap: Double) {
        let subject = TickSubject(rule: false, start: 10, window: 100)
        #expect(subject.engine.tick(elapsed: gap) == true)
        #expect(subject.temp == nil && subject.onList)
    }

    // A start wait of 2 s and a window of 3 s, ticked 0.1 s at a time, are over after exactly 50 ticks: not 49, and with no tick to spare. Subtracting 0.1 twenty times from 2.0 leaves -6e-16 and thirty times from 3.0
    // leaves -1.5e-15, tiny negative residues that the "never below zero" rule absorbs; the tick that reaches zero is the 20th and the 50th. It opens at tick 20 and ends at tick 50, and only those two ticks ask for a save.
    // (A tiny POSITIVE residue, which only the 1e-9 clamp of 02 § Models and Protocol Types (Countdown) can clear, is what the ten-equal-parts test below exercises: 1.0 minus 0.1 ten times leaves 1.4e-16.)
    @Test(arguments: [false, true])
    func tenthOfASecondTicksOpenAfterTwentyAndEndAfterFifty(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 2, window: 3)
        var saves: [Int] = []
        for tick in 1...60 {
            let before = subject.temp
            if subject.engine.tick(elapsed: 0.1) { saves.append(tick) }
            if tick < 20 { #expect(subject.temp?.isOpen == false, "tick \(tick): still waiting") }
            if (20..<50).contains(tick) { #expect(subject.temp?.isOpen == true, "tick \(tick): open (before: \(String(describing: before)))") }
            if tick >= 50 { #expect(subject.temp == nil, "tick \(tick): over") }
        }
        #expect(saves == [20, 50], "the ticks that asked for an immediate save")
        #expect(subject.onList)
    }

    // The same with a tick of exactly one tenth of the window: ten ticks end it, not eleven.
    @Test func aWindowTickedInTenEqualPartsEndsOnTheTenth() {
        let subject = TickSubject(rule: false, start: 2, window: 1)
        _ = subject.engine.tick(elapsed: 2)
        for tick in 1...9 { #expect(subject.engine.tick(elapsed: 0.1) == false, "tick \(tick)") }
        #expect(subject.temp?.isOpen == true)
        #expect(subject.engine.tick(elapsed: 0.1) == true)
        #expect(subject.temp == nil)
    }

    // 02 § Engine, Temporary unblock tick rule: "tick returns true ... in two cases", so between those two ticks every tick returns false, however many there are.
    @Test(arguments: [false, true])
    func onlyTheOpeningTickAndTheEndingTickAskForASave(rule: Bool) {
        let subject = TickSubject(rule: rule, start: 2, window: 3)
        let saves = subject.engine.tick(0.25, times: 4 * 5 + 1)
        #expect(saves == 2, "5 seconds in 0.25 s steps: one save at the opening (tick 8) and one at the end (tick 20)")
    }

    // Every entry is advanced by the same elapsed time, independently: the waiting one counts down, the open one's window counts down, the finished one is removed.
    @Test func severalEntriesAreAdvancedTogetherEachOnItsOwnSchedule() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com", "example.org"], policy: .fastForTests)
        expectSuccess(engine.send(.addPath, domain: "youtube.com/shorts"))
        expectSuccess(engine.temporarily("reddit.com", seconds: 100, start: 10))
        expectSuccess(engine.temporarily("example.com", seconds: 5, start: 4))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 50, start: 2, rule: true))
        #expect(engine.tick(elapsed: 6) == true, "the rule opened and example.com opened")
        #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn.remainingSeconds == 4 && engine.temporaryUnblock(of: "reddit.com")?.window.remainingSeconds == 100)
        #expect(engine.temporaryUnblock(of: "example.com")?.isOpen == true && engine.temporaryUnblock(of: "example.com")?.window.remainingSeconds == 3)
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts")?.window.remainingSeconds == 46)
        #expect(engine.temporaryUnblock(of: "example.org") == nil, "a site without a temporary unblock gets none")
        #expect(engine.tick(elapsed: 4) == true, "example.com ended (its last 3 s, the 4th is lost) and reddit.com opened")
        #expect(engine.temporaryUnblock(of: "example.com") == nil && engine.site("example.com") != nil)
        #expect(engine.temporaryUnblock(of: "reddit.com")?.isOpen == true && engine.temporaryUnblock(of: "reddit.com")?.window.remainingSeconds == 100)
        #expect(engine.temporaryUnblock(ofRule: "youtube.com", "/shorts")?.window.remainingSeconds == 42)
    }

    // A temporary unblock and a permanent unblock on other sites run side by side, and either finishing asks for a save.
    @Test func aTemporaryUnblockDoesNotDisturbAPermanentUnblockCountdownOnAnotherSite() {
        let engine = makeEngine(blocking: ["reddit.com", "example.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 1800, start: 3600))
        expectSuccess(engine.send(.unblock, domain: "example.com", password: rightPassword))
        #expect(engine.tick(elapsed: 1799) == false)
        #expect(engine.tick(elapsed: 1) == true, "the permanent unblock finished")
        #expect(engine.site("example.com") == nil)
        #expect(engine.temporaryUnblock(of: "reddit.com")?.startsIn.remainingSeconds == 1800)
        #expect(engine.tick(elapsed: 1800) == true, "and the temporary one opened")
        #expect(engine.temporaryUnblock(of: "reddit.com")?.isOpen == true)
    }

    // 02 § Engine, tick rule: "A stored temporary unblock that is already finished when a tick runs (which only a hand-edited or older file can hold) is removed on that tick, the tick returns `true`, and the ending is reported."
    @Test(arguments: [false, true])
    func aStoredFinishedRecordIsRemovedOnTheNextTickWhichAsksForASaveAndReportsTheEnding(rule: Bool) {
        let finished = TemporaryUnblock(startsIn: Countdown(remainingSeconds: 0, totalSeconds: 600), window: Countdown(remainingSeconds: 0, totalSeconds: 600))
        let state = PersistedState(blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], temporaryUnblock: rule ? nil : finished)], delaySeconds: 1800, blockedPaths: [BlockedPath(domain: "youtube.com", path: "/shorts", temporaryUnblock: rule ? finished : nil)])
        let engine = Engine(state: state, policy: temporaryPolicy)
        let events = recordEvents(of: engine)
        #expect(engine.tick(elapsed: 0.5) == true)
        #expect(engine.temporaryUnblock(of: "reddit.com") == nil && engine.temporaryUnblock(ofRule: "youtube.com", "/shorts") == nil)
        #expect(engine.site("reddit.com") != nil && engine.pathRule("youtube.com", "/shorts") != nil, "the site and the rule stay on the list")
        #expect(events.lines == [endedLine])
        #expect(engine.tick(elapsed: 0.5) == false, "and nothing is left to report")
        #expect(events.lines == [endedLine])
    }

    // A daemon restarted from the saved file continues a waiting temporary unblock from the remaining time that was saved (the engine holds no clock of its own).
    @Test func aStateRestoredFromTheSavedFileContinuesWhereTheEngineLeftOff() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: 600, start: 1800))
        _ = engine.tick(elapsed: 1000)
        let restored = Engine(state: engine.state, policy: temporaryPolicy)
        #expect(restored.temporaryUnblock(of: "reddit.com")?.startsIn.remainingSeconds == 800)
        #expect(restored.tick(elapsed: 799) == false)
        #expect(restored.temporaryUnblock(of: "reddit.com")?.isOpen == false)
        #expect(restored.tick(elapsed: 1) == true)
        #expect(restored.temporaryUnblock(of: "reddit.com")?.isOpen == true)
        #expect(restored.temporaryUnblock(of: "reddit.com")?.window.remainingSeconds == 600)
    }

    // A state saved while the site was open continues with the window it had left.
    @Test func aStateSavedWhileOpenContinuesWithTheRestOfTheWindow() {
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        openTemporaryUnblock(engine, window: 600)
        _ = engine.tick(elapsed: 250)
        let restored = Engine(state: engine.state, policy: temporaryPolicy)
        #expect(restored.temporaryUnblock(of: "reddit.com")?.window.remainingSeconds == 350)
        #expect(restored.tick(elapsed: 349) == false)
        #expect(restored.tick(elapsed: 1) == true)
        #expect(restored.temporaryUnblock(of: "reddit.com") == nil && restored.site("reddit.com") != nil)
    }
}

// MARK: an independent model of the tick rule

// A model of the tick rule written from the design text and not from the engine's code: take what the start wait can use off it, take the rest off the window,
// stop both at zero. All the times in the generated sequences are multiples of 1/8 second, which a Double holds exactly, so the model and the engine must agree to the last bit.
private struct TickModel {
    var starts: Double
    var window: Double
    var present = true

    // Advances by `elapsed` and says whether the unblock opened in this tick (and is still open) and whether it finished in this tick.
    mutating func advance(_ elapsed: Double) -> (opened: Bool, finished: Bool) {
        guard present else { return (false, false) }
        let waiting = starts > 0
        let used = min(elapsed, starts)
        starts -= used
        window = max(0, window - (elapsed - used))
        let finished = starts == 0 && window == 0
        if finished { present = false }
        return (waiting && starts == 0 && window > 0, finished)
    }
}

@Suite struct TemporaryUnblockTickModelTests {
    // Generated start waits, windows and tick sequences, for a site and for a rule. After every tick the engine's countdowns, its save flag, its events and its presence
    // on the list must equal the model's.
    @Test(arguments: Array(0..<30), [false, true])
    func theEngineAgreesWithTheModelOnGeneratedTickSequences(seed: Int, rule: Bool) {
        var generator = FuzzGenerator(seed: UInt64(seed) &+ 31_000)
        let start = Int.random(in: 2...40, using: &generator)
        let window = Int.random(in: 1...40, using: &generator)
        let subject = TickSubject(rule: rule, start: start, window: window)
        let events = recordEvents(of: subject.engine)
        var model = TickModel(starts: Double(start), window: Double(window))
        let steps = [0.125, 0.25, 0.5, 1, 1.5, 2, 3, 5, 8, 13, 21, 34, 100]
        var opened = 0
        var ended = 0
        for index in 0..<80 {
            let elapsed = steps.randomElement(using: &generator)!
            let expected = model.advance(elapsed)
            if expected.opened { opened += 1 }
            if expected.finished { ended += 1 }
            let saved = subject.engine.tick(elapsed: elapsed)
            let context = "seed \(seed), start \(start), window \(window), tick \(index) of \(elapsed) s"
            #expect(saved == (expected.opened || expected.finished), "\(context): save flag")
            #expect(subject.onList, "\(context): the entry must stay on the list")
            if model.present {
                #expect(subject.temp?.startsIn.remainingSeconds == model.starts, "\(context): start wait")
                #expect(subject.temp?.window.remainingSeconds == model.window, "\(context): window")
                #expect(subject.temp?.window.totalSeconds == Double(window) && subject.temp?.startsIn.totalSeconds == Double(start), "\(context): the lengths chosen never change")
            } else {
                #expect(subject.temp == nil, "\(context): finished, so removed")
            }
            #expect(events.lines.filter { $0 == openedLine }.count == opened && events.lines.filter { $0 == endedLine }.count == ended, "\(context): events \(events.lines)")
        }
        #expect(ended == 1, "seed \(seed): the generated ticks run far past the longest start plus window (80 s), so it ends exactly once")
    }
}

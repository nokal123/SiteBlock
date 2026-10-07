import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § Models and Protocol Types (Countdown) and
// 01-overview-and-data.md § Data Model (Countdown).

@Suite struct CountdownTests {
    @Test func initSetsRemainingAndTotalToTheGivenLength() {
        let countdown = Countdown(seconds: 1800)
        #expect(countdown.remainingSeconds == 1800)
        #expect(countdown.totalSeconds == 1800)
        #expect(!countdown.isFinished)
    }

    @Test func advanceSubtractsElapsedTimeAndKeepsTheTotal() {
        var countdown = Countdown(seconds: 30)
        countdown.advance(by: 10)
        #expect(countdown.remainingSeconds == 20)
        #expect(countdown.totalSeconds == 30)
        countdown.advance(by: 0.5)
        #expect(countdown.remainingSeconds == 19.5)
    }

    @Test func advanceStopsAtZeroAndNeverGoesNegative() {
        var exact = Countdown(seconds: 30)
        exact.advance(by: 30)
        #expect(exact.remainingSeconds == 0 && exact.isFinished)
        var over = Countdown(seconds: 30)
        over.advance(by: 31)
        #expect(over.remainingSeconds == 0 && over.isFinished)
        over.advance(by: 1000)
        #expect(over.remainingSeconds == 0)
        var huge = Countdown(seconds: 30)
        huge.advance(by: Double.greatestFiniteMagnitude)
        #expect(huge.remainingSeconds == 0 && huge.isFinished)
    }

    // "ignores negative or non-finite input so a bad clock reading cannot add time or finish a countdown early"
    @Test(arguments: [-1.0, -0.0, -1e9, -Double.infinity, Double.infinity, Double.nan, 0.0])
    func advanceIgnoresZeroNegativeAndNonFiniteElapsedValues(elapsed: Double) {
        var countdown = Countdown(remainingSeconds: 5, totalSeconds: 30)
        countdown.advance(by: elapsed)
        #expect(countdown == Countdown(remainingSeconds: 5, totalSeconds: 30))
    }

    @Test func isFinishedIsTrueExactlyWhenNoTimeIsLeft() {
        #expect(Countdown(remainingSeconds: 0, totalSeconds: 30).isFinished)
        #expect(Countdown(remainingSeconds: -1, totalSeconds: 30).isFinished)
        #expect(!Countdown(remainingSeconds: 0.001, totalSeconds: 30).isFinished)
        #expect(!Countdown(remainingSeconds: 1, totalSeconds: 30).isFinished)
    }

    // "remainingSeconds rounded up, so a countdown never shows 0 while it is still running"
    @Test(arguments: [(1800.0, 1800), (1799.5, 1800), (1799.0, 1799), (1.0, 1), (0.9, 1), (0.001, 1), (1.0001, 2), (29.5, 30), (59.999, 60), (0.0, 0), (172_800.0, 172_800)])
    func displaySecondsRoundsUpAndShowsZeroOnlyWhenFinished(remaining: Double, expected: Int) {
        #expect(Countdown(remainingSeconds: remaining, totalSeconds: 172_800).displaySeconds == expected)
    }

    @Test func displaySecondsIsZeroForAFinishedCountdownEvenWithANegativeStoredValue() {
        #expect(Countdown(remainingSeconds: -5, totalSeconds: 30).displaySeconds == 0)
    }

    @Test func displaySecondsDoesNotCrashOnAbsurdStoredValues() {
        #expect(Countdown(remainingSeconds: Double.greatestFiniteMagnitude, totalSeconds: 1).displaySeconds > 0)
        #expect(Countdown(remainingSeconds: .infinity, totalSeconds: 1).displaySeconds >= 0)
        #expect(Countdown(remainingSeconds: .nan, totalSeconds: 1).displaySeconds == 0)
    }

    @Test func aCountdownRoundTripsThroughJSONWithTheDesignsFieldNames() throws {
        let countdown = Countdown(remainingSeconds: 1234.5678901234567, totalSeconds: 1800)
        let data = try JSONCoding.encoder.encode(countdown)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Double])
        #expect(object == ["remainingSeconds": 1234.5678901234567, "totalSeconds": 1800])
        #expect(try JSONCoding.decoder.decode(Countdown.self, from: data) == countdown)
    }

    // Many small ticks add up the same as the whole: 1,800 ticks of 1 s finish a 1,800 s countdown on the last one.
    @Test func manySmallAdvancesAddUpToTheSameAsOneBigOne() {
        var countdown = Countdown(seconds: 1800)
        for _ in 0..<1799 { countdown.advance(by: 1) }
        #expect(countdown.remainingSeconds == 1 && !countdown.isFinished)
        countdown.advance(by: 1)
        #expect(countdown.isFinished)
    }
}

// 02-core-components.md § Models and Protocol Types (Countdown.advance): "A remainder below 1e-9 seconds (one nanosecond) is set to
// exactly 0. ... A remainder of 1e-6 seconds is still running."
@Suite struct CountdownToleranceTests {
    // Starting at 1 + remainder and advancing by 1 leaves the stated remainder. The subtraction is exact (both numbers are between 1 and 2),
    // so the only noise is the rounding of 1 + remainder itself, at most about 1.1e-16 s. The values nearest the 1e-9 line, 9e-10 and
    // 1.1e-9, are 1e-10 s from it, a thousand times more than that noise, so the design and not rounding decides them. 9e-10 is below a
    // nanosecond, so it counts as finished; 1.1e-9 is above it, so it is still running.
    @Test(arguments: [(1e-6, true), (1e-3, true), (0.5, true), (2e-9, true), (1.1e-9, true), (9e-10, false), (5.4e-10, false), (1e-10, false), (1e-12, false), (1e-15, false)])
    func aRemainderBelowOneNanosecondCountsAsFinishedAndAnyOtherRemainderIsStillRunning(remainder: Double, running: Bool) {
        var countdown = Countdown(remainingSeconds: 1 + remainder, totalSeconds: 100)
        countdown.advance(by: 1)
        #expect(countdown.isFinished == !running, "a remainder of \(remainder) s")
        if running {
            #expect(countdown.remainingSeconds > 0 && abs(countdown.remainingSeconds - remainder) < 1e-9)
            #expect(countdown.displaySeconds == 1, "a running countdown never shows 0")
        } else {
            #expect(countdown.remainingSeconds == 0, "the remainder must be set to exactly 0")
            #expect(countdown.displaySeconds == 0)
        }
    }

    // The line itself, with no rounding noise at all: the stored remainder is set directly and the advance is so small (1e-300 s, far below
    // the spacing of doubles near 1e-9) that the remainder after it is exactly the stored value. "A remainder below 1e-9 seconds ... is set to
    // exactly 0", so 9e-10 and the largest double under 1e-9 become 0, and 1e-9 itself and 1.1e-9 are not below the line and keep running.
    @Test(arguments: [(9e-10, true), (1e-9.nextDown, true), (1e-9, false), (1e-9.nextUp, false), (1.1e-9, false)])
    func aRemainderExactlyAtOrAboveOneNanosecondKeepsRunningAndOneBelowItFinishes(remainder: Double, finished: Bool) {
        var countdown = Countdown(remainingSeconds: remainder, totalSeconds: 100)
        countdown.advance(by: 1e-300)
        #expect(countdown.isFinished == finished, "a remainder of \(remainder) s")
        #expect(countdown.remainingSeconds == (finished ? 0 : remainder))
    }

    // The case the tolerance exists for: 18,000 ticks of 0.1 s on a 1,800 s countdown. In plain arithmetic the residue is not zero,
    // so the first #expect proves that the test would catch a missing tolerance; the countdown must still finish on the last tick.
    @Test func eighteenThousandTenthSecondAdvancesFinishAnEighteenHundredSecondCountdownOnTheLastOne() {
        var plain = 1800.0
        for _ in 0..<18_000 { plain -= 0.1 }
        #expect(plain > 0 && plain < 1e-9, "premise: plain subtraction leaves a tiny positive residue (\(plain))")
        var countdown = Countdown(seconds: 1800)
        for _ in 0..<17_999 { countdown.advance(by: 0.1) }
        #expect(!countdown.isFinished, "1,799.9 s have passed")
        countdown.advance(by: 0.1)
        #expect(countdown.isFinished && countdown.remainingSeconds == 0)
    }

    // The tolerance is about the remainder, not the elapsed time: a tiny elapsed value must still be subtracted in full.
    @Test func aTinyElapsedValueIsStillSubtractedWhenTheRemainderStaysLarge() {
        var countdown = Countdown(seconds: 10)
        countdown.advance(by: 1e-10)
        #expect(countdown.remainingSeconds == 10 - 1e-10)
        #expect(!countdown.isFinished)
    }

    // A stored remainder of 5e-10 s is not finished (isFinished only looks at remainingSeconds <= 0), but any positive advance leaves a
    // remainder below a nanosecond, which is set to exactly 0.
    @Test func aCountdownWithUnderANanosecondLeftFinishesOnAnyPositiveAdvance() {
        var countdown = Countdown(remainingSeconds: 5e-10, totalSeconds: 100)
        #expect(!countdown.isFinished, "stored values are taken as they are; only advance applies the tolerance")
        countdown.advance(by: 1e-300)
        #expect(countdown.isFinished && countdown.remainingSeconds == 0)
    }
}

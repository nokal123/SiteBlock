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

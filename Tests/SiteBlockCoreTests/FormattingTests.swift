import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § Formatting. Where the design gives only a few examples
// (the padding of the minutes figure under one hour), the tests check the value the text stands for, not an invented layout.

@Suite struct FormattingTests {
    // MARK: duration

    // The design's examples: 45 seconds, 1 minute, 30 minutes, 1 hour 5 minutes, 2 days 3 hours.
    @Test(arguments: [
        (45, "45 seconds"), (60, "1 minute"), (1800, "30 minutes"), (3900, "1 hour 5 minutes"), (183_600, "2 days 3 hours"),
    ])
    func durationMatchesTheDesignExamples(seconds: Int, expected: String) {
        #expect(Formatting.duration(seconds) == expected)
    }

    // Singular for exactly one, plural otherwise.
    @Test(arguments: [
        (0, "0 seconds"), (1, "1 second"), (2, "2 seconds"), (59, "59 seconds"), (61, "1 minute 1 second"), (119, "1 minute 59 seconds"),
        (120, "2 minutes"), (3599, "59 minutes 59 seconds"), (3600, "1 hour"), (7200, "2 hours"), (86_399, "23 hours 59 minutes"),
        (86_400, "1 day"), (172_800, "2 days"), (604_800, "7 days"), (90, "1 minute 30 seconds"), (900, "15 minutes"), (3660, "1 hour 1 minute"),
    ])
    func durationUsesSingularAndPluralAndTheTwoLargestUnits(seconds: Int, expected: String) {
        #expect(Formatting.duration(seconds) == expected)
    }

    // "at most the two largest non-zero units": a zero in between is skipped, and anything below the second unit is dropped.
    @Test(arguments: [
        (3665, "1 hour 1 minute"), (3601, "1 hour 1 second"), (90_061, "1 day 1 hour"), (86_460, "1 day 1 minute"), (86_401, "1 day 1 second"),
        (93_784, "1 day 2 hours"), (90_000, "1 day 1 hour"), (259_199, "2 days 23 hours"),
    ])
    func durationShowsOnlyTheTwoLargestNonZeroUnits(seconds: Int, expected: String) {
        #expect(Formatting.duration(seconds) == expected)
    }

    // The design says nothing about negative durations or absurdly large ones; the call must still return text and not trap.
    @Test(arguments: [-1, -3600, Int.max, Int.min + 1])
    func durationDoesNotCrashOnNegativeOrHugeValues(seconds: Int) {
        #expect(!Formatting.duration(seconds).isEmpty)
    }

    // MARK: clock

    // The design's examples: 29:41 under one hour, 1:05:09 under one day, 2d 03:04:05 otherwise.
    @Test(arguments: [(1781, "29:41"), (3909, "1:05:09"), (183_845, "2d 03:04:05")])
    func clockMatchesTheDesignExamples(seconds: Int, expected: String) {
        #expect(Formatting.clock(seconds) == expected)
    }

    // The boundaries between the three layouts.
    @Test(arguments: [
        (3599, "59:59"), (3600, "1:00:00"), (3601, "1:00:01"), (36_000, "10:00:00"), (86_399, "23:59:59"),
        (86_400, "1d 00:00:00"), (86_401, "1d 00:00:01"), (864_000, "10d 00:00:00"), (90_061, "1d 01:01:01"),
    ])
    func clockSwitchesLayoutAtOneHourAndAtOneDay(seconds: Int, expected: String) {
        #expect(Formatting.clock(seconds) == expected)
    }

    // The design's only under-one-hour example has a two-digit minute, so whether 5 minutes prints as "5:07" or "05:07"
    // is not fixed. The test checks the layout "minutes:two-digit seconds" and that the digits stand for the right time.
    @Test(arguments: [0, 1, 5, 9, 10, 59, 60, 65, 599, 600, 1781, 3599])
    func clockUnderAnHourIsMinutesColonTwoDigitSecondsForTheRightTime(seconds: Int) {
        let text = Formatting.clock(seconds)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 2, "\(text)")
        #expect(parts.last?.count == 2, "seconds are two digits in \(text)")
        let minutes = Int(parts.first ?? "")
        let secondsPart = Int(parts.last ?? "")
        #expect(minutes != nil && secondsPart != nil && minutes! * 60 + secondsPart! == seconds, "\(text) does not stand for \(seconds) seconds")
    }

    @Test func clockDoesNotCrashOnHugeValues() {
        #expect(!Formatting.clock(Int.max).isEmpty)
        #expect(!Formatting.clock(10_000_000_000).isEmpty)
    }

    // MARK: parseDuration

    // 02-core-components.md: accepts 90, 90s, 15m, 2h, 1d, and combinations such as 1h30m. Plain numbers are seconds.
    @Test(arguments: [
        ("90", 90), ("90s", 90), ("15m", 900), ("2h", 7200), ("1d", 86_400), ("1h30m", 5400), ("0", 0), ("1", 1), ("60", 60),
        ("0s", 0), ("30m", 1800), ("7d", 604_800), ("1d2h3m4s", 93_784), ("2h30m15s", 9015), ("1h1s", 3601), ("10m10s", 610),
        ("9223372036854775807", Int.max),
    ])
    func parseDurationAcceptsTheFormsInTheDesign(text: String, expected: Int) {
        #expect(Formatting.parseDuration(text) == expected)
    }

    @Test(arguments: [
        "", " ", "abc", "-5", "-5m", "+5m", "1.5h", "1,5h", "h", "m", "s", "d", "5x", "m15", "15mm", "1e3", "0x10", "1h-30m", "15 min", "15minutes",
        "\u{661}\u{665}m", "\u{FF11}\u{FF15}m", "\u{BD}h", "5\u{0}", "99999999999999999999", "99999999999999999999s", "1h2h3x",
    ])
    func parseDurationReturnsNilForAnythingElse(text: String) {
        #expect(Formatting.parseDuration(text) == nil, "\(text.debugDescription) should not parse")
    }

    // The design says nil for anything else; a value too big for an Int has no honest answer. The CLI feeds this user text,
    // so the only firm requirement is that it never traps: it returns nil, or a positive number that fits.
    @Test(arguments: ["9223372036854775807d", "9223372036854775807h", "9223372036854775807m", "106751991167301d", "9999999999999999d"])
    func parseDurationDoesNotCrashWhenTheTotalOverflowsAnInt(text: String) {
        let result = Formatting.parseDuration(text)
        #expect(result == nil || (result ?? 0) > 0, "\(text) gave \(String(describing: result))")
    }

    @Test(arguments: [1, 59, 60, 90, 3599, 3600, 86_400, 604_800, 1_000_000])
    func parseDurationReadsAPlainNumberBackToTheSameSeconds(seconds: Int) {
        #expect(Formatting.parseDuration(String(seconds)) == seconds)
        #expect(Formatting.parseDuration("\(seconds)s") == seconds)
    }

    @Test(arguments: [1, 2, 15, 90, 1440])
    func parseDurationMultipliesMinutesHoursAndDaysCorrectly(count: Int) {
        #expect(Formatting.parseDuration("\(count)m") == count * 60)
        #expect(Formatting.parseDuration("\(count)h") == count * 3600)
        #expect(Formatting.parseDuration("\(count)d") == count * 86_400)
    }

    // Spec gaps: the design does not say whether these combination edge cases parse.
    @Test(.disabled("spec gap: 02-core-components.md § Formatting does not say whether a trailing unit-less number ('1h30'), uppercase units ('15M'), surrounding spaces (' 15m '), or repeated and out-of-order units ('1m1m', '30m1h') are accepted"))
    func parseDurationHandlesUnspecifiedCombinationForms() {
        #expect(Formatting.parseDuration("1h30") == nil)
    }
}

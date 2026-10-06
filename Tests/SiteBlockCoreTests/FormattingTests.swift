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

    // These forms used to be spec gaps (a disabled test). 02-core-components.md § Formatting now says: "Surrounding whitespace is trimmed
    // and units are case-insensitive (15M works). Units may appear in any order, but each at most once."
    @Test(arguments: [
        (" 15m ", 900), ("15M", 900), ("\t15m\n", 900), ("  90  ", 90), ("90S", 90), ("1D", 86_400), ("2H", 7200), (" 1H30M ", 5400),
        ("30m1h", 5400), ("1s1d", 86_401), ("2m1h", 3720), ("4s3m2h1d", 93_784), ("1M1H", 3660),
    ])
    func parseDurationTrimsSurroundingWhitespaceIgnoresCaseAndAcceptsAnyOrderOfUnits(text: String, expected: Int) {
        #expect(Formatting.parseDuration(text) == expected, "\(text.debugDescription)")
    }

    // "Units may appear in any order, but each at most once. A number without a unit after a unit (1h30) ... return nil."
    @Test(arguments: ["1h30", "1h30m5", "5s5", "1m1m", "1h1h", "30m30m", "1H1h", "1m2s1m", "1d1d", "1s1s", "10m5m", "1h30m1"])
    func parseDurationRejectsARepeatedUnitAndATrailingNumberWithoutAUnit(text: String) {
        #expect(Formatting.parseDuration(text) == nil, "\(text.debugDescription) should not parse")
    }

    // The padding rule from 02-core-components.md § Formatting: "clock pads every unit after the first to two digits and leaves the first
    // unpadded: 5:03, 29:41, 1:05:09, 2d 03:04:05." This used to be a spec gap (only the layout was checked).
    @Test(arguments: [(0, "0:00"), (3, "0:03"), (9, "0:09"), (60, "1:00"), (65, "1:05"), (303, "5:03"), (599, "9:59"), (600, "10:00"), (1781, "29:41"), (3909, "1:05:09"), (3661, "1:01:01"), (183_845, "2d 03:04:05"), (90_061, "1d 01:01:01")])
    func clockPadsEveryUnitAfterTheFirstToTwoDigitsAndLeavesTheFirstUnpadded(seconds: Int, expected: String) {
        #expect(Formatting.clock(seconds) == expected)
    }
}

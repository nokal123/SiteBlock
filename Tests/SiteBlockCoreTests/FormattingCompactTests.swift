import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § Formatting (`compact`): "the short one-line form that `siteblock status` uses: `45s` under a minute. From a minute up
// it counts whole minutes, rounded up, and writes at most two units: `42m`, `1h`, `1h 30m`, `2d 3h`. When days are present the leftover minutes are dropped. A negative value reads as `0s`."
// Every figure below is worked out by hand from that text: round the seconds up to whole minutes first, then split the minutes into days (1440), hours (60) and minutes.

@Suite struct FormattingCompactTests {
    // Under a minute: the plain seconds.
    @Test(arguments: [(0, "0s"), (1, "1s"), (30, "30s"), (45, "45s"), (59, "59s")])
    func underAMinuteItIsTheSeconds(seconds: Int, expected: String) {
        #expect(Formatting.compact(seconds) == expected)
    }

    // From a minute up the seconds are rounded UP to whole minutes, so a running countdown never shows less than is left.
    @Test(arguments: [(60, "1m"), (61, "2m"), (90, "2m"), (119, "2m"), (120, "2m"), (121, "3m"), (2461, "42m"), (2520, "42m"), (2521, "43m"), (3480, "58m"), (3540, "59m")])
    func fromAMinuteUpItCountsWholeMinutesRoundedUp(seconds: Int, expected: String) {
        #expect(Formatting.compact(seconds) == expected)
    }

    // Rounding up can carry into the next unit: 59 minutes and 1 second is 60 minutes, which is "1h", not "59m" and not "60m".
    @Test(arguments: [(3541, "1h"), (3599, "1h"), (7141, "2h"), (86_341, "1d"), (86_399, "1d"), (187_199, "2d 4h"), (259_170, "3d")])
    func roundingUpCarriesIntoTheNextUnit(seconds: Int, expected: String) {
        #expect(Formatting.compact(seconds) == expected)
    }

    // Hours with minutes: at most two units, and a zero unit is not written ("1h", not "1h 0m").
    @Test(arguments: [(3600, "1h"), (3601, "1h 1m"), (3660, "1h 1m"), (3661, "1h 2m"), (5400, "1h 30m"), (5401, "1h 31m"), (7140, "1h 59m"), (7200, "2h"), (86_340, "23h 59m"), (36_000, "10h")])
    func hoursAndMinutes(seconds: Int, expected: String) {
        #expect(Formatting.compact(seconds) == expected)
    }

    // Days with hours: "When days are present the leftover minutes are dropped", and a zero hours unit is not written.
    @Test(arguments: [(86_400, "1d"), (86_401, "1d"), (86_460, "1d"), (90_000, "1d 1h"), (90_060, "1d 1h"), (169_200, "1d 23h"), (172_800, "2d"), (172_801, "2d"), (183_600, "2d 3h"), (183_660, "2d 3h"), (184_800, "2d 3h"), (188_400, "2d 4h"), (604_800, "7d")])
    func daysAndHoursDropTheLeftoverMinutes(seconds: Int, expected: String) {
        #expect(Formatting.compact(seconds) == expected)
    }

    // The examples the design names for the status lines: "opens in 42m, for 1h" and "blocks again in 37m".
    @Test func theDesignsExamples() {
        #expect(Formatting.compact(42 * 60) == "42m")
        #expect(Formatting.compact(3600) == "1h")
        #expect(Formatting.compact(37 * 60) == "37m")
        #expect(Formatting.compact(5400) == "1h 30m")
        #expect(Formatting.compact(2 * 86_400 + 3 * 3600) == "2d 3h")
    }

    // "A negative value reads as `0s`."
    @Test(arguments: [-1, -45, -60, -3600, -86_400, Int.min + 1, Int.min])
    func aNegativeValueReadsAsZeroSeconds(seconds: Int) {
        #expect(Formatting.compact(seconds) == "0s")
    }

    // The largest number must not trap (nothing overflows while the minutes are rounded up), and it is written in days.
    @Test func theLargestIntegerDoesNotCrashAndIsWrittenInDays() {
        let text = Formatting.compact(Int.max)
        #expect(!text.isEmpty && text.contains("d"), "got \(text)")
        #expect(!Formatting.compact(Int.max - 1).isEmpty)
    }

    // An independent reading of the rule, written separately from the library: round up to minutes, then split. Compared at every second up to a bit over two days and at spaced values beyond.
    private func reference(_ seconds: Int) -> String {
        if seconds <= 0 { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = (seconds + 59) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h" }
        return "\(rest)m"
    }

    @Test func compactAgreesWithAnIndependentReadingOfTheRuleForEverySecondUpToAboutTwoDays() {
        for seconds in -100...180_000 { #expect(Formatting.compact(seconds) == reference(seconds), "\(seconds) s") }
        for seconds in stride(from: 180_001, through: 40_000_000, by: 997) { #expect(Formatting.compact(seconds) == reference(seconds), "\(seconds) s") }
    }

    // What every result looks like, whatever the input: seconds alone, or one of the unit pairs, never a unit of zero (except the plain "0s"), hours below 24 and minutes below 60.
    @Test func everyResultHasTheDesignsShape() throws {
        let shape = try Regex(#"^(?:0s|(?:[1-9]|[1-5][0-9])s|[1-9][0-9]*d(?: (?:[1-9]|1[0-9]|2[0-3])h)?|(?:[1-9]|1[0-9]|2[0-3])h(?: (?:[1-9]|[1-5][0-9])m)?|(?:[1-9]|[1-5][0-9])m)$"#)
        for seconds in stride(from: 0, through: 1_000_000, by: 7) {
            let text = Formatting.compact(seconds)
            #expect(text.wholeMatch(of: shape) != nil, "\(seconds) s gave \(text)")
        }
    }

    // A countdown shown with this form never grows as time passes: ticking down one second at a time, the shown number of minutes never rises.
    @Test func aCountdownNeverShowsMoreTimeLaterThanEarlier() {
        func minutes(_ text: String) -> Int {
            var total = 0
            for part in text.split(separator: " ") {
                guard let number = Int(part.dropLast()) else { continue }
                switch part.last {
                case "d": total += number * 1440
                case "h": total += number * 60
                case "m": total += number
                default: total += (number > 0 ? 1 : 0)
                }
            }
            return total
        }
        var previous = minutes(Formatting.compact(200_000))
        for seconds in stride(from: 199_999, through: 0, by: -1) {
            let now = minutes(Formatting.compact(seconds))
            #expect(now <= previous, "at \(seconds) s the form shows more than one second earlier")
            previous = now
        }
    }
}

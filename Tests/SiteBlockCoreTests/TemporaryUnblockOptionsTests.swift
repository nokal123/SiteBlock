import Foundation
import Testing
import SiteBlockCore

// The choices of the "For a while" form. Expected values come from Design Plans/02-core-components.md § TemporaryUnblockOptions: window choices 900, 1800, 3600, 7200
// and 14400 seconds; start choices are the delay itself and then each of 2, 3, 4, 6, 8, 12 and 24 hours that is LONGER than the delay; `label` writes a whole number of
// hours from 1 to 24 in hours and any other length with `Formatting.duration`. Every number is typed out in seconds from the hours the design names.

private let hour = 3600
// The seven extra start choices, in seconds: 2, 3, 4, 6, 8, 12 and 24 hours.
private let extraHours = [2 * hour, 3 * hour, 4 * hour, 6 * hour, 8 * hour, 12 * hour, 24 * hour]

@Suite struct TemporaryUnblockWindowChoiceTests {
    // The five windows the form offers: 15 minutes, 30 minutes, 1, 2 and 4 hours, in this order.
    @Test func theWindowChoicesAreExactlyTheFiveInTheDesignInOrder() {
        #expect(TemporaryUnblockOptions.windowChoices == [900, 1800, 3600, 7200, 14_400])
        #expect(TemporaryUnblockOptions.windowChoices == [15 * 60, 30 * 60, 1 * hour, 2 * hour, 4 * hour])
    }

    // "All of them lie inside the daemon's range of 5 minutes to 4 hours": the form can never offer a window the daemon would refuse. Checked against the real engine too.
    @Test(arguments: TemporaryUnblockOptions.windowChoices)
    func everyWindowChoiceIsInsideTheDaemonsRangeAndTheDaemonAcceptsIt(window: Int) {
        #expect((300...14_400).contains(window))
        let engine = makeEngine(blocking: ["reddit.com"], policy: temporaryPolicy)
        expectSuccess(engine.temporarily("reddit.com", seconds: window, start: nil))
        #expect(engine.temporaryUnblock(of: "reddit.com")?.window.totalSeconds == Double(window))
    }

    @Test func theWindowChoicesAreIncreasingWithNoDuplicates() {
        let choices = TemporaryUnblockOptions.windowChoices
        #expect(zip(choices, choices.dropFirst()).allSatisfy { $0 < $1 })
    }
}

@Suite struct TemporaryUnblockStartChoiceTests {
    // 05 § Unit Tests: "a delay of 1 hour offers itself and all seven".
    @Test func aDelayOfOneHourOffersItselfAndAllSeven() {
        #expect(TemporaryUnblockOptions.startChoices(delaySeconds: 3600) == [3600, 7200, 10_800, 14_400, 21_600, 28_800, 43_200, 86_400])
    }

    // The default delay of 30 minutes is shorter than all seven, so it offers itself and all seven.
    @Test func theDefaultDelayOfThirtyMinutesOffersItselfAndAllSeven() {
        #expect(TemporaryUnblockOptions.startChoices(delaySeconds: 1800) == [1800] + extraHours)
    }

    // 05 § Unit Tests: "a delay of 5 hours offers itself and then 6, 8, 12 and 24".
    @Test func aDelayOfFiveHoursOffersItselfAndThenSixEightTwelveAndTwentyFour() {
        #expect(TemporaryUnblockOptions.startChoices(delaySeconds: 18_000) == [18_000, 21_600, 28_800, 43_200, 86_400])
    }

    // 05 § Unit Tests: "a delay of 24 hours or more offers only itself". 7 days is the longest delay.
    @Test(arguments: [86_400, 86_401, 100_000, 172_800, 604_800])
    func aDelayOfTwentyFourHoursOrMoreOffersOnlyItself(delay: Int) {
        #expect(TemporaryUnblockOptions.startChoices(delaySeconds: delay) == [delay])
    }

    // "that is longer than delaySeconds": a delay equal to one of the hour choices is not listed twice, and one second below or above it changes the list by exactly that entry.
    @Test(arguments: extraHours)
    func aDelayExactlyOnAnHourChoiceListsThatChoiceOnce(delay: Int) {
        let choices = TemporaryUnblockOptions.startChoices(delaySeconds: delay)
        #expect(choices == [delay] + extraHours.filter { $0 > delay })
        #expect(choices.filter { $0 == delay }.count == 1)
        let below = TemporaryUnblockOptions.startChoices(delaySeconds: delay - 1)
        #expect(below.first == delay - 1 && below.contains(delay), "one second below the choice, the choice itself is longer than the delay, so it is offered")
        let above = TemporaryUnblockOptions.startChoices(delaySeconds: delay + 1)
        #expect(above.first == delay + 1 && !above.contains(delay), "one second above, the choice is shorter than the delay and is not offered")
    }

    // The shortest delay the daemon allows is 60 seconds.
    @Test func theShortestDelayOffersItselfAndAllSeven() {
        #expect(TemporaryUnblockOptions.startChoices(delaySeconds: 60) == [60] + extraHours)
    }

    // The design's table, spelled out for a spread of delays.
    @Test(arguments: [
        (60, 8), (300, 8), (1800, 8), (3600, 8), (7199, 8), (7200, 7), (7201, 7), (10_800, 6), (14_399, 6), (14_400, 5), (21_599, 5), (21_600, 4), (28_799, 4), (28_800, 3),
        (43_199, 3), (43_200, 2), (86_399, 2), (86_400, 1), (604_800, 1),
    ])
    func theNumberOfChoicesFallsAsTheDelayPassesEachHourChoice(delay: Int, count: Int) {
        #expect(TemporaryUnblockOptions.startChoices(delaySeconds: delay).count == count, "delay \(delay)")
    }

    // The properties the form relies on, for every delay between 60 seconds and 7 days in steps that cross every boundary: the soonest choice is the delay itself, the list is strictly
    // increasing, and every choice is inside the daemon's start wait range (the delay up to 7 days), so the daemon accepts what the form offers.
    @Test func everyListStartsWithTheDelayIsStrictlyIncreasingAndInsideTheDaemonsRange() {
        var delays = Set([60, 61, 3599, 3600, 3601, 86_399, 86_400, 86_401, 604_799, 604_800])
        delays.formUnion(stride(from: 60, through: 604_800, by: 1789))
        for delay in delays.sorted() {
            let choices = TemporaryUnblockOptions.startChoices(delaySeconds: delay)
            #expect(choices.first == delay, "delay \(delay)")
            #expect(zip(choices, choices.dropFirst()).allSatisfy { $0 < $1 }, "delay \(delay): \(choices)")
            #expect(choices.allSatisfy { $0 >= delay && $0 <= 604_800 }, "delay \(delay): \(choices)")
            #expect(Set(choices.dropFirst()).isSubset(of: Set(extraHours)), "delay \(delay): only the design's hour choices follow the delay")
        }
    }

    // The daemon accepts every start wait the form offers, for a spread of delays: tested against the real engine, one fresh engine per request.
    @Test(arguments: [60, 1800, 3600, 7200, 18_000, 86_400, 604_800])
    func theDaemonAcceptsEveryWindowAndStartWaitTheFormOffers(delay: Int) throws {
        let hash = try PasswordHasher.make(password: rightPassword, iterations: 1000)
        for start in TemporaryUnblockOptions.startChoices(delaySeconds: delay) {
            for window in TemporaryUnblockOptions.windowChoices {
                let state = PersistedState(passwordHash: hash, blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com"])], delaySeconds: delay)
                let engine = Engine(state: state, policy: temporaryPolicy)
                let response = engine.temporarily("reddit.com", seconds: window, start: start)
                #expect(response.ok, "delay \(delay), start \(start), window \(window): \(response.errorCode.map(\.rawValue) ?? "")")
            }
        }
    }
}

@Suite struct TemporaryUnblockLabelTests {
    // "A whole number of hours from 1 to 24 is written in hours (\"1 hour\", \"24 hours\")": all twenty-four of them, singular for one.
    @Test(arguments: Array(1...24))
    func aWholeNumberOfHoursFromOneToTwentyFourIsWrittenInHours(hours: Int) {
        #expect(TemporaryUnblockOptions.label(forSeconds: hours * hour) == (hours == 1 ? "1 hour" : "\(hours) hours"))
    }

    // The explicit examples from the design.
    @Test(arguments: [(3600, "1 hour"), (86_400, "24 hours"), (7200, "2 hours"), (43_200, "12 hours")])
    func theDesignsExamplesOfHourLabels(seconds: Int, expected: String) {
        #expect(TemporaryUnblockOptions.label(forSeconds: seconds) == expected)
    }

    // "any other length is written by Formatting.duration": minutes, mixed lengths, more than 24 hours, and a length that is almost an hour or just over one.
    @Test(arguments: [
        (900, "15 minutes"), (1800, "30 minutes"), (60, "1 minute"), (300, "5 minutes"), (45, "45 seconds"), (5400, "1 hour 30 minutes"), (3599, "59 minutes 59 seconds"),
        (3601, "1 hour 1 second"), (3660, "1 hour 1 minute"), (90_000, "1 day 1 hour"), (86_401, "1 day 1 second"), (172_800, "2 days"), (604_800, "7 days"), (97_200, "1 day 3 hours"),
    ])
    func anyOtherLengthIsWrittenByFormattingDuration(seconds: Int, expected: String) {
        #expect(TemporaryUnblockOptions.label(forSeconds: seconds) == expected)
        #expect(TemporaryUnblockOptions.label(forSeconds: seconds) == Formatting.duration(seconds))
    }

    // The window choices and the start choices all get a label, and the labels of the choices a person picks between are all different.
    @Test func everyChoiceHasADistinctLabel() {
        let windows = TemporaryUnblockOptions.windowChoices.map { TemporaryUnblockOptions.label(forSeconds: $0) }
        #expect(windows == ["15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours"])
        #expect(Set(windows).count == windows.count)
        let starts = TemporaryUnblockOptions.startChoices(delaySeconds: 1800).map { TemporaryUnblockOptions.label(forSeconds: $0) }
        #expect(starts == ["30 minutes", "2 hours", "3 hours", "4 hours", "6 hours", "8 hours", "12 hours", "24 hours"])
        #expect(Set(starts).count == starts.count)
    }

    // 02 § TemporaryUnblockOptions: "It is only called with the positive lengths the form offers and the daemon reports", so zero and negative lengths are not defined and are not tested. The largest length must still not crash.
    @Test(arguments: [1, 59, 3599, 86_401, Int.max])
    func labelDoesNotCrashOnPositiveExtremes(seconds: Int) {
        #expect(!TemporaryUnblockOptions.label(forSeconds: seconds).isEmpty)
    }
}

// MARK: scheduleText and clockPhrase

// A Gregorian calendar fixed to one time zone and the en_US locale, so the words below do not depend on the Mac running the tests.
private struct SetupFailure: Error {}
private func calendar(_ zone: String) throws -> Calendar {
    guard let timeZone = TimeZone(identifier: zone) else { throw SetupFailure() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}
private let american = Locale(identifier: "en_US")
// A moment given by its clock time in a zone's calendar.
private func moment(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, second: Int = 0) throws -> Date {
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { throw SetupFailure() }
    return date
}
// Recent macOS writes the space before AM or PM as a narrow no-break space (U+202F); the design writes an ordinary space ("3:42 PM"), so both are compared as an ordinary space.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

// Expected words come from 02-core-components.md § TemporaryUnblockOptions (`scheduleText`, `clockPhrase`): "Opens at 3:42 PM, blocks again at 4:42 PM." once a window is chosen, "Opens at 3:42 PM." before that; "at 3:42 PM" on the same day,
// "tomorrow at 3:42 PM" on the next day, "Tue, Oct 21 at 3:42 PM" after that; days are judged in the calendar's time zone. 2026-10-19 is a Monday.
@Suite struct TemporaryUnblockScheduleTextTests {
    private func text(start: Int, window: Int?, now: Date, calendar: Calendar) -> String {
        plain(TemporaryUnblockOptions.scheduleText(startSeconds: start, windowSeconds: window, now: now, calendar: calendar, locale: american))
    }

    private func phrase(_ date: Date, now: Date, calendar: Calendar, locale: Locale = american) -> String {
        plain(TemporaryUnblockOptions.clockPhrase(date, now: now, calendar: calendar, locale: locale))
    }

    @Test func aWindowOnTheSameDayGivesBothTimes() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 10, 12)
        #expect(text(start: 5400, window: 3600, now: now, calendar: newYork) == "Opens at 11:42 AM, blocks again at 12:42 PM.")
    }

    @Test func beforeAWindowIsChosenOnlyTheOpeningTimeIsGiven() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 10, 12)
        #expect(text(start: 5400, window: nil, now: now, calendar: newYork) == "Opens at 11:42 AM.")
        #expect(text(start: 0, window: nil, now: now, calendar: newYork) == "Opens at 10:12 AM.")
    }

    @Test func anOpeningOnTheNextDayIsTomorrow() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 22, 30)
        #expect(text(start: 7200, window: 3600, now: now, calendar: newYork) == "Opens tomorrow at 12:30 AM, blocks again tomorrow at 1:30 AM.")
        #expect(text(start: 7200, window: nil, now: now, calendar: newYork) == "Opens tomorrow at 12:30 AM.")
    }

    // "A time just after midnight counts as tomorrow": 12:10 AM is 20 minutes from 11:50 PM, and it is the next calendar day.
    @Test func aTimeJustAfterMidnightCountsAsTomorrowAndOneJustBeforeDoesNot() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 23, 50)
        #expect(text(start: 1200, window: nil, now: now, calendar: newYork) == "Opens tomorrow at 12:10 AM.")
        #expect(text(start: 540, window: nil, now: now, calendar: newYork) == "Opens at 11:59 PM.")
        #expect(text(start: 600, window: nil, now: now, calendar: newYork) == "Opens tomorrow at 12:00 AM.")
    }

    // 05: "a window that ends on the next day": the opening is today, the closing is tomorrow.
    @Test func aWindowThatEndsOnTheNextDayWritesTomorrowOnlyForTheClosing() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 22, 30)
        #expect(text(start: 3600, window: 7200, now: now, calendar: newYork) == "Opens at 11:30 PM, blocks again tomorrow at 1:30 AM.")
    }

    @Test func laterDaysUseTheWeekdayAndTheDate() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 10, 12)
        #expect(text(start: 2 * 86_400, window: nil, now: now, calendar: newYork) == "Opens Wed, Oct 21 at 10:12 AM.")
        #expect(text(start: 3 * 86_400 + 3600, window: 3600, now: now, calendar: newYork) == "Opens Thu, Oct 22 at 11:12 AM, blocks again Thu, Oct 22 at 12:12 PM.")
        #expect(text(start: 7 * 86_400, window: nil, now: now, calendar: newYork) == "Opens Mon, Oct 26 at 10:12 AM.")
        #expect(text(start: 86_400, window: nil, now: now, calendar: newYork) == "Opens tomorrow at 10:12 AM.")
    }

    // The date is the date in the calendar's time zone, not the date on the machine: 9:30 PM in New York is already the next morning in Israel or UTC, and 1:30 AM in Auckland is still the evening before in the Americas and Europe.
    @Test func theWrittenDateIsTheDateInTheCalendarsTimeZone() throws {
        let newYork = try calendar("America/New_York")
        let nowNewYork = try moment(newYork, 2026, 10, 19, 10, 12)
        #expect(text(start: 3 * 86_400 + 11 * 3600 + 18 * 60, window: nil, now: nowNewYork, calendar: newYork) == "Opens Thu, Oct 22 at 9:30 PM.")
        let auckland = try calendar("Pacific/Auckland")
        let nowAuckland = try moment(auckland, 2026, 10, 19, 10, 12)
        #expect(text(start: 2 * 86_400 + 15 * 3600 + 18 * 60, window: nil, now: nowAuckland, calendar: auckland) == "Opens Thu, Oct 22 at 1:30 AM.")
    }

    // Across a month and a year end the date still reads with the month name.
    @Test func theDateCarriesTheMonthAcrossMonthAndYearEnds() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 12, 30, 9, 5)
        #expect(text(start: 3 * 86_400, window: nil, now: now, calendar: newYork) == "Opens Sat, Jan 2 at 9:05 AM.")
    }

    // "Days are judged in the calendar's time zone": the same instant is the same day in New York and the next day in Auckland.
    @Test func daysAndTimesAreJudgedInTheCalendarsTimeZone() throws {
        let newYork = try calendar("America/New_York")
        let auckland = try calendar("Pacific/Auckland")
        let now = try moment(try calendar("UTC"), 2026, 10, 19, 10, 0)
        #expect(text(start: 7200, window: nil, now: now, calendar: newYork) == "Opens at 8:00 AM.")
        #expect(text(start: 7200, window: nil, now: now, calendar: auckland) == "Opens tomorrow at 1:00 AM.")
    }

    // The 25-hour day when clocks go back (2026-11-01 in New York): 24 hours after 12:30 AM is 11:30 PM the same day, not tomorrow.
    @Test func aTwentyFourHourStepOnAFallBackDayStaysOnTheSameDay() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 11, 1, 0, 30)
        #expect(text(start: 86_400, window: nil, now: now, calendar: newYork) == "Opens at 11:30 PM.")
        // The day before, the next day starts after 24 hours as usual.
        let eve = try moment(newYork, 2026, 10, 31, 23, 0)
        #expect(text(start: 3 * 3600, window: nil, now: eve, calendar: newYork) == "Opens tomorrow at 1:00 AM.")
    }

    // The 23-hour day when clocks go forward (2026-03-08): 24 hours after 12:30 AM is 1:30 AM on the next day.
    @Test func aTwentyFourHourStepOnASpringForwardDayIsTomorrow() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 3, 8, 0, 30)
        #expect(text(start: 86_400, window: nil, now: now, calendar: newYork) == "Opens tomorrow at 1:30 AM.")
    }

    // The seconds of `now` count: 10:12:59 plus one second is 10:13.
    @Test func theOpeningIsCountedFromTheExactMoment() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 10, 12, second: 59)
        #expect(text(start: 0, window: nil, now: now, calendar: newYork) == "Opens at 10:12 AM.")
        #expect(text(start: 1, window: nil, now: now, calendar: newYork) == "Opens at 10:13 AM.")
    }

    @Test func clockPhraseGivesTheThreeFormsDirectly() throws {
        let newYork = try calendar("America/New_York")
        let now = try moment(newYork, 2026, 10, 19, 15, 0)
        #expect(phrase(try moment(newYork, 2026, 10, 19, 15, 42), now: now, calendar: newYork) == "at 3:42 PM")
        #expect(phrase(try moment(newYork, 2026, 10, 19, 8, 5), now: now, calendar: newYork) == "at 8:05 AM", "earlier the same day is still the same day")
        #expect(phrase(try moment(newYork, 2026, 10, 20, 15, 42), now: now, calendar: newYork) == "tomorrow at 3:42 PM")
        #expect(phrase(try moment(newYork, 2026, 10, 21, 15, 42), now: now, calendar: newYork) == "Wed, Oct 21 at 3:42 PM")
        #expect(phrase(try moment(newYork, 2026, 10, 18, 15, 42), now: now, calendar: newYork) == "Sun, Oct 18 at 3:42 PM", "yesterday is neither today nor tomorrow, so it gets the date")
    }

    // Times are written in the given locale: a 24-hour locale has no AM or PM.
    @Test func timesFollowTheGivenLocale() throws {
        let berlin = try calendar("Europe/Berlin")
        let now = try moment(berlin, 2026, 10, 19, 10, 0)
        let evening = try moment(berlin, 2026, 10, 19, 15, 42)
        let german = phrase(evening, now: now, calendar: berlin, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("15:42") && !german.contains("PM"), "got: \(german)")
        #expect(phrase(evening, now: now, calendar: berlin) == "at 3:42 PM")
    }
}

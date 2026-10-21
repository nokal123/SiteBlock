using System.Globalization;

namespace SiteBlock.Core;

/// <summary>
/// The fixed choices and the wording rules behind the app's "For a while" unblock form. They live in the library, not in the view, so they can be tested without a window.
/// Nothing here talks to the service; the service applies its own limits again when the request arrives.
/// </summary>
public static class TemporaryUnblockOptions
{
    /// <summary>How long a site can be offered to stay open, in seconds: 15 minutes, 30 minutes, 1 hour, 2 hours and 4 hours. All of them sit inside the service's range of 5 minutes to 4 hours.</summary>
    public static IReadOnlyList<int> WindowChoices { get; } = Array.AsReadOnly(new[] { 900, 1_800, 3_600, 7_200, 14_400 });

    /// <summary>The waits before a site opens, in seconds, that are offered besides the unblock delay itself: 2, 3, 4, 6, 8, 12 and 24 hours.</summary>
    private static readonly int[] ExtraStartChoices = [2 * 3_600, 3 * 3_600, 4 * 3_600, 6 * 3_600, 8 * 3_600, 12 * 3_600, 24 * 3_600];

    /// <summary>
    /// The waits before a site opens that the form offers, shortest first: the unblock delay itself (the soonest the service allows) and every one of 2, 3, 4, 6, 8, 12 and 24 hours that is longer than the delay.
    /// With a delay of 24 hours or more, only the delay is offered.
    /// </summary>
    public static IReadOnlyList<int> StartChoices(int delaySeconds)
    {
        var choices = new List<int> { delaySeconds };
        choices.AddRange(ExtraStartChoices.Where(extra => extra > delaySeconds));
        return choices;
    }

    /// <summary>
    /// Names a length of time for the pickers and the row. A whole number of hours from 1 to 24 is written in hours ("24 hours", not "1 day"), because the choices are written that way;
    /// anything else uses the usual wording ("15 minutes", "1 hour 30 minutes", "2 days").
    /// </summary>
    public static string Label(int seconds)
    {
        if (seconds >= 3_600 && seconds <= 86_400 && seconds % 3_600 == 0)
        {
            int hours = seconds / 3_600;
            return $"{hours} {(hours == 1 ? "hour" : "hours")}";
        }
        return Formatting.Duration(seconds);
    }

    /// <summary>
    /// The gray line under the form's pickers: "Opens at 3:42 PM, blocks again at 4:42 PM." once a window is chosen, and only "Opens at 3:42 PM." before that.
    /// The times are <paramref name="startSeconds"/> (and then <paramref name="windowSeconds"/> more) after <paramref name="now"/>, written in the given time zone and culture.
    /// </summary>
    public static string ScheduleText(int startSeconds, int? windowSeconds, DateTimeOffset now, TimeZoneInfo zone, CultureInfo culture)
    {
        DateTimeOffset opens = now.AddSeconds(startSeconds);
        if (windowSeconds is null) return $"Opens {ClockPhrase(opens, now, zone, culture)}.";
        DateTimeOffset closes = opens.AddSeconds(windowSeconds.Value);
        return $"Opens {ClockPhrase(opens, now, zone, culture)}, blocks again {ClockPhrase(closes, now, zone, culture)}.";
    }

    /// <summary>
    /// Words for a moment in time: "at 3:42 PM" on the same day as <paramref name="now"/>, "tomorrow at 3:42 PM" on the next day, and the weekday and date after that ("Tue, Oct 21 at 3:42 PM").
    /// "Same day" is judged in the given time zone, so a time just after midnight there counts as tomorrow.
    /// </summary>
    public static string ClockPhrase(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone, CultureInfo culture)
    {
        // Convert both moments into the zone first, so the day numbers below are the zone's calendar days and not the machine's.
        DateTimeOffset local = TimeZoneInfo.ConvertTime(date, zone);
        DateTimeOffset localNow = TimeZoneInfo.ConvertTime(now, zone);
        string time = local.ToString(Single(culture.DateTimeFormat.ShortTimePattern), culture);
        string result;
        if (local.Date == localNow.Date) result = $"at {time}";
        else if (local.Date == localNow.Date.AddDays(1)) result = $"tomorrow at {time}";
        else result = $"{local.ToString(Single(WeekdayDatePattern(culture)), culture)} at {time}";
        // Newer ICU data puts a narrow no-break space (U+202F) before "PM" and some cultures use U+00A0; plain spaces keep the text predictable.
        return result.Replace(' ', ' ').Replace(' ', ' ');
    }

    /// <summary>The pattern for "weekday, month day": "ddd, MMM d" for en-US, and for other cultures the culture's own month-and-day order with the weekday in front and the month shortened.</summary>
    private static string WeekdayDatePattern(CultureInfo culture)
    {
        if (culture.Name is "en-US" or "en") return "ddd, MMM d";
        return "ddd " + culture.DateTimeFormat.MonthDayPattern.Replace("MMMM", "MMM");
    }

    /// <summary>A one-letter pattern would be read as a standard format ("t" or "d"), so a "%" in front makes it a custom one-letter pattern.</summary>
    private static string Single(string pattern) => pattern.Length == 1 ? "%" + pattern : pattern;
}

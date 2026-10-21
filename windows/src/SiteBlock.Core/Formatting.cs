using System.Globalization;
using System.Text;

namespace SiteBlock.Core;

/// <summary>Shared human-readable text for durations, so the CLI and the app say the same thing. Every method gives the same answer as the Swift <c>Formatting</c> on every input.</summary>
public static class Formatting
{
    /// <summary>
    /// Describes a length of time in words using at most the two largest non-zero units, for example "45 seconds", "1 hour 5 minutes" or "2 days 3 hours".
    /// A negative length counts as zero, which reads "0 seconds".
    /// </summary>
    public static string Duration(int seconds)
    {
        int remaining = Math.Max(0, seconds);
        (string Name, int Size)[] units = [("day", 86_400), ("hour", 3_600), ("minute", 60), ("second", 1)];
        var parts = new List<string>();
        foreach (var (name, size) in units)
        {
            int count = remaining / size;
            remaining %= size;
            if (count > 0) parts.Add($"{count.ToString(CultureInfo.InvariantCulture)} {name}{(count == 1 ? "" : "s")}");
            if (parts.Count == 2) break;
        }
        return parts.Count == 0 ? "0 seconds" : string.Join(" ", parts);
    }

    /// <summary>
    /// Describes a length of time in the short form used on one line of text: "45s" under a minute, and from a minute up whole minutes rounded up with the larger units folded in, at most two units, such as "42m", "1h", "1h 30m" or "2d 3h".
    /// Rounding up keeps a running countdown from showing less time than is left.
    /// </summary>
    public static string Compact(int seconds)
    {
        int total = Math.Max(0, seconds);
        if (total < 60) return $"{total.ToString(CultureInfo.InvariantCulture)}s";
        // Whole minutes, rounded up; days and hours are then split out of them (so 3,599 seconds reads "1h", not "59m 59s").
        int minutes = total / 60 + (total % 60 > 0 ? 1 : 0);
        int days = minutes / 1_440;
        int hours = (minutes % 1_440) / 60;
        int rest = minutes % 60;
        if (days > 0) return hours > 0 ? $"{days}d {hours}h" : $"{days}d";
        if (hours > 0) return rest > 0 ? $"{hours}h {rest}m" : $"{hours}h";
        return $"{rest}m";
    }

    /// <summary>Describes a length of time as a running clock: "29:41" under an hour, "1:05:09" under a day, "2d 03:04:05" from a day up. The leading unit is not padded.</summary>
    public static string Clock(int seconds)
    {
        int total = Math.Max(0, seconds);
        int days = total / 86_400;
        int hours = (total % 86_400) / 3_600;
        int minutes = (total % 3_600) / 60;
        int secs = total % 60;
        if (total >= 86_400) return $"{days}d {TwoDigits(hours)}:{TwoDigits(minutes)}:{TwoDigits(secs)}";
        if (total >= 3_600) return $"{hours}:{TwoDigits(minutes)}:{TwoDigits(secs)}";
        return $"{minutes}:{TwoDigits(secs)}";
    }

    /// <summary>Pads a number to at least two digits.</summary>
    private static string TwoDigits(int value) => value < 10 ? $"0{value}" : value.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// Turns text such as "90", "90s", "15m", "2h", "1d" or "1h30m" into seconds, or null for anything else.
    /// A plain number is seconds, each unit may appear only once, and signs, decimals and digits from other scripts are refused.
    /// A total too large for an int also gives null (the Swift version allows up to the 64-bit limit; no real window or delay comes near the difference).
    /// </summary>
    public static int? ParseDuration(string text)
    {
        // Trim with Foundation's whitespace-and-newline set, then lowercase the way Swift does, so "1H30M" works and " 1h" is trimmed.
        string cleaned = SwiftText.Lowercased(TrimWhitespace(text));
        if (cleaned.Length == 0) return null;

        // Only ASCII digits count; char.IsDigit would also accept digits from other scripts.
        static bool IsDigit(char c) => c >= '0' && c <= '9';

        // A plain number is in seconds. A run of digits too long to fit gives null.
        if (cleaned.All(IsDigit)) return ToInt(ParseDigits(cleaned));

        long total = 0;
        var digits = new StringBuilder();
        var seenUnits = new HashSet<char>();
        foreach (char c in cleaned)
        {
            if (IsDigit(c))
            {
                digits.Append(c);
                continue;
            }
            // Anything that is not a digit must be one of the four unit letters, used once, with digits in front of it.
            long size = c switch { 'd' => 86_400, 'h' => 3_600, 'm' => 60, 's' => 1, _ => 0 };
            if (size == 0 || digits.Length == 0 || !seenUnits.Add(c)) return null;
            long? amount = ParseDigits(digits.ToString());
            if (amount is null) return null;
            try
            {
                total = checked(total + checked(amount.Value * size));
            }
            catch (OverflowException)
            {
                return null;
            }
            digits.Clear();
        }
        // Digits left over at the end have no unit (like "1h30"), which is not a valid combination.
        return digits.Length == 0 ? ToInt(total) : null;
    }

    /// <summary>Reads a run of ASCII digits as a number, or null when it does not fit in 64 bits.</summary>
    private static long? ParseDigits(string digits) => long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out long value) ? value : null;

    /// <summary>Narrows a number to an int, or null when it is missing or does not fit.</summary>
    private static int? ToInt(long? value) => value is >= 0 and <= int.MaxValue ? (int)value.Value : null;

    /// <summary>Removes the whitespace and line-break characters Foundation's <c>whitespacesAndNewlines</c> set holds from both ends of the text.</summary>
    private static string TrimWhitespace(string text)
    {
        int[] scalars = SwiftText.Scalars(text);
        int start = 0;
        int end = scalars.Length;
        while (start < end && SwiftText.IsWhitespaceOrNewline(scalars[start])) start++;
        while (end > start && SwiftText.IsWhitespaceOrNewline(scalars[end - 1])) end--;
        return SwiftText.FromScalars(scalars.AsSpan(start, end - start));
    }
}

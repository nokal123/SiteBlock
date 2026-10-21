using System.Globalization;
using System.Text;

namespace SiteBlock.Core;

/// <summary>The reasons a typed site name cannot be blocked; each case has a plain sentence a person can read (see <see cref="DomainErrorText.Description"/>).</summary>
public enum DomainError
{
    Empty,
    IpAddress,
    InvalidCharacters,
    LabelTooLong,
    TooLong,
    NeedsDot,
    Reserved,
}

/// <summary>The sentences shown to people for each <see cref="DomainError"/>.</summary>
public static class DomainErrorText
{
    /// <summary>The sentence shown to the user for this problem.</summary>
    public static string Description(this DomainError error) => error switch
    {
        DomainError.Empty => "Enter a site name like example.com.",
        DomainError.IpAddress => "IP addresses can't be blocked through the hosts file. Enter a site name like example.com.",
        DomainError.InvalidCharacters => "That isn't a valid site name. Use only letters, digits, hyphens and dots, like example.com.",
        DomainError.LabelTooLong => "Each part of a site name (between the dots) can be at most 63 characters long.",
        DomainError.TooLong => "A site name can be at most 253 characters long.",
        DomainError.NeedsDot => "Enter a full site name with a dot in it, like example.com.",
        DomainError.Reserved => "Names like localhost and .local are used by the PC itself, so they can't be blocked.",
        _ => throw new ArgumentOutOfRangeException(nameof(error)),
    };
}

/// <summary>Thrown by <see cref="DomainNormalizer.Normalize"/> when the text cannot be blocked; its message is the readable sentence for <see cref="Error"/>.</summary>
public sealed class DomainException(DomainError error) : Exception(error.Description())
{
    /// <summary>Which problem the text has.</summary>
    public DomainError Error { get; } = error;
}

/// <summary>Turns whatever the user typed (a bare name, a full URL, a name with a port or path) into one canonical lowercase base domain, in nine steps.</summary>
public static class DomainNormalizer
{
    /// <summary>True for a character that ends the host part of a URL: the start of the path, the query or the fragment.</summary>
    private static bool IsHostEnder(int scalar) => scalar is '/' or '?' or '#';

    /// <summary>Returns the canonical base domain for the input, or throws a <see cref="DomainException"/> explaining why it cannot be blocked.</summary>
    public static string Normalize(string input)
    {
        ArgumentNullException.ThrowIfNull(input);
        // Step 1: trim whitespace and newlines, using Foundation's set (which, unlike string.Trim, also trims the zero-width space U+200B).
        string trimmed = SwiftText.Trim(input);
        if (trimmed.Length == 0) throw new DomainException(DomainError.Empty);
        // All text surgery below works on Unicode scalars, because a combining mark can glue onto a "/" or "." and hide it from Character comparisons.
        int[] all = SwiftText.Scalars(trimmed);
        ReadOnlySpan<int> scalars = all;

        // Step 2: drop a leading "scheme://", then cut at the first "/", "?" or "#".
        // The "://" only counts as a scheme when it comes before any "/", "?" or "#", so "reddit.com/r?u=http://x.com" stays reddit.com instead of becoming x.com.
        int scheme = IndexOfScheme(scalars);
        if (scheme >= 0)
        {
            int ender = IndexOfHostEnder(scalars);
            if (ender < 0 || ender >= scheme) scalars = scalars[(scheme + 3)..];
        }
        int cut = IndexOfHostEnder(scalars);
        if (cut >= 0) scalars = scalars[..cut];

        // Step 3: drop a "user:pass@" prefix (everything up to and including the last "@").
        int at = scalars.LastIndexOf('@');
        if (at >= 0) scalars = scalars[(at + 1)..];

        // Step 4: reject IPv6 literals and drop a ":port" suffix.
        if (scalars.Length > 0 && scalars[0] == '[') throw new DomainException(DomainError.IpAddress);
        int colonCount = 0;
        int firstColon = -1;
        for (int i = 0; i < scalars.Length; i++)
        {
            if (scalars[i] != ':') continue;
            if (firstColon < 0) firstColon = i;
            colonCount++;
        }
        // More than one colon cannot be a name plus a port, so it is a bare IPv6 address.
        if (colonCount > 1) throw new DomainException(DomainError.IpAddress);
        if (colonCount == 1)
        {
            // A port must be digits only (or empty); anything else is not a site name.
            foreach (int s in scalars[(firstColon + 1)..])
            {
                if (s is < 0x30 or > 0x39) throw new DomainException(DomainError.InvalidCharacters);
            }
            scalars = scalars[..firstColon];
        }

        // Step 5: lowercase and remove one trailing dot. The dot test counts Characters, as Swift's hasSuffix does, so a dot carrying a combining mark is not a trailing dot.
        string host = SwiftText.FromScalars(SwiftText.Lowercased(scalars));
        if (SwiftText.HasCharacterSuffix(host, '.')) host = host[..^1];
        if (host.Length == 0) throw new DomainException(DomainError.Empty);

        // Step 6: check the sizes on the raw Unicode scalars before any encoding.
        // Every input scalar becomes at least one output byte, so a name over these limits could never pass the final checks anyway. Checking first matters because Punycode encoding takes time that grows with the square of the label length, and the service runs this on the thread every command waits on.
        // The label limit is checked before the whole-name limit, so one huge label reports LabelTooLong (the more useful message) rather than TooLong.
        int[] hostScalars = SwiftText.Scalars(host);
        int scalarsInLabel = 0;
        int longestLabel = 0;
        foreach (int scalar in hostScalars)
        {
            if (scalar == '.')
            {
                scalarsInLabel = 0;
            }
            else
            {
                scalarsInLabel++;
                longestLabel = Math.Max(longestLabel, scalarsInLabel);
            }
        }
        if (longestLabel > 63) throw new DomainException(DomainError.LabelTooLong);
        // A leading "www." is stripped in step 8, so it gets four extra characters here; otherwise a legal 253-character name typed with "www." in front would be rejected.
        if (hostScalars.Length > 253 + (SwiftText.HasCharacterPrefix(host, "www.") ? 4 : 0)) throw new DomainException(DomainError.TooLong);

        // Step 7: convert every label that has non-ASCII characters to its xn-- form.
        // Labels are split at "." Characters, as Swift's components(separatedBy:) does: a dot carrying a combining mark stays inside its label, which then gets Punycode-encoded whole.
        var labels = new List<string>();
        foreach (string labelText in SwiftText.SplitOnCharacter(host, '.'))
        {
            int[] label = SwiftText.Scalars(labelText);
            if (IsAllAscii(label))
            {
                labels.Add(labelText);
                continue;
            }
            // Reject invisible or space-like characters before encoding, because Punycode would turn them into a valid-looking label.
            foreach (int s in label)
            {
                if (IsForbiddenNonAscii(s)) throw new DomainException(DomainError.InvalidCharacters);
            }
            string encoded = Punycode.ToAscii(label) ?? throw new DomainException(DomainError.InvalidCharacters);
            labels.Add(encoded);
        }
        string ascii = string.Join('.', labels);

        // Step 8: strip one leading "www." so www.reddit.com and reddit.com are the same site (the expander adds www. back).
        if (ascii.StartsWith("www.", StringComparison.Ordinal)) ascii = ascii[4..];

        // Step 9: validate the final ASCII name.
        if (ascii.Length == 0) throw new DomainException(DomainError.Empty);
        if (Encoding.UTF8.GetByteCount(ascii) > 253) throw new DomainException(DomainError.TooLong);
        // The reserved check comes before the dot check so a bare "localhost" is reported as reserved rather than as missing a dot.
        if (ascii == "localhost" || ascii.EndsWith(".local", StringComparison.Ordinal) || ascii.EndsWith(".localhost", StringComparison.Ordinal)) throw new DomainException(DomainError.Reserved);
        string[] finalLabels = ascii.Split('.');
        if (finalLabels.Length < 2) throw new DomainException(DomainError.NeedsDot);
        foreach (string label in finalLabels)
        {
            if (label.Length == 0) throw new DomainException(DomainError.InvalidCharacters);
            if (label.Length > 63) throw new DomainException(DomainError.LabelTooLong);
            foreach (char c in label)
            {
                if (!IsAllowedLabelChar(c)) throw new DomainException(DomainError.InvalidCharacters);
            }
            if (label[0] == '-' || label[^1] == '-') throw new DomainException(DomainError.InvalidCharacters);
        }
        // A last label made only of digits means the input was an IPv4 address such as 1.2.3.4.
        if (finalLabels[^1].All(c => c is >= '0' and <= '9')) throw new DomainException(DomainError.IpAddress);
        return ascii;
    }

    /// <summary>Finds where "://" starts in the scalars, or -1 when it is absent.</summary>
    private static int IndexOfScheme(ReadOnlySpan<int> scalars)
    {
        for (int i = 0; i + 2 < scalars.Length; i++)
        {
            if (scalars[i] == ':' && scalars[i + 1] == '/' && scalars[i + 2] == '/') return i;
        }
        return -1;
    }

    /// <summary>Finds the first "/", "?" or "#" in the scalars, or -1 when there is none.</summary>
    private static int IndexOfHostEnder(ReadOnlySpan<int> scalars)
    {
        for (int i = 0; i < scalars.Length; i++)
        {
            if (IsHostEnder(scalars[i])) return i;
        }
        return -1;
    }

    /// <summary>True when every scalar is plain ASCII.</summary>
    private static bool IsAllAscii(ReadOnlySpan<int> scalars)
    {
        foreach (int s in scalars)
        {
            if (s >= 0x80) return false;
        }
        return true;
    }

    /// <summary>True for a character that may appear inside a final label: a-z, 0-9 or a hyphen. The final name is ASCII, so each char is one byte.</summary>
    private static bool IsAllowedLabelChar(char c) => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-';

    /// <summary>
    /// True for a non-ASCII character that can never be part of a site name: controls (Cc), invisible formatting marks (Cf, such as U+200B), space, line and paragraph separators (Zs, Zl, Zp), surrogates, private-use and unassigned code points.
    /// These are the same general categories the Swift version refuses.
    /// </summary>
    private static bool IsForbiddenNonAscii(int scalar)
    {
        if (scalar < 0x80) return false;
        if (SwiftText.IsSurrogate(scalar)) return true;
        UnicodeCategory category = Rune.GetUnicodeCategory(new Rune(scalar));
        return category is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.SpaceSeparator or UnicodeCategory.LineSeparator
            or UnicodeCategory.ParagraphSeparator or UnicodeCategory.Surrogate or UnicodeCategory.PrivateUse or UnicodeCategory.OtherNotAssigned;
    }
}

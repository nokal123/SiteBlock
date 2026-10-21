namespace SiteBlock.Core;

/// <summary>The reasons the path part of a typed rule cannot be used; each case has a plain sentence a person can read (see <see cref="PathRuleErrorText.Description"/>).</summary>
public enum PathRuleError
{
    /// <summary>The text names a site but no path under it (or the path is only slashes and stars), so it is a whole-site block, not a path rule.</summary>
    NoPath,
    /// <summary>The path is longer than 256 characters.</summary>
    TooLong,
    /// <summary>The path contains a character that is not allowed, such as a space, a star in the middle, or a letter outside plain ASCII.</summary>
    InvalidCharacters,
}

/// <summary>The sentences shown to people for each <see cref="PathRuleError"/>.</summary>
public static class PathRuleErrorText
{
    /// <summary>The sentence shown to the user for this problem.</summary>
    public static string Description(this PathRuleError error) => error switch
    {
        PathRuleError.NoPath => "Type the part of the site to block after its name, like youtube.com/shorts. A site name alone blocks the whole site.",
        PathRuleError.TooLong => "The part of the address after the site name can be at most 256 characters long.",
        PathRuleError.InvalidCharacters => "That part of the address has a character SiteBlock can't use. Use only letters, digits and - . _ ~ / % ! $ & ' ( ) + , ; = : @, with no spaces.",
        _ => throw new ArgumentOutOfRangeException(nameof(error)),
    };
}

/// <summary>Thrown by <see cref="PathRuleParser.Parse"/> when the path part of the text cannot be used; its message is the readable sentence for <see cref="Error"/>.</summary>
public sealed class PathRuleException(PathRuleError error) : Exception(error.Description())
{
    /// <summary>Which problem the path has.</summary>
    public PathRuleError Error { get; } = error;
}

/// <summary>
/// Turns typed text such as <c>youtube.com/shorts</c> or <c>https://www.youtube.com/shorts/abc?x=1</c> into a path rule (a site plus the start of a path under it), or says the text has no path (so it is a whole-site block), or explains why it cannot be used.
/// It also builds the entries that go into each browser's block list.
/// </summary>
public static class PathRuleParser
{
    /// <summary>The longest path a rule may have, counting the leading slash.</summary>
    public const int MaxPathLength = 256;

    /// <summary>The characters other than ASCII letters and digits that a path may contain.</summary>
    private const string AllowedPathPunctuation = "-._~/%!$&'()+,;=:@";

    /// <summary>
    /// Splits typed text into its host part and its path. The text is trimmed; a leading <c>scheme://</c>, a <c>user@</c> prefix and a <c>:port</c> suffix are dropped from the host; everything from the first <c>?</c> or <c>#</c> on is cut off; and the path is everything from the first <c>/</c> that remains.
    /// The path is null when there is none, or when it is only <c>/</c>, because that means "the whole site". The host is returned as typed (not lowercased or checked); <see cref="Parse"/> does the checking.
    /// </summary>
    public static (string Host, string? Path) Split(string input)
    {
        ArgumentNullException.ThrowIfNull(input);
        // Like DomainNormalizer, this works on Unicode scalars, because a combining mark can glue onto a "/" and hide it from Character comparisons.
        int[] all = SwiftText.Scalars(SwiftText.Trim(input));
        ReadOnlySpan<int> scalars = all;

        // A "://" is a scheme separator only when it comes before any "/", "?" or "#", so "youtube.com/watch?u=http://x.com" keeps its own host.
        int scheme = IndexOfScheme(scalars);
        if (scheme >= 0)
        {
            int ender = IndexOfHostEnder(scalars);
            if (ender < 0 || ender >= scheme) scalars = scalars[(scheme + 3)..];
        }

        int hostEnd = IndexOfHostEnder(scalars);
        if (hostEnd < 0) hostEnd = scalars.Length;
        ReadOnlySpan<int> host = scalars[..hostEnd];

        // A path starts only at a "/". If the host is ended by "?" or "#" instead, the rest is a query or fragment and there is no path.
        string? path = null;
        if (hostEnd < scalars.Length && scalars[hostEnd] == '/')
        {
            int pathEnd = hostEnd;
            while (pathEnd < scalars.Length && scalars[pathEnd] != '?' && scalars[pathEnd] != '#') pathEnd++;
            // A lone "/" is the whole site, not a path.
            if (pathEnd - hostEnd > 1) path = SwiftText.FromScalars(scalars[hostEnd..pathEnd]);
        }

        // Drop "user:pass@" (everything up to the last "@" in the host part). An "@" inside the path, such as /@MrBeast, is not in the host part and stays.
        int at = host.LastIndexOf('@');
        if (at >= 0) host = host[(at + 1)..];

        // Drop a ":port" only when it is exactly one colon followed by digits. Anything else (an IPv6 address, a port with letters) is left for DomainNormalizer to refuse.
        int colonCount = 0;
        int colon = -1;
        for (int i = 0; i < host.Length; i++)
        {
            if (host[i] != ':') continue;
            if (colon < 0) colon = i;
            colonCount++;
        }
        if (colonCount == 1 && (host.Length == 0 || host[0] != '[') && AllDigits(host[(colon + 1)..])) host = host[..colon];

        return (SwiftText.FromScalars(host), path);
    }

    /// <summary>
    /// Reads typed text as a path rule: the normalized base domain (all of DomainNormalizer's rules apply, so <c>www.</c> is stripped and the name is lowercased) and the path.
    /// The path keeps its case, because paths are case-sensitive. Trailing <c>*</c> characters and then trailing <c>/</c> characters are removed, so <c>/shorts/</c> and <c>/shorts*</c> both become <c>/shorts</c>.
    /// Text with no path throws <see cref="PathRuleError.NoPath"/>; a path over 256 characters throws <see cref="PathRuleError.TooLong"/>; a path with any character outside letters, digits and <c>- . _ ~ / % ! $ &amp; ' ( ) + , ; = : @</c> throws <see cref="PathRuleError.InvalidCharacters"/>.
    /// A problem with the site name throws <see cref="DomainException"/> first.
    /// </summary>
    public static (string Domain, string Path) Parse(string input)
    {
        ArgumentNullException.ThrowIfNull(input);
        // The host is checked first, so a typo in the site name reports the site name problem. DomainNormalizer cuts the text at the first "/", "?" or "#" itself, so it sees only the host part.
        string domain = DomainNormalizer.Normalize(input);
        string rawPath = Split(input).Path ?? throw new PathRuleException(PathRuleError.NoPath);

        int[] all = SwiftText.Scalars(rawPath);
        int length = all.Length;
        // Stars come off first and slashes second, so "/shorts/*" becomes "/shorts/" and then "/shorts".
        while (length > 0 && all[length - 1] == '*') length--;
        while (length > 0 && all[length - 1] == '/') length--;
        // Nothing is left for a text such as "/", "//" or "/*": that is the whole site again.
        if (length == 0) throw new PathRuleException(PathRuleError.NoPath);
        if (length > MaxPathLength) throw new PathRuleException(PathRuleError.TooLong);
        ReadOnlySpan<int> scalars = all.AsSpan(0, length);
        // Any star still in the path is in the middle, and anything outside the allowed set (spaces included) cannot be written safely into a browser's block list.
        foreach (int s in scalars)
        {
            if (!IsAllowedPathScalar(s)) throw new PathRuleException(PathRuleError.InvalidCharacters);
        }
        return (domain, SwiftText.FromScalars(scalars));
    }

    /// <summary>The rule as people read it, for example <c>youtube.com/shorts</c>.</summary>
    public static string Display(string domain, string path) => domain + path;

    /// <summary>The entry for the Chrome, Edge and Brave <c>URLBlocklist</c>. Chrome's format matches the domain, its subdomains and any address whose path starts with the given one, so the entry is the rule as people read it.</summary>
    public static string ChromeEntry(string domain, string path) => domain + path;

    /// <summary>The entry for Firefox's <c>WebsiteFilter</c>: a match pattern (Firefox's address-pattern format) for any scheme, the domain and its subdomains, and any path that starts with the given one.</summary>
    public static string FirefoxPattern(string domain, string path) => "*://*." + domain + path + "*";

    /// <summary>True for an ASCII letter or digit, or one of the allowed punctuation characters.</summary>
    private static bool IsAllowedPathScalar(int s)
    {
        if (s is (>= 0x41 and <= 0x5A) or (>= 0x61 and <= 0x7A) or (>= 0x30 and <= 0x39)) return true;
        return s < 0x80 && AllowedPathPunctuation.Contains((char)s, StringComparison.Ordinal);
    }

    /// <summary>True when every scalar is an ASCII digit (an empty run counts as all digits).</summary>
    private static bool AllDigits(ReadOnlySpan<int> scalars)
    {
        foreach (int s in scalars)
        {
            if (s is < 0x30 or > 0x39) return false;
        }
        return true;
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
            if (scalars[i] is '/' or '?' or '#') return i;
        }
        return -1;
    }
}

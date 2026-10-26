namespace SiteBlock.Core;

/// <summary>
/// The block lists the browsers get: for Chrome, Edge and Brave a <c>URLBlocklist</c>, and for Firefox a <c>WebsiteFilter</c>.
/// Each list is kept as two parts, the whole-site entries and the path-rule entries, so a list that is too long can be cut with the whole-site entries kept first.
/// Two instances are equal when their four lists hold the same entries in the same order (a plain record would compare the list objects, not their contents).
/// </summary>
public sealed record BrowserBlockLists(
    IReadOnlyList<string> ChromeSites,
    IReadOnlyList<string> ChromePaths,
    IReadOnlyList<string> FirefoxSites,
    IReadOnlyList<string> FirefoxPaths)
{
    /// <summary>No entries at all; what the uninstaller passes so every list is taken out of the browsers' policy keys.</summary>
    public static BrowserBlockLists Empty { get; } = new([], [], [], []);

    /// <summary>The whole Chrome-format list: whole-site and path entries together, sorted with ordinal (code point) comparison.</summary>
    public IReadOnlyList<string> Chrome => Combined(ChromeSites, ChromePaths);

    /// <summary>The whole Firefox list: whole-site and path patterns together, sorted with ordinal (code point) comparison.</summary>
    public IReadOnlyList<string> Firefox => Combined(FirefoxSites, FirefoxPaths);

    /// <summary>True when the other value holds the same entries in all four lists, compared entry by entry.</summary>
    public bool Equals(BrowserBlockLists? other) =>
        other is not null
        && ChromeSites.SequenceEqual(other.ChromeSites)
        && ChromePaths.SequenceEqual(other.ChromePaths)
        && FirefoxSites.SequenceEqual(other.FirefoxSites)
        && FirefoxPaths.SequenceEqual(other.FirefoxPaths);

    /// <summary>A hash built from the entries of all four lists, so it agrees with <see cref="Equals(BrowserBlockLists?)"/>.</summary>
    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var list in new[] { ChromeSites, ChromePaths, FirefoxSites, FirefoxPaths })
        {
            hash.Add(list.Count);
            foreach (var entry in list) hash.Add(entry, StringComparer.Ordinal);
        }
        return hash.ToHashCode();
    }

    /// <summary>Joins two parts into one list sorted by ordinal comparison, which matches Swift's sorted() on the ASCII entries used here.</summary>
    private static List<string> Combined(IReadOnlyList<string> sites, IReadOnlyList<string> paths)
    {
        var all = new List<string>(sites.Count + paths.Count);
        all.AddRange(sites);
        all.AddRange(paths);
        all.Sort(StringComparer.Ordinal);
        return all;
    }
}

/// <summary>The browsers SiteBlock writes a policy for. Each one has its own registry key and its own policy names.</summary>
public enum BrowserTarget
{
    /// <summary>Google Chrome.</summary>
    Chrome,
    /// <summary>Microsoft Edge.</summary>
    Edge,
    /// <summary>Brave.</summary>
    Brave,
    /// <summary>Mozilla Firefox.</summary>
    Firefox,
}

/// <summary>Helpers that give a <see cref="BrowserTarget"/> its name and its part of the block lists.</summary>
public static class BrowserTargetExtensions
{
    /// <summary>The name used in log lines, for example "Chrome".</summary>
    public static string DisplayName(this BrowserTarget target) => target switch
    {
        BrowserTarget.Chrome => "Chrome",
        BrowserTarget.Edge => "Edge",
        BrowserTarget.Brave => "Brave",
        BrowserTarget.Firefox => "Firefox",
        _ => throw new ArgumentOutOfRangeException(nameof(target)),
    };

    /// <summary>The part of the block lists this browser uses, in the order the engine built them: Firefox gets its match patterns, the other three get the Chrome-format entries.</summary>
    public static (IReadOnlyList<string> Sites, IReadOnlyList<string> Paths) Lists(this BrowserTarget target, BrowserBlockLists lists) =>
        target == BrowserTarget.Firefox ? (lists.FirefoxSites, lists.FirefoxPaths) : (lists.ChromeSites, lists.ChromePaths);
}

/// <summary>The pure rules shared by every browser's block list: how a too-long list is cut. Nothing here reads or writes the registry.</summary>
public static class BrowserPolicy
{
    /// <summary>Chrome, Edge and Brave read at most this many entries of their block list, and Firefox reads at most this many of its <c>WebsiteFilter</c> patterns; the rest are ignored.</summary>
    public const int MaxListEntries = 1000;

    /// <summary>The Edge policy name that makes Bing SafeSearch strict (value 2).</summary>
    public const string BingSafeSearchKey = "ForceBingSafeSearch";

    /// <summary>The Brave policy name that, set to 1, turns off Brave's "Private Window with Tor". Brave reads it only when it starts.</summary>
    public const string BraveTorDisabledKey = "TorDisabled";

    /// <summary>
    /// Cuts the block list to <paramref name="limit"/> entries when it is too long, keeping the whole-site entries before the path entries so a long list of path rules can never push a whole-site block out.
    /// Returns the entries to write (sorted, so the registry holds the same list on every pass) and how many were left out.
    /// </summary>
    public static (List<string> List, int DroppedCount) Capped(IEnumerable<string> sites, IEnumerable<string> paths, int limit = MaxListEntries)
    {
        var sortedSites = sites.ToList();
        sortedSites.Sort(StringComparer.Ordinal);
        var sortedPaths = paths.ToList();
        sortedPaths.Sort(StringComparer.Ordinal);
        var all = new List<string>(sortedSites.Count + sortedPaths.Count);
        all.AddRange(sortedSites);
        all.AddRange(sortedPaths);

        if (all.Count <= limit)
        {
            all.Sort(StringComparer.Ordinal);
            return (all, 0);
        }

        // A negative limit keeps nothing, the same as Swift's max(0, limit).
        int keep = Math.Max(0, limit);
        var kept = all.GetRange(0, keep);
        kept.Sort(StringComparer.Ordinal);
        return (kept, all.Count - keep);
    }
}

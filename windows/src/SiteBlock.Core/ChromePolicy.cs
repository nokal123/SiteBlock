namespace SiteBlock.Core;

/// <summary>
/// The pure rules for the Chrome-family block list SiteBlock writes: which host names go into the <c>URLBlocklist</c> list, and the names of the adult-filter policies that sit beside it.
/// Nothing here reads or writes the registry, so it can be tested anywhere.
/// </summary>
public static class ChromePolicy
{
    /// <summary>The policy (a registry subkey on Windows) that holds the list of sites the browser must refuse.</summary>
    public const string BlocklistKey = "URLBlocklist";

    /// <summary>The policy that makes the browser check each top-level page against Google's adult-content classification and refuse flagged ones. The value 1 means "filter sites".</summary>
    public const string SafeSitesKey = "SafeSitesFilterBehavior";

    /// <summary>The policy that makes Google Search always use SafeSearch.</summary>
    public const string SafeSearchKey = "ForceGoogleSafeSearch";

    /// <summary>The policy that sets the browser's Secure DNS mode. "off" makes the browser use Windows' own name lookups, so the hosts file and the family DNS servers reach it too.</summary>
    public const string DnsOverHttpsKey = "DnsOverHttpsMode";

    /// <summary>The Edge policy that makes Bing SafeSearch strict (value 2); same name as <see cref="BrowserPolicy.BingSafeSearchKey"/>.</summary>
    public const string BingSafeSearchKey = BrowserPolicy.BingSafeSearchKey;

    /// <summary>
    /// Returns the shortest list of host names that covers every host of every blocked site, lowercased and sorted.
    /// A <c>URLBlocklist</c> entry such as "youtube.com" also blocks every subdomain, so a host is left out when another host in the list is one of its parent domains ("www.youtube.com" is covered by "youtube.com").
    /// The browsers read at most 1,000 entries and ignore the rest, so keeping the list short keeps every site blocked.
    /// </summary>
    public static List<string> UrlBlocklist(IEnumerable<BlockedSite> sites)
    {
        // A set drops the names that two sites share; the final sort makes the list the same on every pass so it can be compared with the registry.
        var all = new HashSet<string>(sites.SelectMany(s => s.Hosts).Select(h => h.ToLowerInvariant()), StringComparer.Ordinal);
        var result = all.Where(h => !IsCovered(h, all)).ToList();
        result.Sort(StringComparer.Ordinal);
        return result;
    }

    /// <summary>
    /// True when the list holds the host itself or one of its parent domains, so a whole-site entry already blocks it.
    /// For example the list ["youtube.com"] covers "youtube.com" and "music.youtube.com" but not "notyoutube.com". The engine uses it to leave out path rules that a whole-site block makes redundant.
    /// </summary>
    public static bool Covers(IEnumerable<string> list, string host)
    {
        var all = new HashSet<string>(list, StringComparer.Ordinal);
        return all.Contains(host) || IsCovered(host, all);
    }

    /// <summary>True when some other name in the set is a parent domain of the host, for example "youtube.com" for "m.youtube.com". Only whole labels count, so "notyoutube.com" is not covered by "youtube.com".</summary>
    private static bool IsCovered(string host, HashSet<string> all)
    {
        int start = 0;
        int dot;
        while ((dot = host.IndexOf('.', start)) >= 0)
        {
            start = dot + 1;
            if (all.Contains(host.Substring(start))) return true;
        }
        return false;
    }
}

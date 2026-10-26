using System.Text.Json.Nodes;

namespace SiteBlock.Integration.Tests.Support;

// Expected values written out from the design, never computed by the code under test:
// 02-core-components.md § DomainExpander (expansion rule and related-domains table), § HostsFileEditor (markers and line format), § Engine (always-blocked names),
// 03-daemon-cli-app.md § ChromePolicyEnforcer (covering list) and 06-windows.md § SiteBlock.Core (Windows browser policy rules).
internal static class Expected
{
    public const string BeginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted";
    public const string EndMarker = "# END SiteBlock";

    public static readonly string[] CommonPrefixes = ["www", "m", "mobile", "old", "new", "amp", "app", "web"];

    // Engine.privateRelayHosts and Engine.dohBypassHosts, written while the adult filter is active (always, except during an uninstall).
    public static readonly string[] AlwaysBlocked = ["mask-h2.icloud.com", "mask.icloud.com", "doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"];

    // The related-domains table for the two sites the tests block.
    private static readonly Dictionary<string, string[]> Related = new()
    {
        ["reddit.com"] = ["np.reddit.com", "i.reddit.com", "oauth.reddit.com", "gateway.reddit.com", "gql.reddit.com", "sh.reddit.com", "redd.it", "i.redd.it", "v.redd.it", "preview.redd.it", "external-preview.redd.it", "redditstatic.com", "www.redditstatic.com", "redditmedia.com"],
        ["youtube.com"] = ["music.youtube.com", "tv.youtube.com", "studio.youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com", "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com"],
    };

    // The expansion rule: base, each common prefix in front of the base, each related name, and www./m. in front of each related name with exactly two labels; sorted, no duplicates.
    public static List<string> Expand(string domain)
    {
        var names = new HashSet<string>(StringComparer.Ordinal) { domain };
        foreach (string prefix in CommonPrefixes) names.Add($"{prefix}.{domain}");
        foreach (string related in Related.GetValueOrDefault(domain, []))
        {
            names.Add(related);
            if (related.Split('.').Length == 2)
            {
                names.Add("www." + related);
                names.Add("m." + related);
            }
        }
        var sorted = names.ToList();
        sorted.Sort(StringComparer.Ordinal);
        return sorted;
    }

    // The two hosts-file lines for one blocked name.
    public static string[] Lines(string host) => [$"0.0.0.0 {host}", $":: {host}"];

    // The lines strictly between the BEGIN and END markers, or null when the file has no complete section.
    public static List<string>? SectionLines(string hostsText)
    {
        var lines = hostsText.Replace("\r\n", "\n").Split('\n').ToList();
        int begin = lines.FindIndex(line => line.Trim().StartsWith("# BEGIN SiteBlock", StringComparison.Ordinal));
        if (begin < 0) return null;
        int end = lines.FindIndex(begin + 1, line => line.Trim() == EndMarker);
        if (end < 0) return null;
        return lines.GetRange(begin + 1, end - begin - 1);
    }

    // The section's lines for exactly these blocked names plus the always-blocked ones, in the order the design gives (sorted names, each with its 0.0.0.0 and :: line).
    public static List<string> SectionFor(IEnumerable<string> blockedHosts)
    {
        var names = blockedHosts.Concat(AlwaysBlocked).Distinct(StringComparer.Ordinal).ToList();
        names.Sort(StringComparer.Ordinal);
        return names.SelectMany(Lines).ToList();
    }

    // Registry key paths (06-windows.md § SiteBlock.Core, Windows browser policy rules).
    public const string ChromeKey = @"SOFTWARE\Policies\Google\Chrome";
    public const string EdgeKey = @"SOFTWARE\Policies\Microsoft\Edge";
    public const string BraveKey = @"SOFTWARE\Policies\BraveSoftware\Brave";
    public const string FirefoxKey = @"SOFTWARE\Policies\Mozilla\Firefox";
    public const string FirefoxDnsKey = FirefoxKey + @"\DNSOverHTTPS";
    public const string FirefoxBlockKey = FirefoxKey + @"\WebsiteFilter\Block";

    // The URLBlocklist subkey of a Chromium browser's key.
    public static string Blocklist(string browserKey) => browserKey + @"\URLBlocklist";

    // Each Chromium browser's owned named values while the adult filter is on, as (name, type, value) with the value as JSON text.
    public static readonly Dictionary<string, (string Name, string Type, string Value)[]> AdultValues = new()
    {
        [ChromeKey] = [("SafeSitesFilterBehavior", "dword", "1"), ("ForceGoogleSafeSearch", "dword", "1"), ("DnsOverHttpsMode", "string", "\"off\"")],
        [EdgeKey] = [("DnsOverHttpsMode", "string", "\"off\""), ("ForceGoogleSafeSearch", "dword", "1"), ("ForceBingSafeSearch", "dword", "2")],
        [BraveKey] = [("DnsOverHttpsMode", "string", "\"off\""), ("SafeSitesFilterBehavior", "dword", "1"), ("ForceGoogleSafeSearch", "dword", "1"), ("TorDisabled", "dword", "1")],
        [FirefoxDnsKey] = [("Enabled", "dword", "0"), ("Locked", "dword", "1")],
    };

    // The family DNS servers: the active provider's in the built-in providers file (01-overview-and-data.md § Fixed Policy Values), IPv4 first, then IPv6.
    // Which provider is active, and its exact addresses, is pinned by the providers file's own tests.
    public static readonly string[] FamilyServers = [.. SiteBlock.Core.FamilyDNSProviders.BuiltIn!.ActiveProvider.Servers];
    // The active provider's two IPv4 servers, which an adapter without IPv6 settings gets.
    public static readonly string[] FamilyIpv4Servers = [.. SiteBlock.Core.FamilyDNSProviders.BuiltIn!.ActiveProvider.Ipv4];

    // Finds a key in registry.json without regard to letter case, as the registry compares key names.
    public static JsonObject? Key(JsonObject registry, string keyPath)
    {
        foreach (var (name, node) in registry) if (string.Equals(name, keyPath, StringComparison.OrdinalIgnoreCase)) return node as JsonObject;
        return null;
    }

    // Finds a value in a key without regard to letter case.
    public static JsonObject? Value(JsonObject? key, string name)
    {
        if (key is null) return null;
        foreach (var (valueName, node) in key) if (string.Equals(valueName, name, StringComparison.OrdinalIgnoreCase)) return node as JsonObject;
        return null;
    }

    // The list stored in a list subkey: the string values named "1".."N", in number order; null when the key is missing. Fails when a value is not a string or a name is not "1".."N".
    public static List<string>? List(JsonObject registry, string keyPath)
    {
        if (Key(registry, keyPath) is not JsonObject key) return null;
        var entries = new List<string>();
        for (int i = 1; i <= key.Count; i++)
        {
            var value = Value(key, i.ToString(System.Globalization.CultureInfo.InvariantCulture)) ?? throw new Xunit.Sdk.XunitException($"{keyPath} has no value named {i}: {key.ToJsonString()}");
            Assert.Equal("string", (string?)value["type"]);
            entries.Add((string)value["value"]!);
        }
        return entries;
    }

    // Asserts that a value exists with exactly this type and JSON value.
    public static void AssertValue(JsonObject registry, string keyPath, string name, string type, string jsonValue)
    {
        var value = Value(Key(registry, keyPath), name);
        Assert.True(value is not null, $"{keyPath}\\{name} is missing from registry.json");
        Assert.Equal(type, (string?)value!["type"]);
        Assert.Equal(jsonValue, value["value"]!.ToJsonString());
    }

    // Asserts every adult-filter value of all four browsers is present with the documented type and content.
    public static void AssertAdultFilterValues(JsonObject registry)
    {
        foreach (var (key, values) in AdultValues)
        {
            foreach (var (name, type, value) in values) AssertValue(registry, key, name, type, value);
        }
    }
}

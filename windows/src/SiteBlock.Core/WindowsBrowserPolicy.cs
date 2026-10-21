namespace SiteBlock.Core;

/// <summary>The two kinds of registry value SiteBlock writes. The kind matters because a browser ignores a policy whose registry type is wrong.</summary>
public enum RegValueKind
{
    /// <summary>Text (REG_SZ).</summary>
    String,
    /// <summary>A 32-bit whole number (REG_DWORD).</summary>
    DWord,
}

/// <summary>
/// One registry value SiteBlock wants: its kind plus its text or its number.
/// Equality compares the kind and the content, so the text "1" is never equal to the number 1: a browser ignores a policy of the wrong type, so a hand edit that swaps one for the other must look wrong and be rewritten.
/// </summary>
public readonly record struct RegValue(RegValueKind Kind, string? Text, int? Number)
{
    /// <summary>A text value (REG_SZ).</summary>
    public static RegValue Str(string text) => new(RegValueKind.String, text ?? throw new ArgumentNullException(nameof(text)), null);

    /// <summary>A whole-number value (REG_DWORD).</summary>
    public static RegValue DWord(int number) => new(RegValueKind.DWord, null, number);

    /// <summary>A short readable form such as <c>"off"</c> or <c>dword:1</c>, for logs and test failures.</summary>
    public override string ToString() => Kind == RegValueKind.String ? $"\"{Text}\"" : $"dword:{Number}";
}

/// <summary>
/// Everything SiteBlock wants in one browser's registry policy key, as plain data with no registry calls.
/// An enforcer compares this with the real registry and rewrites what differs; the uninstaller passes an adult-filter-off, empty-list version so the Owned sets tell it what to delete.
/// </summary>
public sealed class RegistryPolicy
{
    /// <summary>Creates the description from its five parts.</summary>
    public RegistryPolicy(
        string keyPath,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, RegValue>> values,
        IReadOnlyDictionary<string, IReadOnlyList<string>> lists,
        IReadOnlySet<string> ownedListSubkeys,
        IReadOnlyDictionary<string, IReadOnlySet<string>> ownedValueNames)
    {
        KeyPath = keyPath;
        Values = values;
        Lists = lists;
        OwnedListSubkeys = ownedListSubkeys;
        OwnedValueNames = ownedValueNames;
    }

    /// <summary>The policy key under HKEY_LOCAL_MACHINE, for example <c>SOFTWARE\Policies\Google\Chrome</c>.</summary>
    public string KeyPath { get; }

    /// <summary>
    /// The named values SiteBlock wants right now, grouped by subkey path relative to <see cref="KeyPath"/> ("" for the key itself, <c>DNSOverHTTPS</c> for Firefox), then by value name.
    /// A subkey with nothing wanted (for example when the adult filter is off) is not listed.
    /// </summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, RegValue>> Values { get; }

    /// <summary>
    /// The block lists SiteBlock wants right now, keyed by list subkey relative to <see cref="KeyPath"/> (<c>URLBlocklist</c>, or <c>WebsiteFilter\Block</c> for Firefox).
    /// The entries are written in order as text values named "1", "2", "3" and so on. An empty list is not listed.
    /// </summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>> Lists { get; }

    /// <summary>The list subkeys SiteBlock owns even when they are currently empty or missing from <see cref="Lists"/>; the enforcer and the uninstaller delete an owned list subkey that is not wanted.</summary>
    public IReadOnlySet<string> OwnedListSubkeys { get; }

    /// <summary>For each subkey ("" or <c>DNSOverHTTPS</c>), the value names SiteBlock owns even when it currently wants them absent; the enforcer and the uninstaller delete an owned value that is not wanted. Values with other names are never touched.</summary>
    public IReadOnlyDictionary<string, IReadOnlySet<string>> OwnedValueNames { get; }
}

/// <summary>
/// The pure rules that turn a browser, its block lists and the adult-filter flag into the registry contents SiteBlock wants.
/// Chrome, Edge and Brave read policies from named values under their policy key and from a <c>URLBlocklist</c> subkey; Firefox uses a <c>DNSOverHTTPS</c> subkey and a <c>WebsiteFilter\Block</c> subkey.
/// </summary>
public static class WindowsBrowserPolicy
{
    /// <summary>The Firefox subkey that holds the Secure DNS settings.</summary>
    private const string FirefoxDnsSubkey = "DNSOverHTTPS";

    /// <summary>The Firefox subkey that holds the blocked website patterns.</summary>
    private const string FirefoxBlockSubkey = @"WebsiteFilter\Block";

    /// <summary>The registry key (under HKEY_LOCAL_MACHINE) in which the given browser reads its policies.</summary>
    public static string KeyPath(BrowserTarget target) => target switch
    {
        BrowserTarget.Chrome => @"SOFTWARE\Policies\Google\Chrome",
        BrowserTarget.Edge => @"SOFTWARE\Policies\Microsoft\Edge",
        BrowserTarget.Brave => @"SOFTWARE\Policies\BraveSoftware\Brave",
        BrowserTarget.Firefox => @"SOFTWARE\Policies\Mozilla\Firefox",
        _ => throw new ArgumentOutOfRangeException(nameof(target)),
    };

    /// <summary>
    /// What SiteBlock wants in the browser's registry key.
    /// The block list is included only when it is not empty, and cut to 1,000 entries with whole-site entries kept first.
    /// The adult-filter values (SafeSearch, Secure DNS off, and for Chrome and Brave the SafeSites filter) are included only while <paramref name="adultFilter"/> is true, which is always except during an uninstall.
    /// The Owned sets are the same whatever the flag and the lists are, so a pass with the filter off and empty lists still knows what to remove.
    /// </summary>
    public static RegistryPolicy Desired(BrowserTarget target, BrowserBlockLists lists, bool adultFilter)
    {
        var (sites, paths) = target.Lists(lists);
        var entries = BrowserPolicy.Capped(sites, paths).List;

        var values = new Dictionary<string, IReadOnlyDictionary<string, RegValue>>();
        var wantedLists = new Dictionary<string, IReadOnlyList<string>>();
        var ownedValues = new Dictionary<string, IReadOnlySet<string>>();
        string listSubkey;

        if (target == BrowserTarget.Firefox)
        {
            listSubkey = FirefoxBlockSubkey;
            // Firefox's own DNS-over-HTTPS skips the hosts file, so it is switched off (Enabled 0) and locked (Locked 1) so the person cannot switch it back on in Firefox's settings.
            if (adultFilter)
            {
                values[FirefoxDnsSubkey] = new Dictionary<string, RegValue>
                {
                    ["Enabled"] = RegValue.DWord(0),
                    ["Locked"] = RegValue.DWord(1),
                };
            }
            ownedValues[FirefoxDnsSubkey] = new HashSet<string>(StringComparer.Ordinal) { "Enabled", "Locked" };
        }
        else
        {
            listSubkey = ChromePolicy.BlocklistKey;
            var wanted = new Dictionary<string, RegValue>();
            if (adultFilter)
            {
                // Secure DNS off makes the browser use Windows' own name lookups, so the hosts file and the family DNS servers reach it.
                wanted[ChromePolicy.DnsOverHttpsKey] = RegValue.Str("off");
                wanted[ChromePolicy.SafeSearchKey] = RegValue.DWord(1);
                // Edge has no SafeSites policy here; it gets strict Bing SafeSearch (2) instead.
                if (target == BrowserTarget.Edge) wanted[ChromePolicy.BingSafeSearchKey] = RegValue.DWord(2);
                else wanted[ChromePolicy.SafeSitesKey] = RegValue.DWord(1);
            }
            if (wanted.Count > 0) values[""] = wanted;

            var owned = new HashSet<string>(StringComparer.Ordinal) { ChromePolicy.DnsOverHttpsKey, ChromePolicy.SafeSearchKey };
            owned.Add(target == BrowserTarget.Edge ? ChromePolicy.BingSafeSearchKey : ChromePolicy.SafeSitesKey);
            ownedValues[""] = owned;
        }

        if (entries.Count > 0) wantedLists[listSubkey] = entries;

        return new RegistryPolicy(KeyPath(target), values, wantedLists, new HashSet<string>(StringComparer.Ordinal) { listSubkey }, ownedValues);
    }

    /// <summary>The value names a list of the given length is stored under: "1", "2", up to "count".</summary>
    public static IReadOnlyList<string> ListValueNames(int count)
    {
        var names = new List<string>(Math.Max(0, count));
        for (int i = 1; i <= count; i++) names.Add(i.ToString(System.Globalization.CultureInfo.InvariantCulture));
        return names;
    }

    /// <summary>
    /// True only when the list subkey holds exactly the wanted entries: the value names are exactly "1" to "N" with nothing extra (a stray "1001" added by hand makes it wrong), and each value is text equal to the wanted entry at that position.
    /// </summary>
    public static bool ListMatches(IReadOnlyList<string> wanted, IReadOnlyDictionary<string, RegValue> actualValues)
    {
        if (actualValues.Count != wanted.Count) return false;
        var names = ListValueNames(wanted.Count);
        for (int i = 0; i < wanted.Count; i++)
        {
            if (!actualValues.TryGetValue(names[i], out var actual)) return false;
            if (actual.Kind != RegValueKind.String || !string.Equals(actual.Text, wanted[i], StringComparison.Ordinal)) return false;
        }
        return true;
    }
}

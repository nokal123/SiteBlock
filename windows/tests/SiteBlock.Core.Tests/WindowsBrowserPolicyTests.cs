using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// Expected values come from 06-windows.md § SiteBlock.Core (Windows browser policy rules) and 03-daemon-cli-app.md § BrowserPolicyEnforcer (the 1,000 cap with whole-site entries first).
public sealed class WindowsBrowserPolicyTests
{
    private static readonly BrowserBlockLists RedditAndShorts = new(["reddit.com", "redd.it"], ["youtube.com/shorts"], ["*://*.reddit.com/*", "*://*.redd.it/*"], ["*://*.youtube.com/shorts*"]);

    // The named values directly in the policy key, or an empty map.
    private static IReadOnlyDictionary<string, RegValue> TopValues(RegistryPolicy policy) => policy.Values.TryGetValue("", out var values) ? values : new Dictionary<string, RegValue>();

    [Theory]
    [InlineData(BrowserTarget.Chrome, @"SOFTWARE\Policies\Google\Chrome")]
    [InlineData(BrowserTarget.Edge, @"SOFTWARE\Policies\Microsoft\Edge")]
    [InlineData(BrowserTarget.Brave, @"SOFTWARE\Policies\BraveSoftware\Brave")]
    [InlineData(BrowserTarget.Firefox, @"SOFTWARE\Policies\Mozilla\Firefox")]
    public void Desired_EachBrowser_UsesItsDocumentedPolicyKey(BrowserTarget target, string keyPath)
    {
        Assert.Equal(keyPath, WindowsBrowserPolicy.KeyPath(target));
        Assert.Equal(keyPath, WindowsBrowserPolicy.Desired(target, RedditAndShorts, adultFilter: true).KeyPath);
    }

    [Fact]
    public void Desired_ChromeWithTheFilterOn_HoldsExactlyTheThreeAdultValuesWithTheirTypes()
    {
        var policy = WindowsBrowserPolicy.Desired(BrowserTarget.Chrome, RedditAndShorts, adultFilter: true);

        var values = TopValues(policy);
        Assert.Equal(3, values.Count);
        Assert.Equal(RegValue.DWord(1), values["SafeSitesFilterBehavior"]);
        Assert.Equal(RegValue.DWord(1), values["ForceGoogleSafeSearch"]);
        Assert.Equal(RegValue.Str("off"), values["DnsOverHttpsMode"]);
        Assert.Equal([""], policy.Values.Keys);
    }

    [Fact]
    public void Desired_EdgeWithTheFilterOn_HasStrictBingSafeSearchAndNoSafeSites()
    {
        var values = TopValues(WindowsBrowserPolicy.Desired(BrowserTarget.Edge, RedditAndShorts, adultFilter: true));

        Assert.Equal(3, values.Count);
        Assert.Equal(RegValue.Str("off"), values["DnsOverHttpsMode"]);
        Assert.Equal(RegValue.DWord(1), values["ForceGoogleSafeSearch"]);
        Assert.Equal(RegValue.DWord(2), values["ForceBingSafeSearch"]);
        Assert.False(values.ContainsKey("SafeSitesFilterBehavior"));
    }

    // 06 § SiteBlock.Core: Brave gets the Chrome-style adult values plus TorDisabled (DWORD 1), which removes the "New Private Window with Tor" option.
    [Fact]
    public void Desired_BraveWithTheFilterOn_HoldsTheChromeStyleAdultValuesAndTorDisabled()
    {
        var values = TopValues(WindowsBrowserPolicy.Desired(BrowserTarget.Brave, RedditAndShorts, adultFilter: true));

        Assert.Equal(4, values.Count);
        Assert.Equal(RegValue.Str("off"), values["DnsOverHttpsMode"]);
        Assert.Equal(RegValue.DWord(1), values["SafeSitesFilterBehavior"]);
        Assert.Equal(RegValue.DWord(1), values["ForceGoogleSafeSearch"]);
        Assert.Equal(RegValue.DWord(1), values["TorDisabled"]);
    }

    [Fact]
    public void Desired_FirefoxWithTheFilterOn_PutsDnsSettingsInTheirSubkeyAndNothingInTheKeyItself()
    {
        var policy = WindowsBrowserPolicy.Desired(BrowserTarget.Firefox, RedditAndShorts, adultFilter: true);

        var dns = policy.Values["DNSOverHTTPS"];
        Assert.Equal(2, dns.Count);
        Assert.Equal(RegValue.DWord(0), dns["Enabled"]);
        Assert.Equal(RegValue.DWord(1), dns["Locked"]);
        Assert.Empty(TopValues(policy));
        Assert.Equal(["DNSOverHTTPS"], policy.Values.Keys);
    }

    [Theory]
    [InlineData(BrowserTarget.Chrome)]
    [InlineData(BrowserTarget.Edge)]
    [InlineData(BrowserTarget.Brave)]
    public void Desired_ChromiumBrowsers_GetTheChromeListInTheirUrlBlocklistSortedByCodePoint(BrowserTarget target)
    {
        var policy = WindowsBrowserPolicy.Desired(target, RedditAndShorts, adultFilter: true);

        Assert.Equal(["URLBlocklist"], policy.Lists.Keys);
        Assert.Equal(["redd.it", "reddit.com", "youtube.com/shorts"], policy.Lists["URLBlocklist"]);
        Assert.Equal(["URLBlocklist"], policy.OwnedListSubkeys);
    }

    [Fact]
    public void Desired_Firefox_GetsTheFirefoxPatternsInWebsiteFilterBlockOnly()
    {
        var policy = WindowsBrowserPolicy.Desired(BrowserTarget.Firefox, RedditAndShorts, adultFilter: true);

        Assert.Equal([@"WebsiteFilter\Block"], policy.Lists.Keys);
        Assert.Equal(["*://*.redd.it/*", "*://*.reddit.com/*", "*://*.youtube.com/shorts*"], policy.Lists[@"WebsiteFilter\Block"]);
        // The person's own exceptions list is not SiteBlock's.
        Assert.Equal([@"WebsiteFilter\Block"], policy.OwnedListSubkeys);
    }

    [Theory]
    [InlineData(BrowserTarget.Chrome)]
    [InlineData(BrowserTarget.Edge)]
    [InlineData(BrowserTarget.Brave)]
    [InlineData(BrowserTarget.Firefox)]
    public void Desired_EmptyLists_LeaveTheListSubkeyOutButStillOwnIt(BrowserTarget target)
    {
        var policy = WindowsBrowserPolicy.Desired(target, BrowserBlockLists.Empty, adultFilter: true);

        Assert.Empty(policy.Lists);
        Assert.Single(policy.OwnedListSubkeys);
        // The adult-filter values are there even with nothing blocked.
        Assert.NotEmpty(policy.Values.SelectMany(group => group.Value));
    }

    [Theory]
    [InlineData(BrowserTarget.Chrome)]
    [InlineData(BrowserTarget.Edge)]
    [InlineData(BrowserTarget.Brave)]
    [InlineData(BrowserTarget.Firefox)]
    public void Desired_FilterOff_LeavesOutEveryAdultValueButKeepsTheLists(BrowserTarget target)
    {
        var on = WindowsBrowserPolicy.Desired(target, RedditAndShorts, adultFilter: true);
        var off = WindowsBrowserPolicy.Desired(target, RedditAndShorts, adultFilter: false);

        Assert.Empty(off.Values.SelectMany(group => group.Value));
        Assert.Equal(on.Lists.Keys, off.Lists.Keys);
        foreach (var (subkey, entries) in on.Lists) Assert.Equal(entries, off.Lists[subkey]);
    }

    [Theory]
    [InlineData(BrowserTarget.Chrome, "", new[] { "DnsOverHttpsMode", "ForceGoogleSafeSearch", "SafeSitesFilterBehavior" })]
    [InlineData(BrowserTarget.Edge, "", new[] { "DnsOverHttpsMode", "ForceBingSafeSearch", "ForceGoogleSafeSearch" })]
    [InlineData(BrowserTarget.Brave, "", new[] { "DnsOverHttpsMode", "ForceGoogleSafeSearch", "SafeSitesFilterBehavior", "TorDisabled" })]
    [InlineData(BrowserTarget.Firefox, "DNSOverHTTPS", new[] { "Enabled", "Locked" })]
    public void Desired_OwnedSets_AreTheSameWhateverTheFlagAndTheLists(BrowserTarget target, string subkey, string[] ownedNames)
    {
        var variants = new[]
        {
            WindowsBrowserPolicy.Desired(target, RedditAndShorts, adultFilter: true),
            WindowsBrowserPolicy.Desired(target, RedditAndShorts, adultFilter: false),
            WindowsBrowserPolicy.Desired(target, BrowserBlockLists.Empty, adultFilter: true),
            WindowsBrowserPolicy.Desired(target, BrowserBlockLists.Empty, adultFilter: false),
        };

        foreach (var policy in variants)
        {
            Assert.Equal([subkey], policy.OwnedValueNames.Keys);
            Assert.Equal(ownedNames, policy.OwnedValueNames[subkey].Order(StringComparer.Ordinal));
            Assert.Equal(variants[0].OwnedListSubkeys.Order(StringComparer.Ordinal), policy.OwnedListSubkeys.Order(StringComparer.Ordinal));
        }
    }

    [Fact]
    public void Desired_ExactlyAThousandEntries_KeepsThemAll()
    {
        var sites = Enumerable.Range(0, 990).Select(i => $"site{i:D4}.example").ToList();
        var paths = Enumerable.Range(0, 10).Select(i => $"rule{i}.example/p").ToList();

        var list = WindowsBrowserPolicy.Desired(BrowserTarget.Chrome, new BrowserBlockLists(sites, paths, [], []), adultFilter: true).Lists["URLBlocklist"];

        Assert.Equal(1000, list.Count);
        Assert.Equal(sites.Concat(paths).Order(StringComparer.Ordinal), list);
    }

    [Fact]
    public void Desired_OverAThousandEntries_CutsToAThousandWithEveryWholeSiteKeptFirst()
    {
        // Path entries that sort before every site ("a…") must still lose to the sites.
        var sites = Enumerable.Range(0, 995).Select(i => $"site{i:D4}.example").ToList();
        var paths = Enumerable.Range(0, 30).Select(i => $"a{i:D2}.example/path").ToList();

        var list = WindowsBrowserPolicy.Desired(BrowserTarget.Edge, new BrowserBlockLists(sites, paths, [], []), adultFilter: true).Lists["URLBlocklist"];

        Assert.Equal(1000, list.Count);
        Assert.All(sites, site => Assert.Contains(site, list));
        Assert.Equal(5, list.Count(entry => entry.Contains('/')));
        Assert.All(list, entry => Assert.True(sites.Contains(entry) || paths.Contains(entry)));
        Assert.Equal(list.Order(StringComparer.Ordinal), list);
    }

    [Fact]
    public void Desired_MoreThanAThousandWholeSites_KeepsNoPathEntryForFirefox()
    {
        var sites = Enumerable.Range(0, 1005).Select(i => $"*://*.site{i:D4}.example/*").ToList();
        var paths = new List<string> { "*://*.aaa.example/x*" };

        var list = WindowsBrowserPolicy.Desired(BrowserTarget.Firefox, new BrowserBlockLists([], [], sites, paths), adultFilter: true).Lists[@"WebsiteFilter\Block"];

        Assert.Equal(1000, list.Count);
        Assert.DoesNotContain("*://*.aaa.example/x*", list);
        Assert.Equal(list.Distinct().Count(), list.Count);
    }

    [Fact]
    public void ListValueNames_AreOneToNAsText()
    {
        Assert.Equal(["1", "2", "3"], WindowsBrowserPolicy.ListValueNames(3));
        Assert.Empty(WindowsBrowserPolicy.ListValueNames(0));
        Assert.Equal("1000", WindowsBrowserPolicy.ListValueNames(1000)[^1]);
    }

    // The registry contents of a correct list subkey for the given entries.
    private static Dictionary<string, RegValue> Stored(params string[] entries) =>
        entries.Select((entry, index) => ((index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), RegValue.Str(entry))).ToDictionary(pair => pair.Item1, pair => pair.Item2);

    [Fact]
    public void ListMatches_ExactCopy_IsTrue()
    {
        Assert.True(WindowsBrowserPolicy.ListMatches(["a.com", "b.com"], Stored("a.com", "b.com")));
        Assert.True(WindowsBrowserPolicy.ListMatches([], new Dictionary<string, RegValue>()));
    }

    [Fact]
    public void ListMatches_StrayValueOrWrongTypeOrOrderOrMissingEntry_IsFalse()
    {
        var stray = Stored("a.com", "b.com");
        stray["1001"] = RegValue.Str("c.com");
        var wrongType = Stored("a.com", "b.com");
        wrongType["2"] = RegValue.DWord(1);
        var gap = new Dictionary<string, RegValue> { ["1"] = RegValue.Str("a.com"), ["3"] = RegValue.Str("b.com") };

        Assert.False(WindowsBrowserPolicy.ListMatches(["a.com", "b.com"], stray));
        Assert.False(WindowsBrowserPolicy.ListMatches(["a.com", "b.com"], wrongType));
        Assert.False(WindowsBrowserPolicy.ListMatches(["a.com", "b.com"], Stored("b.com", "a.com")));
        Assert.False(WindowsBrowserPolicy.ListMatches(["a.com", "b.com"], Stored("a.com")));
        Assert.False(WindowsBrowserPolicy.ListMatches(["a.com", "b.com"], gap));
        Assert.False(WindowsBrowserPolicy.ListMatches(["a.com"], Stored("A.com")));
        Assert.False(WindowsBrowserPolicy.ListMatches([], Stored("a.com")));
    }

    [Fact]
    public void RegValue_TextOneAndNumberOne_AreDifferentValues()
    {
        Assert.NotEqual(RegValue.Str("1"), RegValue.DWord(1));
        Assert.NotEqual(RegValue.DWord(1), RegValue.DWord(2));
        Assert.Equal(RegValue.Str("off"), RegValue.Str("off"));
        Assert.NotEqual(RegValue.Str("off"), RegValue.Str("Off"));
    }
}

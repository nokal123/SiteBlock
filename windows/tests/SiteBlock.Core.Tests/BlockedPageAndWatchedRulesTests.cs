using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// BlockedPage: expected values from 02-core-components.md § BlockedPage (title "Blocked by SiteBlock"; the address is "data:text/html;charset=utf-8," plus the page percent-encoded,
// leaving only ASCII letters, digits and -._~ plain; the heading "<rule> is blocked"; the rule HTML-escaped for & < > " ') and 06-windows.md § SiteBlock.Core (Blocked page: the last
// sentence names the system tray icon).
public sealed partial class BlockedPageTests
{
    private const string Prefix = "data:text/html;charset=utf-8,";

    // The part after the prefix, checked to hold only plain characters and %XX escapes.
    private static string Payload(string address)
    {
        Assert.StartsWith(Prefix, address, StringComparison.Ordinal);
        return address[Prefix.Length..];
    }

    // Undoes the percent-encoding by hand: each %XX is one byte, every other character is its own ASCII byte, and the bytes are UTF-8.
    private static string Decode(string payload)
    {
        var bytes = new List<byte>();
        for (int i = 0; i < payload.Length; i++)
        {
            if (payload[i] == '%')
            {
                bytes.Add(Convert.ToByte(payload.Substring(i + 1, 2), 16));
                i += 2;
            }
            else bytes.Add((byte)payload[i]);
        }
        return new UTF8Encoding(false, true).GetString([.. bytes]);
    }

    [GeneratedRegex("^(?:[A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})*$")]
    private static partial Regex OnlyPlainOrEscaped();

    [GeneratedRegex("<h1[^>]*>(.*?)</h1>", RegexOptions.Singleline)]
    private static partial Regex Heading();

    [Fact]
    public void Title_IsBlockedBySiteBlock()
    {
        Assert.Equal("Blocked by SiteBlock", BlockedPage.Title);
        Assert.Contains("<title>Blocked by SiteBlock</title>", BlockedPage.Html("x.com"), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("x.com")]
    [InlineData("youtube.com/shorts")]
    [InlineData("a#b%c d+e&f")]
    [InlineData("bücher.de/straße")]
    [InlineData("😀.example/路径")]
    public void Address_PayloadHoldsOnlyUnreservedCharactersAndEscapes(string rule)
    {
        string payload = Payload(BlockedPage.Address(rule));
        Assert.Matches(OnlyPlainOrEscaped(), payload);
        // '#' would end the page at a fragment, '+' is not a space in a data: address, and a raw space breaks the address bar text.
        Assert.DoesNotContain('#', payload);
        Assert.DoesNotContain('+', payload);
        Assert.DoesNotContain(' ', payload);
    }

    [Theory]
    [InlineData("x.com")]
    [InlineData("youtube.com/shorts")]
    [InlineData("a#b%c d+e&f")]
    [InlineData("bücher.de/straße")]
    [InlineData("😀.example/路径")]
    [InlineData("<script>alert('x')</script>")]
    public void Address_DecodedGivesBackTheHtml(string rule)
    {
        Assert.Equal(BlockedPage.Html(rule), Decode(Payload(BlockedPage.Address(rule))));
    }

    [Theory]
    [InlineData("ü", "%C3%BC")]
    [InlineData("😀", "%F0%9F%98%80")]
    [InlineData("é", "%C3%A9")]
    public void Address_NonAsciiIsEncodedAsItsUtf8Bytes(string rule, string escaped)
    {
        Assert.Contains(escaped, BlockedPage.Address(rule), StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("-", "-")]
    [InlineData(".", ".")]
    [InlineData("_", "_")]
    [InlineData("~", "~")]
    [InlineData("!", "%21")]
    [InlineData("*", "%2A")]
    [InlineData("'", "%27")]
    [InlineData("(", "%28")]
    [InlineData("/", "%2F")]
    [InlineData("%", "%25")]
    public void Address_KeepsOnlyDashDotUnderscoreTildeAsPunctuation(string character, string expected)
    {
        // The escaped page's rule text sits between "%3Ch1%3E" (the heading tag) and "%20is%20blocked"; a quote is escaped to an HTML entity first, so it is checked on its own below.
        string payload = Payload(BlockedPage.Address("z" + character + "z"));
        if (character == "'") Assert.DoesNotContain("'", payload, StringComparison.Ordinal);
        else Assert.Contains("z" + expected + "z", payload, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("x.com")]
    [InlineData("youtube.com/shorts")]
    public void Html_HeadingSaysTheRuleIsBlocked(string rule)
    {
        Assert.Equal(rule + " is blocked", Heading().Match(BlockedPage.Html(rule)).Groups[1].Value);
    }

    [Fact]
    public void Html_LastSentenceNamesTheSystemTrayNotTheMenuBar()
    {
        string html = BlockedPage.Html("x.com");
        Assert.Contains("SiteBlock blocked this page. To open it again, use the SiteBlock icon in the system tray.", html, StringComparison.Ordinal);
        Assert.DoesNotContain("menu bar", html, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Html_FollowsTheSystemsLightOrDarkAppearance()
    {
        Assert.Contains("prefers-color-scheme", BlockedPage.Html("x.com"), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("a&b")]
    [InlineData("<img src=x onerror=alert(1)>")]
    [InlineData("\"quoted\"")]
    [InlineData("it's")]
    [InlineData("&amp;")]
    [InlineData("<script>alert('x')</script>")]
    public void Html_RuleTextIsEscapedSoItShowsAsTextAndAddsNoMarkup(string rule)
    {
        string html = BlockedPage.Html(rule);
        string heading = Heading().Match(html).Groups[1].Value;
        // The raw heading holds none of the five special characters except & starting an entity, and reads back as exactly the rule.
        Assert.DoesNotContain('<', heading);
        Assert.DoesNotContain('>', heading);
        Assert.DoesNotContain('"', heading);
        Assert.DoesNotContain('\'', heading);
        Assert.Matches("^(?:[^&]|&(?:amp|lt|gt|quot|#39|#x27|apos);)*$", heading);
        Assert.Equal(rule + " is blocked", WebUtility.HtmlDecode(heading));
        // The page has exactly the markup it always has: no element the rule added.
        Assert.Equal(Regex.Matches(BlockedPage.Html("x.com"), "<").Count, Regex.Matches(html, "<").Count);
    }
}

// WatchedPathRule: expected values from 06-windows.md § SiteBlock.Core (Rules for the tab watcher) and 02-core-components.md § TabRuleMatcher (whole-site path "/", displayText,
// the 0.5 s and 4 s intervals, 4 s for an empty list; a whole-site rule matches every path of the domain and its subdomains; a data: address matches no rule).
public sealed class WatchedPathRuleTests
{
    [Fact]
    public void WholeSitePath_IsASlashAlone()
    {
        Assert.Equal("/", WatchedPathRule.WholeSitePath);
    }

    [Theory]
    [InlineData("/", true)]
    [InlineData("/shorts", false)]
    [InlineData("/s", false)]
    [InlineData("//", false)]
    public void IsWholeSite_TrueOnlyForTheSlashPath(string path, bool expected)
    {
        Assert.Equal(expected, new WatchedPathRule("x.com", path).IsWholeSite);
    }

    [Theory]
    [InlineData("x.com", "/", "x.com")]
    [InlineData("youtube.com", "/shorts", "youtube.com/shorts")]
    [InlineData("reddit.com", "/r/All", "reddit.com/r/All")]
    public void DisplayText_IsTheDomainAloneForAWholeSiteOtherwiseSiteAndPath(string domain, string path, string expected)
    {
        Assert.Equal(expected, new WatchedPathRule(domain, path).DisplayText);
    }

    [Fact]
    public void CheckIntervals_AreHalfASecondAndFourSeconds()
    {
        Assert.Equal(TimeSpan.FromSeconds(0.5), WatchedPathRule.PathRuleCheckInterval);
        Assert.Equal(TimeSpan.FromSeconds(4), WatchedPathRule.WholeSiteCheckInterval);
    }

    [Fact]
    public void CheckInterval_FourSecondsForNoRulesOrOnlyWholeSitesAndHalfASecondWithAnyPathRule()
    {
        var whole = new WatchedPathRule("x.com", "/");
        var path = new WatchedPathRule("youtube.com", "/shorts");
        Assert.Equal(TimeSpan.FromSeconds(4), WatchedPathRule.CheckInterval([]));
        Assert.Equal(TimeSpan.FromSeconds(4), WatchedPathRule.CheckInterval([whole, new WatchedPathRule("a.com", "/")]));
        Assert.Equal(TimeSpan.FromSeconds(0.5), WatchedPathRule.CheckInterval([path]));
        Assert.Equal(TimeSpan.FromSeconds(0.5), WatchedPathRule.CheckInterval([whole, whole, path]));
    }

    [Theory]
    [InlineData("https://x.com", true)]
    [InlineData("https://x.com/", true)]
    [InlineData("http://www.x.com/home?a=1#b", true)]
    [InlineData("https://mobile.x.com/i/flow", true)]
    [InlineData("https://X.COM/Anything", true)]
    [InlineData("https://notx.com/", false)]
    [InlineData("https://x.co/", false)]
    [InlineData("https://x.com.evil.net/", false)]
    [InlineData("ftp://x.com/", false)]
    public void Matches_WholeSiteRuleCoversEveryPathOfTheSiteAndItsSubdomains(string url, bool expected)
    {
        Assert.Equal(expected, TabRuleMatcher.Matches(url, new WatchedPathRule("x.com", "/")));
    }

    [Fact]
    public void MatchingRule_TheBlockedPageItselfMatchesNoRule()
    {
        var rules = new[] { new WatchedPathRule("x.com", "/"), new WatchedPathRule("youtube.com", "/shorts") };
        Assert.Null(TabRuleMatcher.MatchingRule(BlockedPage.Address("x.com"), rules));
        Assert.Null(TabRuleMatcher.MatchingRule(BlockedPage.Address("youtube.com/shorts"), rules));
    }
}

// StatusSnapshot.WatchedTabRules and SecondsUntilWatchedRulesChange: expected values from 02-core-components.md § TabRuleMatcher (Rules for the tab watcher): one whole-site rule per host of
// the browsers' block list (sites whose temporary unblock is not open, a host dropped when a parent domain is listed, normalized so www. goes, refused hosts and duplicates dropped,
// sorted by domain) followed by the path rules without an open temporary unblock; and the smallest of the countdowns that change that list, or null.
public sealed class WatchedTabRulesTests
{
    private static StatusSnapshot Snapshot(BlockedSiteStatus[] sites, BlockedPathStatus[]? paths = null) => new("1.0", true, sites, 0, null, null, null, null, true, true, paths ?? []);

    private static BlockedSiteStatus Site(string domain, params string[] hosts) => new(domain, hosts.Length == 0 ? [domain, "www." + domain] : hosts, null);

    private static WatchedPathRule Whole(string domain) => new(domain, "/");

    private static readonly TemporaryUnblockStatus Open = new(null, 600, 900, true);
    private static readonly TemporaryUnblockStatus Waiting = new(120, 900, 900, false);

    [Fact]
    public void WatchedTabRules_NoSitesOrPaths_IsEmpty()
    {
        Assert.Empty(Snapshot([]).WatchedTabRules);
    }

    [Fact]
    public void WatchedTabRules_OneWholeSiteRulePerSiteSortedByDomain()
    {
        var rules = Snapshot([Site("reddit.com", "reddit.com", "www.reddit.com", "old.reddit.com"), Site("bing.com")]).WatchedTabRules;
        Assert.Equal([Whole("bing.com"), Whole("reddit.com")], rules);
    }

    [Fact]
    public void WatchedTabRules_HostUnderAnotherSitesDomainIsLeftOut()
    {
        var rules = Snapshot([Site("mail.google.com"), Site("google.com")]).WatchedTabRules;
        Assert.Equal([Whole("google.com")], rules);
    }

    [Fact]
    public void WatchedTabRules_ListedWwwHostIsNormalizedToTheBareDomain()
    {
        var rules = Snapshot([Site("example.com", "www.example.com")]).WatchedTabRules;
        Assert.Equal([Whole("example.com")], rules);
        Assert.True(TabRuleMatcher.Matches("https://www.example.com/page", rules[0]));
    }

    [Fact]
    public void WatchedTabRules_SharedHostAndHostsNormalizingAlikeGiveOneRule()
    {
        // "dup.org." and "dup.org" are two names to the browsers' list but one host after normalizing (one trailing dot goes); so are "bücher.de" and its Punycode form.
        var rules = Snapshot([Site("a.com", "shared.net"), Site("b.com", "shared.net"), Site("c.com", "dup.org."), Site("d.com", "dup.org"), Site("e.com", "bücher.de"), Site("f.com", "xn--bcher-kva.de")]).WatchedTabRules;
        Assert.Equal([Whole("dup.org"), Whole("shared.net"), Whole("xn--bcher-kva.de")], rules);
    }

    [Fact]
    public void WatchedTabRules_HostTheNormalizerRefusesIsDropped()
    {
        var rules = Snapshot([Site("ok.com", "ok.com", "bad_host.ok2.com")]).WatchedTabRules;
        Assert.Equal([Whole("ok.com")], rules);
    }

    [Fact]
    public void WatchedTabRules_SiteWithOpenTemporaryUnblockIsLeftOutAndWaitingOneStays()
    {
        var sites = new[] { new BlockedSiteStatus("open.com", ["open.com"], null, Open), new BlockedSiteStatus("waiting.com", ["waiting.com"], null, Waiting), new BlockedSiteStatus("leaving.com", ["leaving.com"], 3600) };
        Assert.Equal([Whole("leaving.com"), Whole("waiting.com")], Snapshot(sites).WatchedTabRules);
    }

    [Fact]
    public void WatchedTabRules_OpenSitesHostIsNotHiddenUnderAnotherSite()
    {
        // google.com is open for now, so mail.google.com (still blocked) must be watched on its own instead of being folded into google.com.
        var sites = new[] { new BlockedSiteStatus("google.com", ["google.com"], null, Open), new BlockedSiteStatus("mail.google.com", ["mail.google.com"], null) };
        Assert.Equal([Whole("mail.google.com")], Snapshot(sites).WatchedTabRules);
    }

    [Fact]
    public void WatchedTabRules_WholeSitesComeBeforePathRulesWhateverTheirNames()
    {
        var paths = new[] { new BlockedPathStatus("aaa.com", "/shorts", "aaa.com/shorts", null), new BlockedPathStatus("open.com", "/x", "open.com/x", null, Open), new BlockedPathStatus("wait.com", "/y", "wait.com/y", null, Waiting) };
        var rules = Snapshot([Site("zzz.com")], paths).WatchedTabRules;
        Assert.Equal([Whole("zzz.com"), new WatchedPathRule("aaa.com", "/shorts"), new WatchedPathRule("wait.com", "/y")], rules);
    }

    [Fact]
    public void SecondsUntilWatchedRulesChange_NoCountdown_IsNull()
    {
        Assert.Null(Snapshot([Site("a.com")], [new BlockedPathStatus("b.com", "/x", "b.com/x", null)]).SecondsUntilWatchedRulesChange);
    }

    [Theory]
    [InlineData("site-unblock", 300)]
    [InlineData("path-unblock", 42)]
    [InlineData("site-open", 600)]
    [InlineData("path-waiting", 120)]
    public void SecondsUntilWatchedRulesChange_EachKindAloneGivesItsOwnSeconds(string kind, long expected)
    {
        StatusSnapshot snapshot = kind switch
        {
            "site-unblock" => Snapshot([new BlockedSiteStatus("a.com", ["a.com"], 300)]),
            "path-unblock" => Snapshot([], [new BlockedPathStatus("b.com", "/x", "b.com/x", 42)]),
            "site-open" => Snapshot([new BlockedSiteStatus("a.com", ["a.com"], null, Open)]),
            _ => Snapshot([], [new BlockedPathStatus("b.com", "/x", "b.com/x", null, Waiting)]),
        };
        Assert.Equal(expected, snapshot.SecondsUntilWatchedRulesChange);
    }

    [Fact]
    public void SecondsUntilWatchedRulesChange_WaitingWithoutOpensInSecondsUsesSecondsRemaining()
    {
        var snapshot = Snapshot([new BlockedSiteStatus("a.com", ["a.com"], null, new TemporaryUnblockStatus(null, 75, 900, false))]);
        Assert.Equal(75, snapshot.SecondsUntilWatchedRulesChange);
    }

    [Fact]
    public void SecondsUntilWatchedRulesChange_IsTheSmallestAcrossEveryKind()
    {
        var sites = new[] { new BlockedSiteStatus("a.com", ["a.com"], 300), new BlockedSiteStatus("c.com", ["c.com"], null, Open), new BlockedSiteStatus("d.com", ["d.com"], null, new TemporaryUnblockStatus(30, 900, 900, false)) };
        var paths = new[] { new BlockedPathStatus("b.com", "/x", "b.com/x", 90), new BlockedPathStatus("e.com", "/y", "e.com/y", null, new TemporaryUnblockStatus(null, 17, 900, true)) };
        Assert.Equal(17, Snapshot(sites, paths).SecondsUntilWatchedRulesChange);
        // Without the 17-second open path rule, the waiting site's 30-second start wait is the smallest (its 900-second window does not count yet).
        Assert.Equal(30, Snapshot(sites, paths[..1]).SecondsUntilWatchedRulesChange);
    }
}

using System.Diagnostics;
using SiteBlock.AppLogic;
using SiteBlock.Core;

namespace SiteBlock.AppLogic.Tests;

// The tab watcher's move to the blocked page, its reload fallback, whole-site rules, and its look interval.
// Expected values come from 06-windows.md § TabWatcher (step 5: read the address again, call IBrowserTabs.Open with BlockedPage.Address(rule.DisplayText), press reload only
// when Open throws; the two log lines; SetRules ignores an equal list and a changed list cuts the wait short; a look every 0.5 s while a path rule exists and every 4 s otherwise)
// and § SiteBlock.Core (Rules for the tab watcher: DisplayText is the site name alone for a whole site), with the matching rules of 02-core-components.md § TabRuleMatcher.
public sealed class TabWatcherBlockedPageTests
{
    private const int Chrome = 4100;
    private static readonly WatchedPathRule Shorts = new("youtube.com", "/shorts");
    private static readonly WatchedPathRule WholeX = new("x.com", "/");
    private const string SentChrome = "sent a Google Chrome tab to the blocked page";
    private const string ReloadedChrome = "reloaded a Google Chrome tab on a blocked site or part of a site";

    private static (TabWatcher Watcher, FakeBrowserTabs Tabs, RecordingLog Log, ManualClock Clock) Make(params WatchedPathRule[] rules)
    {
        var tabs = new FakeBrowserTabs();
        var log = new RecordingLog();
        var clock = new ManualClock();
        var watcher = new TabWatcher(tabs, clock, log);
        watcher.SetRules(rules);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        return (watcher, tabs, log, clock);
    }

    // The page's HTML, read back out of a data: address by undoing the percent-encoding (the bytes are UTF-8).
    private static string PageOf(string address)
    {
        const string prefix = "data:text/html;charset=utf-8,";
        Assert.StartsWith(prefix, address, StringComparison.Ordinal);
        return Uri.UnescapeDataString(address[prefix.Length..]);
    }

    // Polls a condition on real time, for the beat that runs on a pool thread.
    private static bool Eventually(Func<bool> condition, double seconds = 5)
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(seconds))
        {
            if (condition()) return true;
            Thread.Sleep(5);
        }
        return condition();
    }

    [Fact]
    public async Task Tick_OpenThrows_PressesReloadOnceAndLogsTheReloadLine()
    {
        var (watcher, tabs, log, _) = Make(Shorts);
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.OpenThrows = true;
        await watcher.TryRunTickAsync();
        Assert.Equal([(Chrome, "1", BlockedPage.Address("youtube.com/shorts"))], tabs.OpenAttempts);
        Assert.Equal([(Chrome, "1")], tabs.Reloads);
        Assert.Equal([ReloadedChrome], log.Lines);
    }

    [Fact]
    public async Task Tick_OpenThrowsThenReloadWorks_IsNotRepeatedOnLaterTicks()
    {
        var (watcher, tabs, log, _) = Make(Shorts);
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.OpenThrows = true;
        for (int i = 0; i < 4; i++) await watcher.TryRunTickAsync();
        Assert.Single(tabs.OpenAttempts);
        Assert.Single(tabs.Reloads);
        Assert.Equal([ReloadedChrome], log.Lines);
    }

    [Fact]
    public async Task Tick_PathRule_OpenAddressIsTheBlockedPageNamingSiteAndPath()
    {
        var (watcher, tabs, _, _) = Make(Shorts);
        tabs.SetWindows(Chrome, ("1", "https://m.youtube.com/shorts/abc?feature=share"));
        await watcher.TryRunTickAsync();
        var open = Assert.Single(tabs.Opens);
        Assert.Equal(BlockedPage.Address("youtube.com/shorts"), open.Url);
        Assert.Contains("youtube.com/shorts is blocked", PageOf(open.Url), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Tick_WholeSiteRule_SendsEveryPathAndSubdomainToThePageNamingJustTheDomain()
    {
        var (watcher, tabs, _, _) = Make(WholeX);
        tabs.SetWindows(Chrome, ("1", "https://x.com"), ("2", "https://mobile.x.com/home?q=1#top"), ("3", "https://notx.com/"), ("4", "http://www.x.com:8080/i/flow/login"), ("5", "https://x.co/"), ("6", "chrome://settings/x.com"));
        await watcher.TryRunTickAsync();
        Assert.Equal(["1", "2", "4"], tabs.Opens.Select(open => open.Window).Order(StringComparer.Ordinal));
        foreach (var open in tabs.Opens)
        {
            Assert.Equal(BlockedPage.Address("x.com"), open.Url);
            string page = PageOf(open.Url);
            Assert.Contains("x.com is blocked", page, StringComparison.Ordinal);
            // A whole site shows the domain alone, never the "/" path that stands for it.
            Assert.DoesNotContain("x.com/ is blocked", page, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Tick_SiteAndPathRuleOnTheSameSite_PageNamesTheWholeSite()
    {
        // The rule list comes from the snapshot, which puts whole sites before path rules (02-core-components.md § TabRuleMatcher, watchedTabRules).
        var snapshot = new StatusSnapshot("1.0", true, [new BlockedSiteStatus("youtube.com", ["youtube.com", "www.youtube.com"], null)], 0, null, null, null, null, true, true, [new BlockedPathStatus("youtube.com", "/shorts", "youtube.com/shorts", null)]);
        var (watcher, tabs, _, _) = Make([.. snapshot.WatchedTabRules]);
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        Assert.Equal(BlockedPage.Address("youtube.com"), Assert.Single(tabs.Opens).Url);
    }

    [Fact]
    public async Task Tick_PathRuleListedAfterAWholeSite_PageNamesThePathRuleTheTabMatches()
    {
        // The tab matches only the second rule of the list, so a page built from the list's first rule (x.com) would be wrong.
        var (watcher, tabs, _, _) = Make(WholeX, Shorts);
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        Assert.Equal(BlockedPage.Address("youtube.com/shorts"), Assert.Single(tabs.Opens).Url);
    }

    [Fact]
    public async Task Tick_SecondReadIsOnAnotherRule_PageNamesTheRuleTheTabIsOnNow()
    {
        var (watcher, tabs, _, _) = Make(WholeX, Shorts);
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.CurrentOverrides[(Chrome, "1")] = "https://x.com/home";
        await watcher.TryRunTickAsync();
        Assert.Equal(BlockedPage.Address("x.com"), Assert.Single(tabs.Opens).Url);
    }

    [Fact]
    public async Task Tick_TabShowingTheBlockedPage_IsLeftAloneUntilItReturnsToTheSite()
    {
        var (watcher, tabs, log, _) = Make(WholeX);
        tabs.SetWindows(Chrome, ("1", "https://x.com/home"));
        await watcher.TryRunTickAsync();
        // The browser now shows the blocked page itself, a data: address that matches no rule.
        tabs.SetWindows(Chrome, ("1", BlockedPage.Address("x.com")));
        for (int i = 0; i < 3; i++) await watcher.TryRunTickAsync();
        Assert.Single(tabs.OpenAttempts);
        tabs.SetWindows(Chrome, ("1", "https://x.com/home"));
        await watcher.TryRunTickAsync();
        Assert.Equal(2, tabs.Opens.Count);
        Assert.Equal([SentChrome, SentChrome], log.Lines);
    }

    [Fact]
    public async Task Tick_RetryAfterBothFailed_TriesTheOpenFirstAgain()
    {
        var (watcher, tabs, log, clock) = Make(Shorts);
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.OpenThrows = true;
        tabs.ReloadThrows = true;
        await watcher.TryRunTickAsync();
        tabs.OpenThrows = false;
        tabs.ReloadThrows = false;
        clock.Advance(TimeSpan.FromSeconds(5));
        await watcher.TryRunTickAsync();
        Assert.Equal(2, tabs.OpenAttempts.Count);
        Assert.Single(tabs.Opens);
        Assert.Empty(tabs.Reloads);
        Assert.Equal([SentChrome], log.Lines);
    }

    [Theory]
    [MemberData(nameof(IntervalCases))]
    public void Start_FirstWaitFollowsTheRuleList(WatchedPathRule[] rules, double seconds)
    {
        var (watcher, _, _, clock) = Make(rules);
        try
        {
            watcher.Start();
            Assert.True(Eventually(() => clock.RequestedDelays.Count >= 1));
            Assert.Equal(TimeSpan.FromSeconds(seconds), clock.RequestedDelays[0]);
        }
        finally
        {
            watcher.Dispose();
        }
    }

    public static TheoryData<WatchedPathRule[], double> IntervalCases() => new()
    {
        { [], 4 },
        { [WholeX], 4 },
        { [WholeX, new WatchedPathRule("reddit.com", "/")], 4 },
        { [Shorts], 0.5 },
        { [WholeX, Shorts], 0.5 },
    };

    [Fact]
    public void SetRules_EqualListDoesNotCutTheWaitButADifferentListLooksAtOnce()
    {
        var (watcher, tabs, _, clock) = Make(WholeX);
        tabs.Browsers.Clear();
        try
        {
            watcher.Start();
            // The rules set before Start are looked at at once, then the beat waits 4 seconds.
            Assert.True(Eventually(() => clock.Parked(TimeSpan.FromSeconds(4)) == 1 && tabs.RunningBrowsersCalls == 1));

            // An equal list, built anew, changes nothing: the beat keeps waiting and no look happens.
            watcher.SetRules([new WatchedPathRule("x.com", "/")]);
            Thread.Sleep(300);
            Assert.Equal(1, tabs.RunningBrowsersCalls);
            Assert.Equal(1, clock.Parked(TimeSpan.FromSeconds(4)));

            // A different list is looked at without the clock moving, and the next wait uses the half-second interval of a path rule.
            watcher.SetRules([WholeX, Shorts]);
            Assert.True(Eventually(() => tabs.RunningBrowsersCalls == 2));
            Assert.True(Eventually(() => clock.Parked(TimeSpan.FromSeconds(0.5)) == 1));
            Assert.Equal(0, clock.Parked(TimeSpan.FromSeconds(4)));
        }
        finally
        {
            watcher.Dispose();
        }
    }

    [Fact]
    public void SetRules_PathRuleRemoved_NextWaitGoesBackToFourSeconds()
    {
        var (watcher, tabs, _, clock) = Make(WholeX, Shorts);
        tabs.Browsers.Clear();
        try
        {
            watcher.Start();
            Assert.True(Eventually(() => clock.Parked(TimeSpan.FromSeconds(0.5)) == 1));
            watcher.SetRules([WholeX]);
            Assert.True(Eventually(() => clock.Parked(TimeSpan.FromSeconds(4)) == 1));
            Assert.Equal(0, clock.Parked(TimeSpan.FromSeconds(0.5)));
        }
        finally
        {
            watcher.Dispose();
        }
    }
}

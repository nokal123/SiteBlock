using SiteBlock.AppLogic;
using SiteBlock.Core;

namespace SiteBlock.AppLogic.Tests;

public sealed class TabWatcherTests
{
    private const int Chrome = 4100;
    private const int Edge = 5200;
    private static readonly WatchedPathRule Shorts = new("youtube.com", "/shorts");

    private static (TabWatcher Watcher, FakeBrowserTabs Tabs, RecordingLog Log) Make(params WatchedPathRule[] rules)
    {
        var tabs = new FakeBrowserTabs();
        var log = new RecordingLog();
        var watcher = new TabWatcher(tabs, new ManualClock(), log);
        watcher.SetRules(rules);
        return (watcher, tabs, log);
    }

    [Fact]
    public async Task Tick_NoRules_MakesNoBrowserCallsAtAll()
    {
        var (watcher, tabs, _) = Make();
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        Assert.True(await watcher.TryRunTickAsync());
        Assert.Equal(0, tabs.TotalCalls);
    }

    [Fact]
    public async Task Tick_MatchingWindow_ReloadsItOnceAndLogsOnlyTheBrowserName()
    {
        var (watcher, tabs, log) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        Assert.Equal([(Chrome, "1")], tabs.Reloads);
        Assert.Equal(["reloaded a Google Chrome tab on a blocked part of a site"], log.Lines);
    }

    [Fact]
    public async Task Tick_SameAddressOnLaterTicks_IsNotReloadedAgain()
    {
        var (watcher, tabs, log) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        for (int i = 0; i < 4; i++) await watcher.TryRunTickAsync();
        Assert.Single(tabs.Reloads);
        Assert.Single(log.Lines);
    }

    [Fact]
    public async Task Tick_WindowMovesToAnotherBlockedAddress_IsReloadedAgain()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/def"));
        await watcher.TryRunTickAsync();
        Assert.Equal(2, tabs.Reloads.Count);
    }

    [Fact]
    public async Task Tick_WindowLeavesAndReturnsToSameBlockedAddress_IsReloadedAgain()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/"));
        await watcher.TryRunTickAsync();
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        Assert.Equal(2, tabs.Reloads.Count);
    }

    [Fact]
    public async Task Tick_SecondReadShowsWindowMovedOn_DoesNotReload()
    {
        var (watcher, tabs, log) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.CurrentOverrides[(Chrome, "1")] = "https://www.youtube.com/watch?v=xyz";
        await watcher.TryRunTickAsync();
        Assert.Equal([(Chrome, "1")], tabs.CurrentUrlCalls);
        Assert.Empty(tabs.Reloads);
        Assert.Empty(log.Lines);
    }

    [Fact]
    public async Task Tick_SecondReadUnreadable_DoesNotReload()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.CurrentOverrides[(Chrome, "1")] = null;
        await watcher.TryRunTickAsync();
        Assert.Empty(tabs.Reloads);
    }

    [Fact]
    public async Task Tick_NonMatchingWindows_AreLeftAloneWithoutSecondRead()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/watch?v=1"), ("2", "https://notyoutube.com/shorts/x"), ("3", "https://www.youtube.com/Shorts/x"), ("4", "https://www.youtube.com/shorts/x"));
        await watcher.TryRunTickAsync();
        Assert.Equal([(Chrome, "4")], tabs.Reloads);
        Assert.Equal([(Chrome, "4")], tabs.CurrentUrlCalls);
    }

    [Fact]
    public async Task Tick_TwoBrowsersWithSameWindowId_AreTrackedSeparately()
    {
        var (watcher, tabs, log) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.Browsers.Add(new BrowserProcess(Edge, "Microsoft Edge"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.SetWindows(Edge, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        Assert.Equal([(Chrome, "1"), (Edge, "1")], tabs.Reloads.OrderBy(r => r.Pid));
        Assert.Contains("reloaded a Microsoft Edge tab on a blocked part of a site", log.Lines);
    }

    [Fact]
    public async Task Tick_BrowserExitedAndIdReused_StartsWithNoMemory()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        tabs.Browsers.Clear();
        tabs.Browsers.Add(new BrowserProcess(Edge, "Microsoft Edge"));
        await watcher.TryRunTickAsync();
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        await watcher.TryRunTickAsync();
        Assert.Equal(2, tabs.Reloads.Count(r => r.Pid == Chrome));
    }

    [Fact]
    public async Task Tick_NoBrowserRunning_ForgetsEverything()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        tabs.Browsers.Clear();
        await watcher.TryRunTickAsync();
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        await watcher.TryRunTickAsync();
        Assert.Equal(2, tabs.Reloads.Count);
    }

    [Fact]
    public async Task Tick_BrowserUnreadableForOneTick_KeepsItsMemory()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        tabs.UnreadableProcesses.Add(Chrome);
        await watcher.TryRunTickAsync();
        tabs.UnreadableProcesses.Clear();
        await watcher.TryRunTickAsync();
        Assert.Single(tabs.Reloads);
    }

    [Fact]
    public async Task Tick_ReloadButtonFails_NoLogLineAndLaterTicksStillRun()
    {
        var (watcher, tabs, log) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        tabs.ReloadThrows = true;
        Assert.True(await watcher.TryRunTickAsync());
        Assert.Empty(log.Lines);
        tabs.ReloadThrows = false;
        tabs.SetWindows(Chrome, ("2", "https://m.youtube.com/shorts/q"));
        Assert.True(await watcher.TryRunTickAsync());
        Assert.Equal([(Chrome, "2")], tabs.Reloads);
    }

    [Fact]
    public async Task Tick_RulesReplacedWithNone_StopsTouchingBrowsers()
    {
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/abc"));
        await watcher.TryRunTickAsync();
        int calls = tabs.TotalCalls;
        watcher.SetRules([]);
        await watcher.TryRunTickAsync();
        Assert.Equal(calls, tabs.TotalCalls);
    }

    [Fact]
    public async Task Tick_ManyReloads_LogNeverHoldsRuleDomainOrAddress()
    {
        var rules = new[] { Shorts, new WatchedPathRule("instagram.com", "/reels") };
        var (watcher, tabs, log) = Make(rules);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.Browsers.Add(new BrowserProcess(Edge, "Microsoft Edge"));
        tabs.SetWindows(Chrome, ("1", "https://www.youtube.com/shorts/secret-video"), ("2", "https://www.instagram.com/reels/abc?utm=1"));
        tabs.SetWindows(Edge, ("9", "http://youtube.com/shorts/x#frag"));
        await watcher.TryRunTickAsync();
        Assert.Equal(3, log.Lines.Count);
        foreach (string line in log.Lines)
        {
            foreach (string forbidden in new[] { "youtube", "instagram", "shorts", "reels", "http", "/", "secret" }) Assert.DoesNotContain(forbidden, line, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public async Task TryRunTick_WhileAnotherTickRuns_IsSkippedNotQueued()
    {
        var (watcher, tabs, _) = Make(Shorts);
        var release = new ManualResetEventSlim(false);
        var entered = new ManualResetEventSlim(false);
        tabs.RunningBrowsersHook = () =>
        {
            entered.Set();
            release.Wait(TimeSpan.FromSeconds(5));
            return [];
        };
        Task<bool> first = watcher.TryRunTickAsync();
        Assert.True(entered.Wait(TimeSpan.FromSeconds(5)));
        Assert.False(await watcher.TryRunTickAsync());
        release.Set();
        Assert.True(await first);
        Assert.Equal(1, tabs.RunningBrowsersCalls);
    }

    [Fact]
    public void DeniedBrowserNames_IsAlwaysEmptyOnWindows()
    {
        var (watcher, _, _) = Make(Shorts);
        Assert.Empty(watcher.DeniedBrowserNames);
    }

    [Fact]
    public async Task Tick_AddressBarTextWithoutScheme_IsReloadedOnceGivenHttps()
    {
        // The reader turns the bare address-bar text into an address with BrowserAddress.ToUrl, as UiaBrowserTabs does.
        var (watcher, tabs, _) = Make(Shorts);
        tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        tabs.SetWindows(Chrome, ("1", BrowserAddress.ToUrl("youtube.com/shorts/abc")));
        await watcher.TryRunTickAsync();
        Assert.Single(tabs.Reloads);
    }
}

public sealed class BrowserAddressTests
{
    [Theory]
    [InlineData("youtube.com/shorts/abc", "https://youtube.com/shorts/abc")]
    [InlineData("www.youtube.com/shorts", "https://www.youtube.com/shorts")]
    [InlineData("  youtube.com/shorts  ", "https://youtube.com/shorts")]
    [InlineData("localhost:8080/shorts", "https://localhost:8080/shorts")]
    [InlineData("http://youtube.com/shorts", "http://youtube.com/shorts")]
    [InlineData("https://youtube.com/shorts", "https://youtube.com/shorts")]
    [InlineData("about:blank", "about:blank")]
    [InlineData("chrome://settings", "chrome://settings")]
    [InlineData("", "")]
    public void ToUrl_AddsHttpsOnlyWhenTextHasNoScheme(string text, string expected)
    {
        Assert.Equal(expected, BrowserAddress.ToUrl(text));
    }

    [Theory]
    [InlineData("youtube.com/shorts/abc?next=https://example.com", "https://youtube.com/shorts/abc?next=https://example.com")]
    [InlineData("youtube.com/shorts/abc#https://x.y", "https://youtube.com/shorts/abc#https://x.y")]
    public void ToUrl_SchemeLessTextWithAddressInQueryOrFragment_StillGetsHttps(string text, string expected)
    {
        // The text starts with a host, so it has no scheme; an address later in the query or fragment does not give it one.
        Assert.Equal(expected, BrowserAddress.ToUrl(text));
    }

    [Fact]
    public void ToUrl_SchemeLessShortsWithAddressInQuery_StillMatchesTheRule()
    {
        string url = BrowserAddress.ToUrl("youtube.com/shorts/abc?next=https://example.com");
        Assert.True(TabRuleMatcher.Matches(url, new WatchedPathRule("youtube.com", "/shorts")));
    }
}

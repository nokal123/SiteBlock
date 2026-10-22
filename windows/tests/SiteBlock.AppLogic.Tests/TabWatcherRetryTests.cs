using SiteBlock.AppLogic;
using SiteBlock.Core;

namespace SiteBlock.AppLogic.Tests;

// What the tab watcher does when a reload it decided on does not happen: the second read of the address gives nothing, or the reload button cannot be pressed.
// Expected values come from 06-windows.md § TabWatcher step 6: such a reload is tried again 5 seconds later, at most 3 times at the same address, and after that the tab is
// left alone until its address changes. "5 seconds later" is measured on IClock.MonotonicMilliseconds, the clock that ignores wall-clock changes (§ Tray App, Structure).
// The design's "tried again 5 seconds later, at most 3 times" is read here as 3 attempts in all (the first try and two retries), which is how the coordinator's brief states it.
// Each attempt reads the address again before pressing, so the fake's CurrentUrlCalls counts attempts, and Reloads counts presses that worked.
// The only log line the watcher writes is the reload line, so a failed attempt must write nothing (§ TabWatcher, last paragraph).
public sealed class TabWatcherRetryTests
{
    private const int Chrome = 4100;
    private const int Edge = 5200;
    private static readonly WatchedPathRule Shorts = new("youtube.com", "/shorts");
    private const string Blocked = "https://www.youtube.com/shorts/abc";
    private const string OtherBlocked = "https://www.youtube.com/shorts/def";
    private const string Home = "https://www.youtube.com/";
    private const string ReloadLine = "reloaded a Google Chrome tab on a blocked part of a site";

    private sealed class Rig
    {
        public FakeBrowserTabs Tabs { get; } = new();
        public ManualClock Clock { get; } = new();
        public RecordingLog Log { get; } = new();
        public TabWatcher Watcher { get; }
        // Monotonic milliseconds at which each attempt (each second read of a window's address) happened, filled by Tick.
        public List<long> AttemptTimes { get; } = [];

        public Rig()
        {
            Watcher = new TabWatcher(Tabs, Clock, Log);
            Watcher.SetRules([Shorts]);
            Tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
            Tabs.SetWindows(Chrome, ("1", Blocked));
        }

        public int Attempts => Tabs.CurrentUrlCalls.Count;

        // Runs one tick at the current clock time and records the time of every attempt it made.
        public async Task Tick()
        {
            int before = Attempts;
            Assert.True(await Watcher.TryRunTickAsync());
            for (int i = before; i < Attempts; i++) AttemptTimes.Add(Clock.MonotonicMilliseconds);
        }

        // Moves the clock forward in half-second beats, the watcher's own interval, running one tick after each, until the clock reads `untilMs`.
        public async Task TickUntil(long untilMs)
        {
            while (Clock.MonotonicMilliseconds < untilMs)
            {
                Clock.Advance(TimeSpan.FromMilliseconds(500));
                await Tick();
            }
        }
    }

    [Fact]
    public async Task ReloadButtonFails_IsNotTriedAgainBeforeFiveSecondsAndIsTriedAtFiveSeconds()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;

        await rig.Tick();
        await rig.TickUntil(4_500);
        Assert.Equal([0L], rig.AttemptTimes);

        await rig.TickUntil(5_000);
        Assert.Equal([0L, 5_000L], rig.AttemptTimes);
    }

    [Fact]
    public async Task ReloadButtonKeepsFailing_IsTriedThreeTimesFiveSecondsApartThenLeftAlone()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;

        await rig.Tick();
        await rig.TickUntil(60_000);

        Assert.Equal([0L, 5_000L, 10_000L], rig.AttemptTimes);
        Assert.Empty(rig.Tabs.Reloads);
        Assert.Empty(rig.Log.Lines);
    }

    [Fact]
    public async Task AfterThreeFailures_AWorkingButtonIsStillNotPressedWhileTheAddressStaysTheSame()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(10_000);
        Assert.Equal(3, rig.Attempts);

        rig.Tabs.ReloadThrows = false;
        await rig.TickUntil(60_000);

        Assert.Equal(3, rig.Attempts);
        Assert.Empty(rig.Tabs.Reloads);
    }

    [Fact]
    public async Task SecondReadGivesNothing_IsTriedAgainFiveSecondsLaterAndReloadsWhenItCanBeRead()
    {
        var rig = new Rig();
        // The address cannot be read again right now, for example because the person clicked into the address bar.
        rig.Tabs.CurrentOverrides[(Chrome, "1")] = null;

        await rig.Tick();
        await rig.TickUntil(4_500);
        Assert.Empty(rig.Tabs.Reloads);
        Assert.Equal(1, rig.Attempts);

        rig.Tabs.CurrentOverrides.Clear();
        await rig.TickUntil(5_000);

        Assert.Equal([(Chrome, "1")], rig.Tabs.Reloads);
        Assert.Equal([ReloadLine], rig.Log.Lines);
    }

    [Fact]
    public async Task SecondReadKeepsGivingNothing_CountsTowardTheSameCapOfThreeAttempts()
    {
        var rig = new Rig();
        rig.Tabs.CurrentOverrides[(Chrome, "1")] = null;

        await rig.Tick();
        await rig.TickUntil(60_000);

        Assert.Equal([0L, 5_000L, 10_000L], rig.AttemptTimes);
        Assert.Empty(rig.Log.Lines);
    }

    [Fact]
    public async Task ReloadWorksOnTheRetry_IsNotRepeatedWhileTheTabStaysAtThatAddress()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();

        rig.Tabs.ReloadThrows = false;
        await rig.TickUntil(60_000);

        Assert.Equal([0L, 5_000L], rig.AttemptTimes);
        Assert.Equal([(Chrome, "1")], rig.Tabs.Reloads);
        Assert.Equal([ReloadLine], rig.Log.Lines);
    }

    [Fact]
    public async Task AfterTheCap_AddressMovesToAnotherBlockedAddress_IsTriedAtOnceWithThreeFreshAttempts()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(20_000);
        Assert.Equal(3, rig.Attempts);

        rig.Tabs.SetWindows(Chrome, ("1", OtherBlocked));
        await rig.TickUntil(80_000);

        Assert.Equal([0L, 5_000L, 10_000L, 20_500L, 25_500L, 30_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task AfterTheCap_TabLeavesTheBlockedPartAndReturns_IsHandledFresh()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(20_000);
        Assert.Equal(3, rig.Attempts);

        rig.Tabs.SetWindows(Chrome, ("1", Home));
        await rig.TickUntil(21_000);
        rig.Tabs.SetWindows(Chrome, ("1", Blocked));
        await rig.TickUntil(80_000);

        Assert.Equal([0L, 5_000L, 10_000L, 21_500L, 26_500L, 31_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task TabLeavesTheBlockedPartBeforeItsRetryIsDue_ReturnsLaterAndIsHandledFresh()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();

        rig.Tabs.SetWindows(Chrome, ("1", Home));
        await rig.TickUntil(2_000);
        rig.Tabs.SetWindows(Chrome, ("1", Blocked));
        await rig.TickUntil(60_000);

        // Back on the blocked part at 2.5 s: a first try at once, then the two retries 5 seconds apart.
        Assert.Equal([0L, 2_500L, 7_500L, 12_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task TabIsOffTheBlockedPartJustWhenItsRetryFallsDue_ReturnsLaterAndIsHandledFresh()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(4_500);

        // The tick at 5 s, when the retry falls due, sees the tab on a page that is not blocked.
        rig.Tabs.SetWindows(Chrome, ("1", Home));
        await rig.TickUntil(5_000);
        Assert.Equal([0L], rig.AttemptTimes);
        rig.Tabs.SetWindows(Chrome, ("1", Blocked));
        await rig.TickUntil(60_000);

        // A tab that left the blocked path and came back is handled fresh: three attempts from its return at 5.5 s.
        Assert.Equal([0L, 5_500L, 10_500L, 15_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task WindowMissingFromTheListJustWhenItsRetryFallsDue_ReturnsLaterAndIsHandledFresh()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(4_500);

        // The address bar has keyboard focus at 5 s, so the window is left out of the list (IBrowserTabs.ReadWindows), then it is back on the same blocked address.
        rig.Tabs.SetWindows(Chrome);
        await rig.TickUntil(5_000);
        Assert.Equal([0L], rig.AttemptTimes);
        rig.Tabs.SetWindows(Chrome, ("1", Blocked));
        await rig.TickUntil(60_000);

        // § TabWatcher step 6: a tab missing from a look has left, so its count is dropped and its return at 5.5 s starts with all 3 tries, 5 seconds apart. The first
        // failure at 0 s is not counted against the return, so there are four attempts in all, not three.
        Assert.Equal([0L, 5_500L, 10_500L, 15_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task BrowserUnreadableWhenItsRetryFallsDue_IsRetriedOnTheNextTickItCanBeRead()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(4_500);

        rig.Tabs.UnreadableProcesses.Add(Chrome);
        await rig.TickUntil(5_000);
        rig.Tabs.UnreadableProcesses.Clear();
        rig.Tabs.ReloadThrows = false;
        await rig.TickUntil(30_000);

        Assert.Equal([0L, 5_500L], rig.AttemptTimes);
        Assert.Equal([(Chrome, "1")], rig.Tabs.Reloads);
    }

    [Fact]
    public async Task WallClockJumpsForward_DoesNotBringTheRetryForward()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();

        // The wall clock moves a day ahead while the monotonic clock moves only 1 second.
        rig.Clock.Now = rig.Clock.Now.AddDays(1);
        await rig.TickUntil(1_000);

        Assert.Equal([0L], rig.AttemptTimes);
    }

    [Fact]
    public async Task BrowserQuitsWhileAnotherKeepsRunning_ItsFailuresAreDroppedAndAReturningIdStartsFresh()
    {
        var rig = new Rig();
        rig.Tabs.Browsers.Add(new BrowserProcess(Edge, "Microsoft Edge"));
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(20_000);
        Assert.Equal(3, rig.Attempts);

        // Chrome quits; Edge keeps running, so ticks still look at browsers.
        rig.Tabs.Browsers.RemoveAll(browser => browser.ProcessId == Chrome);
        await rig.TickUntil(21_000);
        // A new Chrome process that happens to get the same process id and window handle.
        rig.Tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        await rig.TickUntil(80_000);

        Assert.Equal([0L, 5_000L, 10_000L, 21_500L, 26_500L, 31_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task EveryBrowserQuits_TheirFailuresAreDroppedAndAReturningIdStartsFresh()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(20_000);
        Assert.Equal(3, rig.Attempts);

        // No supported browser runs for one look.
        rig.Tabs.Browsers.Clear();
        await rig.TickUntil(21_000);
        rig.Tabs.Browsers.Add(new BrowserProcess(Chrome, "Google Chrome"));
        await rig.TickUntil(80_000);

        // The browser that quit dropped its state, so the returning one gets three attempts again.
        Assert.Equal([0L, 5_000L, 10_000L, 21_500L, 26_500L, 31_500L], rig.AttemptTimes);
    }

    [Fact]
    public async Task EveryRuleIsRemovedForOneLook_TheCountIsDroppedAndTheRestoredRuleGivesThreeFreshAttempts()
    {
        var rig = new Rig();
        rig.Tabs.ReloadThrows = true;
        await rig.Tick();
        await rig.TickUntil(20_000);
        Assert.Equal(3, rig.Attempts);

        // No path rule exists for the look at 20.5 s; the tab stays on the same blocked address the whole time.
        rig.Watcher.SetRules([]);
        await rig.TickUntil(20_500);
        rig.Watcher.SetRules([Shorts]);
        await rig.TickUntil(80_000);

        // § TabWatcher step 6: the count of every tab is dropped when no rule exists, so the restored rule finds the tab at 21 s and tries it 3 times, 5 seconds apart.
        Assert.Equal([0L, 5_000L, 10_000L, 21_000L, 26_000L, 31_000L], rig.AttemptTimes);
        Assert.Empty(rig.Tabs.Reloads);
    }

    [Fact]
    public async Task OneTabsFailingReload_DoesNotHoldBackAnotherTabOfTheSameBrowser()
    {
        var rig = new Rig();
        rig.Tabs.CurrentOverrides[(Chrome, "1")] = null;
        await rig.Tick();

        rig.Tabs.SetWindows(Chrome, ("1", Blocked), ("2", OtherBlocked));
        await rig.TickUntil(30_000);

        // Window 2 is reloaded once, at once; window 1, whose address never reads back, gets its three attempts and no reload.
        Assert.Equal([(Chrome, "2")], rig.Tabs.Reloads);
        Assert.Equal(3, rig.Tabs.CurrentUrlCalls.Count(call => call.Window == "1"));
        Assert.Equal(1, rig.Tabs.CurrentUrlCalls.Count(call => call.Window == "2"));
        Assert.Equal([ReloadLine], rig.Log.Lines);
    }
}

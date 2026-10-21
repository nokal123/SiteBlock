using SiteBlock.AppLogic;
using SiteBlock.Core;
using static SiteBlock.AppLogic.Tests.Fixtures;

namespace SiteBlock.AppLogic.Tests;

public sealed class StatusModelPollingTests
{
    private static readonly TimeSpan Fast = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan Slow = TimeSpan.FromSeconds(30);

    [Fact]
    public async Task Polling_PanelClosed_AsksOnceAtStartThenEveryThirtySeconds()
    {
        var clock = new ManualClock();
        var client = new FakeDaemonClient(Snapshot());
        using var status = new StatusModel(client, clock, new InlineUiDispatcher());
        status.Start();
        await Wait.Until(() => client.StatusCount == 1 && clock.Parked(Slow) == 1, "the first poll");
        clock.Advance(TimeSpan.FromMilliseconds(29_999));
        await Task.Delay(50);
        Assert.Equal(1, client.StatusCount);
        clock.Advance(TimeSpan.FromMilliseconds(1));
        await Wait.Until(() => client.StatusCount == 2 && clock.Parked(Slow) == 1, "the second poll");
        Assert.Equal(0, clock.Parked(Fast));
    }

    [Fact]
    public async Task Polling_PanelOpens_AsksAtOnceThenEverySecond()
    {
        var clock = new ManualClock();
        var client = new FakeDaemonClient(Snapshot());
        using var status = new StatusModel(client, clock, new InlineUiDispatcher());
        status.Start();
        await Wait.Until(() => client.StatusCount == 1 && clock.Parked(Slow) == 1, "the first poll");
        await status.PanelVisibilityChangedAsync(true);
        await Wait.Until(() => client.StatusCount == 2 && clock.Parked(Fast) == 1, "the poll on opening");
        Assert.Equal(0, clock.Parked(Slow));
        clock.Advance(TimeSpan.FromMilliseconds(999));
        await Task.Delay(50);
        Assert.Equal(2, client.StatusCount);
        clock.Advance(TimeSpan.FromMilliseconds(1));
        await Wait.Until(() => client.StatusCount == 3 && clock.Parked(Fast) == 1, "the next one-second poll");
    }

    [Fact]
    public async Task Polling_PanelClosesAgain_GoesBackToThirtySeconds()
    {
        var clock = new ManualClock();
        var client = new FakeDaemonClient(Snapshot());
        using var status = new StatusModel(client, clock, new InlineUiDispatcher());
        status.Start();
        await Wait.Until(() => client.StatusCount == 1 && clock.Parked(Slow) == 1, "the first poll");
        await status.PanelVisibilityChangedAsync(true);
        await Wait.Until(() => client.StatusCount == 2 && clock.Parked(Fast) == 1, "fast polling");
        await status.PanelVisibilityChangedAsync(false);
        int before = client.StatusCount;
        clock.Advance(Fast);
        await Wait.Until(() => client.StatusCount == before + 1 && clock.Parked(Slow) == 1, "the poll that switches back to 30 seconds");
        clock.Advance(TimeSpan.FromSeconds(29));
        await Task.Delay(50);
        Assert.Equal(before + 1, client.StatusCount);
    }

    [Fact]
    public async Task Refresh_EqualSnapshotBuiltSeparately_IsNotPublishedAgain()
    {
        var clock = new ManualClock();
        var client = new FakeDaemonClient(Snapshot(sites: [Site("reddit.com", pending: 100)], paths: [Rule("youtube.com", "/shorts", temporary: Waiting(50, 900))]));
        var status = new StatusModel(client, clock, new InlineUiDispatcher());
        await status.RefreshAsync();
        long arrived = status.SnapshotArrivedAt;
        var changes = new List<string?>();
        status.PropertyChanged += (_, e) => changes.Add(e.PropertyName);
        clock.Advance(TimeSpan.FromSeconds(1));
        // A new object with the same values, as a fresh reply from the pipe would be.
        client.Snapshot = Snapshot(sites: [Site("reddit.com", pending: 100)], paths: [Rule("youtube.com", "/shorts", temporary: Waiting(50, 900))]);
        await status.RefreshAsync();
        Assert.DoesNotContain(nameof(StatusModel.Snapshot), changes);
        Assert.DoesNotContain(nameof(StatusModel.SnapshotArrivedAt), changes);
        Assert.Equal(arrived, status.SnapshotArrivedAt);
    }

    [Fact]
    public async Task Refresh_ChangedSnapshot_IsPublishedWithItsArrivalTime()
    {
        var clock = new ManualClock();
        var client = new FakeDaemonClient(Snapshot(sites: [Site("reddit.com", pending: 100)]));
        var status = new StatusModel(client, clock, new InlineUiDispatcher());
        await status.RefreshAsync();
        clock.Advance(TimeSpan.FromSeconds(3));
        client.Snapshot = Snapshot(sites: [Site("reddit.com", pending: 97)]);
        await status.RefreshAsync();
        Assert.Equal(97, status.Snapshot!.Blocked[0].UnblockSecondsRemaining);
        Assert.Equal(3000, status.SnapshotArrivedAt);
    }
}

public sealed class StatusModelWatchedRulesTests
{
    private static async Task<TabWatcher> Apply(StatusSnapshot snapshot)
    {
        var watcher = new TabWatcher(new FakeBrowserTabs(), new ManualClock());
        var status = new StatusModel(new FakeDaemonClient(snapshot), new ManualClock(), new InlineUiDispatcher(), tabWatcher: watcher);
        await status.RefreshAsync();
        return watcher;
    }

    [Fact]
    public async Task ApplyStatus_PassesEveryRuleExceptThoseWithAnOpenTemporaryUnblock()
    {
        TabWatcher watcher = await Apply(Snapshot(paths:
        [
            Rule("youtube.com", "/shorts"),
            Rule("instagram.com", "/reels", pending: 600),
            Rule("tiktok.com", "/foryou", temporary: Waiting(300, 900)),
            Rule("reddit.com", "/r/all", temporary: Open(200, 900)),
        ]));
        Assert.Equal([new WatchedPathRule("youtube.com", "/shorts"), new WatchedPathRule("instagram.com", "/reels"), new WatchedPathRule("tiktok.com", "/foryou")], watcher.Rules);
    }

    [Fact]
    public async Task ApplyStatus_WholeSiteTemporarilyOpen_KeepsThatSitesPathRule()
    {
        TabWatcher watcher = await Apply(Snapshot(sites: [Site("youtube.com", temporary: Open(200, 900))], paths: [Rule("youtube.com", "/shorts")]));
        Assert.Equal([new WatchedPathRule("youtube.com", "/shorts")], watcher.Rules);
    }

    [Fact]
    public async Task ApplyStatus_EveryRuleOpen_GivesTheWatcherNoRules()
    {
        TabWatcher watcher = await Apply(Snapshot(paths: [Rule("youtube.com", "/shorts", temporary: Open(200, 900))]));
        Assert.Empty(watcher.Rules);
    }

    [Fact]
    public async Task ApplyStatus_TemporaryUnblockEnds_RuleIsWatchedAgain()
    {
        var watcher = new TabWatcher(new FakeBrowserTabs(), new ManualClock());
        var client = new FakeDaemonClient(Snapshot(paths: [Rule("youtube.com", "/shorts", temporary: Open(200, 900))]));
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher(), tabWatcher: watcher);
        await status.RefreshAsync();
        Assert.Empty(watcher.Rules);
        client.Snapshot = Snapshot(paths: [Rule("youtube.com", "/shorts")]);
        await status.RefreshAsync();
        Assert.Equal([new WatchedPathRule("youtube.com", "/shorts")], watcher.Rules);
    }

    [Fact]
    public async Task ApplyStatus_CommandReply_PassesItsRulesAtOnce()
    {
        var watcher = new TabWatcher(new FakeBrowserTabs(), new ManualClock());
        var client = new FakeDaemonClient(Snapshot());
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher(), tabWatcher: watcher);
        await status.RefreshAsync();
        client.Handler = r => Task.FromResult(Response.Success(Snapshot(paths: [Rule("youtube.com", "/shorts")])));
        await status.AddPathAsync("youtube.com/shorts");
        Assert.Equal([new WatchedPathRule("youtube.com", "/shorts")], watcher.Rules);
    }
}

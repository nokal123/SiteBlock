using SiteBlock.AppLogic;
using SiteBlock.Core;
using static SiteBlock.AppLogic.Tests.Fixtures;

namespace SiteBlock.AppLogic.Tests;

public sealed class RowPresentationTests
{
    private static RowItem SiteItem(long? pending = null, TemporaryUnblockStatus? temporary = null) => RowItem.FromSite(Site("reddit.com", pending, temporary));
    private static RowItem RuleItem(long? pending = null, TemporaryUnblockStatus? temporary = null) => RowItem.FromRule(Rule("youtube.com", "/shorts", pending, temporary));

    // The full countdown line as a person reads it: the bold lead (if any), a space, then the rest.
    private static string? Line(RowPresentation p) => p.LineLead is null ? p.LineText : p.LineLead + " " + p.LineText;

    [Theory]
    [InlineData(RowKind.Site)]
    [InlineData(RowKind.Rule)]
    public void Build_PlainBlocked_NeutralClosedLockUnblockButtonNoLine(RowKind kind)
    {
        RowItem item = kind == RowKind.Site ? SiteItem() : RuleItem();
        RowPresentation p = RowPresentation.Build(item, UnblockStep.Closed, canUnblock: true, 0, 0);
        Assert.Equal(SiteTone.Neutral, p.Tone);
        Assert.Equal(LockIcon.Closed, p.Icon);
        Assert.Equal(RowButton.Unblock, p.Button);
        Assert.Equal("Unblock…", p.ButtonLabel);
        Assert.Null(Line(p));
    }

    [Theory]
    [InlineData(RowKind.Site)]
    [InlineData(RowKind.Rule)]
    public void Build_PendingPermanentUnblock_RedClockKeepBlockedAndStillBlockedLine(RowKind kind)
    {
        RowItem item = kind == RowKind.Site ? SiteItem(pending: 1781) : RuleItem(pending: 1781);
        RowPresentation p = RowPresentation.Build(item, UnblockStep.Closed, canUnblock: true, pendingLeft: 1781, 0);
        Assert.Equal(SiteTone.Blocked, p.Tone);
        Assert.Equal(LockIcon.Clock, p.Icon);
        Assert.Equal(RowButton.KeepBlocked, p.Button);
        Assert.Equal("Keep blocked", p.ButtonLabel);
        Assert.Equal("Still blocked · unblocks in 29:41", Line(p));
    }

    [Theory]
    [InlineData(RowKind.Site)]
    [InlineData(RowKind.Rule)]
    public void Build_WaitingTemporaryUnblock_RedClockKeepBlockedAndOpensInLine(RowKind kind)
    {
        TemporaryUnblockStatus waiting = Waiting(opensIn: 2530, window: 3600);
        RowItem item = kind == RowKind.Site ? SiteItem(temporary: waiting) : RuleItem(temporary: waiting);
        RowPresentation p = RowPresentation.Build(item, UnblockStep.Closed, canUnblock: true, 0, temporaryLeft: 2530);
        Assert.Equal(SiteTone.Blocked, p.Tone);
        Assert.Equal(LockIcon.Clock, p.Icon);
        Assert.Equal(RowButton.KeepBlocked, p.Button);
        Assert.Equal("Keep blocked", p.ButtonLabel);
        Assert.Equal("Opens in 42:10 for 1 hour — still blocked", Line(p));
    }

    [Theory]
    [InlineData(RowKind.Site)]
    [InlineData(RowKind.Rule)]
    public void Build_OpenTemporaryUnblock_GreenOpenLockBlockNowAndBlocksAgainLine(RowKind kind)
    {
        TemporaryUnblockStatus open = Open(left: 2225, window: 3600);
        RowItem item = kind == RowKind.Site ? SiteItem(temporary: open) : RuleItem(temporary: open);
        RowPresentation p = RowPresentation.Build(item, UnblockStep.Closed, canUnblock: true, 0, temporaryLeft: 2225);
        Assert.Equal(SiteTone.Open, p.Tone);
        Assert.Equal(LockIcon.Open, p.Icon);
        Assert.Equal(RowButton.BlockNow, p.Button);
        Assert.Equal("Block now", p.ButtonLabel);
        Assert.Equal("Unblocked — blocks again in 37:05", Line(p));
    }

    [Theory]
    [InlineData(900, "Opens in 5:03 for 15 minutes — still blocked")]
    [InlineData(1800, "Opens in 5:03 for 30 minutes — still blocked")]
    [InlineData(7200, "Opens in 5:03 for 2 hours — still blocked")]
    [InlineData(14400, "Opens in 5:03 for 4 hours — still blocked")]
    public void Build_WaitingTemporaryUnblock_NamesTheWindowLength(long window, string expected)
    {
        RowPresentation p = RowPresentation.Build(SiteItem(temporary: Waiting(303, window)), UnblockStep.Closed, true, 0, temporaryLeft: 303);
        Assert.Equal(expected, Line(p));
    }

    [Fact]
    public void Build_WaitingTemporaryUnblockOverAnHour_UsesHourClock()
    {
        RowPresentation p = RowPresentation.Build(SiteItem(temporary: Waiting(3909, 3600)), UnblockStep.Closed, true, 0, temporaryLeft: 3909);
        Assert.Equal("Opens in 1:05:09 for 1 hour — still blocked", Line(p));
    }

    [Fact]
    public async Task Present_TimePassesBetweenPolls_CountdownLinesMoveDown()
    {
        var clock = new ManualClock();
        var client = new FakeDaemonClient(Snapshot(sites: [Site("reddit.com", pending: 1781)], paths: [Rule("youtube.com", "/shorts", temporary: Open(2225, 3600))]));
        var status = new StatusModel(client, clock, new InlineUiDispatcher());
        var list = new BlockedListModel(status);
        await status.RefreshAsync();
        list.Update(status.Snapshot!);
        clock.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal("Still blocked · unblocks in 29:31", Line(list.SiteRows[0].Present()));
        Assert.Equal("Unblocked — blocks again in 36:55", Line(list.RuleRows[0].Present()));
    }

    [Fact]
    public async Task Present_NoPassword_PlainRowHasNoButton()
    {
        var client = new FakeDaemonClient(Snapshot(passwordSet: false, sites: [Site("reddit.com")]));
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        await status.RefreshAsync();
        var row = new BlockedRowModel(status, RowItem.FromSite(status.Snapshot!.Blocked[0]));
        Assert.Equal(RowButton.None, row.Present().Button);
    }

    [Theory]
    [InlineData(RowKind.Site, false, Command.CancelUnblock)]
    [InlineData(RowKind.Site, true, Command.CancelUnblock)]
    [InlineData(RowKind.Rule, false, Command.CancelUnblockPath)]
    [InlineData(RowKind.Rule, true, Command.CancelUnblockPath)]
    public async Task KeepBlockedOrBlockNow_SendsCancelWithNoPassword(RowKind kind, bool open, Command expected)
    {
        TemporaryUnblockStatus temporary = open ? Open(100, 900) : Waiting(100, 900);
        var client = new FakeDaemonClient(Snapshot());
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        await status.RefreshAsync();
        RowItem item = kind == RowKind.Site ? SiteItem(temporary: temporary) : RuleItem(temporary: temporary);
        var row = new BlockedRowModel(status, item);
        await row.KeepBlockedAsync();
        Request sent = Assert.Single(client.Commands);
        Assert.Equal(expected, sent.Command);
        Assert.Equal(kind == RowKind.Site ? "reddit.com" : "youtube.com/shorts", sent.Domain);
        Assert.Null(sent.Password);
    }
}

public sealed class ToneColorTests
{
    // An opacity byte within half a step of the percentage, which is the closest an 8-bit alpha can get.
    private static void AssertAlpha(double fraction, byte alpha) => Assert.InRange(alpha, Math.Floor(fraction * 255), Math.Ceiling(fraction * 255));

    [Theory]
    [InlineData(SiteTone.Blocked, false, 0x9E, 0x3A, 0x2F)]
    [InlineData(SiteTone.Blocked, true, 0xE0, 0x8A, 0x78)]
    [InlineData(SiteTone.Open, false, 0x3D, 0x6B, 0x4A)]
    [InlineData(SiteTone.Open, true, 0x8C, 0xC2, 0x9B)]
    public void Accent_IsTheFullStrengthToneColor(SiteTone tone, bool dark, int r, int g, int b)
    {
        Argb color = ToneColors.Accent(tone, dark)!.Value;
        Assert.Equal(new Argb(255, (byte)r, (byte)g, (byte)b), color);
    }

    [Theory]
    [InlineData(SiteTone.Blocked, false, 0x9E3A2F, 0.07, 0.22)]
    [InlineData(SiteTone.Blocked, true, 0xE08A78, 0.13, 0.30)]
    [InlineData(SiteTone.Open, false, 0x3D6B4A, 0.07, 0.22)]
    [InlineData(SiteTone.Open, true, 0x8CC29B, 0.13, 0.30)]
    public void FillAndEdge_AreTheToneAtTheDesignOpacities(SiteTone tone, bool dark, uint rgb, double fill, double edge)
    {
        Argb f = ToneColors.Fill(tone, dark)!.Value;
        Argb e = ToneColors.Edge(tone, dark)!.Value;
        Assert.Equal(((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb), (f.R, f.G, f.B));
        Assert.Equal(((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb), (e.R, e.G, e.B));
        AssertAlpha(fill, f.A);
        AssertAlpha(edge, e.A);
    }

    [Fact]
    public void Neutral_HasNoTint()
    {
        Assert.Null(ToneColors.Accent(SiteTone.Neutral, false));
        Assert.Null(ToneColors.Fill(SiteTone.Neutral, true));
        Assert.Null(ToneColors.Edge(SiteTone.Neutral, false));
    }

    [Theory]
    [InlineData(false, 0x9E, 0x3A, 0x2F)]
    [InlineData(true, 0xB0, 0x4A, 0x3D)]
    public void KeepBlockedAndBlockNowButtonFill_IsTheBlockedRed(bool dark, int r, int g, int b)
    {
        // Both "Keep blocked" and "Block now" are filled in the blocked red, darker in dark mode.
        Assert.Equal(new Argb(255, (byte)r, (byte)g, (byte)b), ToneColors.ButtonFill(SiteTone.Blocked, dark)!.Value);
    }
}

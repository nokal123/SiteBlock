using SiteBlock.AppLogic;
using SiteBlock.Core;
using static SiteBlock.AppLogic.Tests.Fixtures;

namespace SiteBlock.AppLogic.Tests;

public sealed class TemporaryUnblockFormTests
{
    [Fact]
    public void WindowPicker_StartsOnChooseAndOffersTheFiveWindows()
    {
        var form = new TemporaryUnblockFormModel(1800);
        Assert.Null(form.WindowSeconds);
        Assert.Equal("Choose…", form.WindowLabel);
        Assert.Equal([(null, "Choose…"), (900, "15 minutes"), (1800, "30 minutes"), (3600, "1 hour"), (7200, "2 hours"), (14400, "4 hours")], form.WindowOptions.Select(o => (o.Value, o.Label)));
    }

    [Fact]
    public void StartPicker_ThirtyMinuteDelay_OffersSoonestThenEachLongerFixedWait()
    {
        var form = new TemporaryUnblockFormModel(1800);
        Assert.Equal(1800, form.StartSeconds);
        Assert.Equal(
            [(1800, "30 minutes (soonest)"), (7200, "2 hours"), (10800, "3 hours"), (14400, "4 hours"), (21600, "6 hours"), (28800, "8 hours"), (43200, "12 hours"), (86400, "24 hours")],
            form.StartOptions.Select(o => (o.Value!.Value, o.Label)));
    }

    [Fact]
    public void StartPicker_DelayExactlyTwoHours_DoesNotOfferTwoHoursTwice()
    {
        var form = new TemporaryUnblockFormModel(7200);
        Assert.Equal([7200, 10800, 14400, 21600, 28800, 43200, 86400], form.StartOptions.Select(o => o.Value!.Value));
        Assert.Equal("2 hours (soonest)", form.StartOptions[0].Label);
    }

    [Theory]
    [InlineData(86400, "24 hours (soonest)")]
    [InlineData(604800, "7 days (soonest)")]
    public void StartPicker_DelayOfADayOrMore_OffersOnlyTheDelay(int delay, string label)
    {
        var form = new TemporaryUnblockFormModel(delay);
        PickerOption only = Assert.Single(form.StartOptions);
        Assert.Equal((delay, label), (only.Value!.Value, only.Label));
    }

    [Fact]
    public void StartPicker_FiveHourDelay_OffersOnlyLongerWaitsAfterTheSoonest()
    {
        var form = new TemporaryUnblockFormModel(18000);
        Assert.Equal([18000, 21600, 28800, 43200, 86400], form.StartOptions.Select(o => o.Value!.Value));
        Assert.Equal("5 hours (soonest)", form.StartOptions[0].Label);
    }

    [Theory]
    [InlineData(null, "", false)]
    [InlineData(3600, "", false)]
    [InlineData(null, "secret123", false)]
    [InlineData(3600, "secret123", true)]
    public void CanSubmit_NeedsBothAWindowAndAPassword(int? window, string password, bool expected)
    {
        var form = new TemporaryUnblockFormModel(1800) { WindowSeconds = window, Password = password };
        Assert.Equal(expected, form.CanSubmit(busy: false));
    }

    private static async Task<(BlockedRowModel Row, FakeDaemonClient Client)> OpenForm(bool rule)
    {
        StatusSnapshot snapshot = rule ? Snapshot(delay: 1800, paths: [Rule("youtube.com", "/shorts")]) : Snapshot(delay: 1800, sites: [Site("reddit.com")]);
        var client = new FakeDaemonClient(snapshot);
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        await status.RefreshAsync();
        var list = new BlockedListModel(status);
        list.Update(status.Snapshot!);
        BlockedRowModel row = rule ? list.RuleRows[0] : list.SiteRows[0];
        row.OpenChoice();
        row.ChooseForAWhile();
        return (row, client);
    }

    [Fact]
    public async Task Schedule_Site_SendsTemporaryUnblockWithWindowAndSoonestStart()
    {
        var (row, client) = await OpenForm(rule: false);
        TemporaryUnblockFormModel form = row.TemporaryForm!;
        form.WindowSeconds = 3600;
        form.Password = "secret123";
        Assert.True(await row.ScheduleTemporaryAsync());
        Assert.Equal(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: "secret123", Seconds: 3600, StartSeconds: 1800), Assert.Single(client.Commands));
    }

    [Fact]
    public async Task Schedule_RuleWithLaterStart_SendsTemporaryUnblockPathWithPickedStart()
    {
        var (row, client) = await OpenForm(rule: true);
        TemporaryUnblockFormModel form = row.TemporaryForm!;
        form.WindowSeconds = 900;
        form.PickedStart = 21600;
        form.Password = "secret123";
        Assert.True(await row.ScheduleTemporaryAsync());
        Assert.Equal(new Request(Command.TemporaryUnblockPath, Domain: "youtube.com/shorts", Password: "secret123", Seconds: 900, StartSeconds: 21600), Assert.Single(client.Commands));
    }

    [Fact]
    public async Task Schedule_WithoutWindow_SendsNothing()
    {
        var (row, client) = await OpenForm(rule: false);
        row.TemporaryForm!.Password = "secret123";
        Assert.False(await row.ScheduleTemporaryAsync());
        Assert.Empty(client.Commands);
        Assert.Equal("secret123", row.TemporaryForm!.Password);
    }

    [Fact]
    public async Task Schedule_Pressed_EmptiesPasswordBeforeTheServiceAnswers()
    {
        var (row, client) = await OpenForm(rule: false);
        var answer = new TaskCompletionSource<Response>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Handler = r => r.Command == Command.Status ? Task.FromResult(Response.Success(client.Snapshot)) : answer.Task;
        TemporaryUnblockFormModel form = row.TemporaryForm!;
        form.WindowSeconds = 1800;
        form.Password = "secret123";
        Task<bool> pressing = row.ScheduleTemporaryAsync();
        await Wait.Until(() => client.Commands.Count == 1, "the request to be sent");
        Assert.Equal("", form.Password);
        answer.SetResult(Response.Success(client.Snapshot));
        Assert.True(await pressing);
    }

    [Fact]
    public async Task Schedule_Accepted_ClosesTheForm()
    {
        var (row, _) = await OpenForm(rule: false);
        row.TemporaryForm!.WindowSeconds = 1800;
        row.TemporaryForm!.Password = "secret123";
        await row.ScheduleTemporaryAsync();
        Assert.Null(row.TemporaryForm);
        Assert.Equal(UnblockStep.Closed, row.Step);
    }

    [Fact]
    public async Task Schedule_Refused_FormStaysOpenWithPicksKeptPasswordEmptyAndCursorInPassword()
    {
        var (row, client) = await OpenForm(rule: false);
        client.Handler = r => Task.FromResult(r.Command == Command.Status ? Response.Success(client.Snapshot) : Response.Failure(ErrorCode.WrongPassword, "Wrong password."));
        TemporaryUnblockFormModel form = row.TemporaryForm!;
        form.WindowSeconds = 7200;
        form.PickedStart = 10800;
        form.Password = "wrong-one";
        Assert.False(await row.ScheduleTemporaryAsync());
        Assert.Same(form, row.TemporaryForm);
        Assert.Equal(UnblockStep.ForAWhile, row.Step);
        Assert.Equal(7200, form.WindowSeconds);
        Assert.Equal(10800, form.StartSeconds);
        Assert.Equal("", form.Password);
        Assert.True(form.FocusPasswordRequested);
    }

    [Fact]
    public async Task Schedule_RefusedThenRetypedPassword_SendsTheKeptPicksAgain()
    {
        var (row, client) = await OpenForm(rule: false);
        int calls = 0;
        client.Handler = r => Task.FromResult(r.Command == Command.Status || ++calls > 1 ? Response.Success(client.Snapshot) : Response.Failure(ErrorCode.WrongPassword, "Wrong password."));
        TemporaryUnblockFormModel form = row.TemporaryForm!;
        form.WindowSeconds = 14400;
        form.Password = "wrong-one";
        await row.ScheduleTemporaryAsync();
        form.Password = "secret123";
        Assert.True(await row.ScheduleTemporaryAsync());
        Assert.Equal(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: "secret123", Seconds: 14400, StartSeconds: 1800), client.Commands[^1]);
    }

    [Fact]
    public async Task ChooseForAWhile_UsesTheCurrentDelayAsSoonest()
    {
        var client = new FakeDaemonClient(Snapshot(delay: 3600, sites: [Site("reddit.com")]));
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        await status.RefreshAsync();
        var row = new BlockedRowModel(status, RowItem.FromSite(status.Snapshot!.Blocked[0]));
        row.ChooseForAWhile();
        Assert.Equal(3600, row.TemporaryForm!.StartSeconds);
        Assert.Equal("1 hour (soonest)", row.TemporaryForm!.StartLabelText);
    }

    [Fact]
    public void ScheduleText_WithAndWithoutWindow_GivesOpeningAndClosingTimes()
    {
        var form = new TemporaryUnblockFormModel(1800);
        var now = new DateTimeOffset(2026, 10, 22, 15, 12, 0, TimeSpan.Zero);
        var culture = System.Globalization.CultureInfo.GetCultureInfo("en-US");
        string before = form.ScheduleText(now, TimeZoneInfo.Utc, culture);
        form.WindowSeconds = 3600;
        string after = form.ScheduleText(now, TimeZoneInfo.Utc, culture);
        Assert.Equal("Opens at 3:42 PM.", before.Replace(' ', ' '));
        Assert.Equal("Opens at 3:42 PM, blocks again at 4:42 PM.", after.Replace(' ', ' '));
    }
}

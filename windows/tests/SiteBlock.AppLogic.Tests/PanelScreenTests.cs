using SiteBlock.AppLogic;
using SiteBlock.Core;
using static SiteBlock.AppLogic.Tests.Fixtures;

namespace SiteBlock.AppLogic.Tests;

public sealed class PanelScreenTests
{
    private static (PanelModel Panel, StatusModel Status, FakeDaemonClient Client) Make(StatusSnapshot snapshot)
    {
        var client = new FakeDaemonClient(snapshot);
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        return (new PanelModel(status), status, client);
    }

    [Fact]
    public void Screen_BeforeAnyAnswer_IsConnecting()
    {
        var (panel, _, _) = Make(Snapshot());
        Assert.Equal(PanelScreen.Connecting, panel.Screen);
    }

    [Fact]
    public async Task Screen_ServiceNotRunning_ShowsNotRunningWithInstallCmdRepair()
    {
        var (panel, status, client) = Make(Snapshot());
        client.Handler = _ => throw new DaemonClientException(ClientError.NotRunning);
        await status.RefreshAsync();
        Assert.Equal(PanelScreen.NotRunning, panel.Screen);
        Assert.Equal("The SiteBlock service isn't running.", panel.NotRunningMessage);
        Assert.Contains("double-click", PanelModel.NotRunningRepair, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Install SiteBlock.cmd", PanelModel.NotRunningRepair, StringComparison.Ordinal);
        Assert.True(status.ServiceUnreachable);
    }

    [Fact]
    public async Task Screen_ServiceComesBackAfterNotRunning_ReturnsToHome()
    {
        var (panel, status, client) = Make(Snapshot());
        client.Handler = _ => throw new DaemonClientException(ClientError.NotRunning);
        await status.RefreshAsync();
        client.Handler = null;
        await status.RefreshAsync();
        Assert.Equal(PanelScreen.Home, panel.Screen);
        Assert.False(status.ServiceUnreachable);
    }

    [Fact]
    public async Task Screen_SettingsOpenedWithPassword_ShowsSettingsAndBackReturnsHome()
    {
        var (panel, status, _) = Make(Snapshot(passwordSet: true));
        await status.RefreshAsync();
        Assert.Equal(PanelScreen.Home, panel.Screen);
        panel.OpenSettings();
        Assert.Equal(PanelScreen.Settings, panel.Screen);
        panel.CloseSettings();
        Assert.Equal(PanelScreen.Home, panel.Screen);
    }

    [Fact]
    public async Task Screen_PanelClosesWhileOnSettings_ReopensOnHome()
    {
        var (panel, status, _) = Make(Snapshot(passwordSet: true));
        await status.RefreshAsync();
        panel.OpenSettings();
        await panel.PanelVisibilityChangedAsync(true);
        await panel.PanelVisibilityChangedAsync(false);
        Assert.Equal(PanelScreen.Home, panel.Screen);
    }

    [Fact]
    public async Task Banners_HealthySnapshotWithPathRules_HasNoBannerAtAll()
    {
        // Windows has no browser-permission banner, so path rules alone never produce a banner.
        var (panel, status, _) = Make(Snapshot(paths: [Rule("youtube.com", "/shorts")]));
        await status.RefreshAsync();
        Assert.Empty(panel.CurrentBanners());
        Assert.False(panel.HasBannerContent);
    }

    [Fact]
    public void BannerKinds_HaveNoPermissionBanner()
    {
        Assert.DoesNotContain(Enum.GetNames<BannerKind>(), name => name.Contains("Permission", StringComparison.OrdinalIgnoreCase) || name.Contains("Automation", StringComparison.OrdinalIgnoreCase));
    }
}

public sealed class FirstBlockAndPasswordTests
{
    private static (HomeModel Home, StatusModel Status, FakeDaemonClient Client) Make(StatusSnapshot snapshot)
    {
        var client = new FakeDaemonClient(snapshot);
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        return (new HomeModel(status), status, client);
    }

    [Fact]
    public async Task PressBlock_NoPasswordYet_OpensPasswordFormAndSendsNothing()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false));
        await status.RefreshAsync();
        home.AddText = "reddit.com";
        bool accepted = await home.PressBlockAsync();
        Assert.False(accepted);
        Assert.Empty(client.Commands);
        Assert.True(home.IsChoosingFirstPassword);
        Assert.Equal("reddit.com", home.AddText);
        Assert.Equal("Choose a SiteBlock password", SetupFormModel.Title);
        Assert.Equal("Set password and block", home.FirstBlockForm.SubmitTitle);
    }

    [Fact]
    public async Task FirstBlockForm_Mismatch_ShowsInlineAndSendsNothing()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false));
        await status.RefreshAsync();
        home.AddText = "reddit.com";
        await home.PressBlockAsync();
        home.FirstBlockForm.Password = "secret123";
        home.FirstBlockForm.Confirmation = "secret124";
        Assert.False(await home.FirstBlockForm.SubmitAsync());
        Assert.NotNull(home.FirstBlockForm.LocalProblem);
        Assert.Empty(client.Commands);
    }

    [Fact]
    public async Task FirstBlockForm_PasswordUnderSixCharacters_ShowsInlineAndSendsNothing()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false));
        await status.RefreshAsync();
        home.AddText = "reddit.com";
        await home.PressBlockAsync();
        home.FirstBlockForm.Password = "12345";
        home.FirstBlockForm.Confirmation = "12345";
        Assert.False(await home.FirstBlockForm.SubmitAsync());
        Assert.NotNull(home.FirstBlockForm.LocalProblem);
        Assert.Empty(client.Commands);
    }

    [Fact]
    public async Task FirstBlockForm_ValidPassword_SendsSetupThenAddForTheTypedSite()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false));
        await status.RefreshAsync();
        client.Handler = request => Task.FromResult(request.Command switch
        {
            Command.Setup => Response.Success(Snapshot(passwordSet: true)),
            Command.Add => Response.Success(Snapshot(passwordSet: true, sites: [Site("reddit.com")])),
            _ => Response.Success(client.Snapshot),
        });
        home.AddText = "reddit.com";
        await home.PressBlockAsync();
        home.FirstBlockForm.Password = "secret123";
        home.FirstBlockForm.Confirmation = "secret123";
        Assert.True(await home.FirstBlockForm.SubmitAsync());
        IReadOnlyList<Request> commands = client.Commands;
        Assert.Equal(2, commands.Count);
        Assert.Equal(new Request(Command.Setup, Password: "secret123"), commands[0]);
        Assert.Equal(Command.Add, commands[1].Command);
        Assert.Equal("reddit.com", commands[1].Domain);
        Assert.False(home.IsChoosingFirstPassword);
    }

    [Fact]
    public async Task FirstBlockForm_SetupRefused_DoesNotSendAdd()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false));
        await status.RefreshAsync();
        client.Handler = request => Task.FromResult(request.Command == Command.Setup ? Response.Failure(ErrorCode.NotAllowed, "Not allowed.") : Response.Success(client.Snapshot));
        home.AddText = "reddit.com";
        await home.PressBlockAsync();
        home.FirstBlockForm.Password = "secret123";
        home.FirstBlockForm.Confirmation = "secret123";
        Assert.False(await home.FirstBlockForm.SubmitAsync());
        Assert.DoesNotContain(client.Commands, r => r.Command is Command.Add or Command.AddPath);
        Assert.True(home.IsChoosingFirstPassword);
    }

    [Fact]
    public async Task FirstBlockForm_TypedTextHasPath_SendsAddPathAfterSetup()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false));
        await status.RefreshAsync();
        client.Handler = request => Task.FromResult(Response.Success(Snapshot(passwordSet: true)));
        home.AddText = "youtube.com/shorts";
        await home.PressBlockAsync();
        home.FirstBlockForm.Password = "secret123";
        home.FirstBlockForm.Confirmation = "secret123";
        await home.FirstBlockForm.SubmitAsync();
        Assert.Equal([Command.Setup, Command.AddPath], client.Commands.Select(r => r.Command));
        Assert.Equal("youtube.com/shorts", client.Commands[1].Domain);
    }

    [Fact]
    public async Task NeedsNewPassword_NoPasswordButSitesBlocked_IsTrueAndRowsHaveNoUnblockButton()
    {
        var client = new FakeDaemonClient(Snapshot(passwordSet: false, sites: [Site("reddit.com")]));
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        var panel = new PanelModel(status);
        await status.RefreshAsync();
        Assert.True(panel.Home.NeedsNewPassword);
        Assert.Equal("Choose a new password", HomeModel.ChooseNewPasswordTitle);
        BlockedRowModel row = Assert.Single(panel.List.SiteRows);
        Assert.Equal(RowButton.None, row.Present().Button);
        Assert.Null(row.Present().ButtonLabel);
    }

    [Fact]
    public async Task NeedsNewPassword_NoPasswordButOnlyPathRules_IsTrue()
    {
        var (home, status, _) = Make(Snapshot(passwordSet: false, paths: [Rule("youtube.com", "/shorts")]));
        await status.RefreshAsync();
        Assert.True(home.NeedsNewPassword);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, true)]
    public async Task NeedsNewPassword_OtherCases_IsFalse(bool passwordSet, bool withSites)
    {
        var (home, status, _) = Make(Snapshot(passwordSet: passwordSet, sites: withSites ? [Site("reddit.com")] : []));
        await status.RefreshAsync();
        Assert.False(home.NeedsNewPassword);
    }

    [Fact]
    public async Task NewPasswordForm_ValidPassword_SendsOnlySetup()
    {
        var (home, status, client) = Make(Snapshot(passwordSet: false, sites: [Site("reddit.com")]));
        await status.RefreshAsync();
        home.OpenNewPasswordForm();
        Assert.True(home.IsChoosingNewPassword);
        home.NewPasswordForm.Password = "another1";
        home.NewPasswordForm.Confirmation = "another1";
        await home.NewPasswordForm.SubmitAsync();
        Assert.Equal([new Request(Command.Setup, Password: "another1")], client.Commands);
    }
}

public sealed class AddSiteTests
{
    private static async Task<(HomeModel Home, FakeDaemonClient Client)> Make()
    {
        var client = new FakeDaemonClient(Snapshot(passwordSet: true));
        var status = new StatusModel(client, new ManualClock(), new InlineUiDispatcher());
        await status.RefreshAsync();
        return (new HomeModel(status), client);
    }

    [Theory]
    [InlineData("youtube.com/shorts")]
    [InlineData("https://www.youtube.com/shorts/abc?x=1")]
    [InlineData("youtube.com/shorts/")]
    public async Task PressBlock_TextWithPathDefaultChoice_SendsAddPath(string typed)
    {
        var (home, client) = await Make();
        home.AddText = typed;
        Assert.True(home.HasPath);
        Assert.True(home.OnlyThisPart);
        Assert.Equal("Only this part", HomeModel.OnlyThisPartTitle);
        await home.PressBlockAsync();
        Request sent = Assert.Single(client.Commands);
        Assert.Equal(Command.AddPath, sent.Command);
        Assert.Equal(typed, sent.Domain);
    }

    [Fact]
    public async Task PressBlock_TextWithPathAndWholeSiteChosen_SendsAdd()
    {
        var (home, client) = await Make();
        home.AddText = "youtube.com/shorts";
        home.OnlyThisPart = false;
        Assert.Equal("Whole site", HomeModel.WholeSiteTitle);
        await home.PressBlockAsync();
        Assert.Equal(Command.Add, Assert.Single(client.Commands).Command);
    }

    [Theory]
    [InlineData("reddit.com")]
    [InlineData("youtube.com/")]
    [InlineData("youtube.com?x=1")]
    [InlineData("https://reddit.com")]
    public async Task PressBlock_TextWithoutPath_SendsAddAndShowsNoChoice(string typed)
    {
        var (home, client) = await Make();
        home.AddText = typed;
        Assert.False(home.HasPath);
        await home.PressBlockAsync();
        Request sent = Assert.Single(client.Commands);
        Assert.Equal(Command.Add, sent.Command);
    }

    [Fact]
    public async Task PressBlock_WholeSitePickedThenNewPathTyped_ChoiceGoesBackToOnlyThisPart()
    {
        var (home, client) = await Make();
        home.AddText = "youtube.com/shorts";
        home.OnlyThisPart = false;
        home.AddText = "";
        home.AddText = "instagram.com/reels";
        await home.PressBlockAsync();
        Assert.Equal(Command.AddPath, Assert.Single(client.Commands).Command);
    }

    [Fact]
    public async Task PressBlock_Accepted_EmptiesFieldButRefusalKeepsIt()
    {
        var (home, client) = await Make();
        home.AddText = "reddit.com";
        Assert.True(await home.PressBlockAsync());
        Assert.Equal("", home.AddText);
        client.Handler = r => Task.FromResult(r.Command == Command.Status ? Response.Success(client.Snapshot) : Response.Failure(ErrorCode.InvalidDomain, "That is not a site."));
        home.AddText = "not a site";
        Assert.False(await home.PressBlockAsync());
        Assert.Equal("not a site", home.AddText);
    }

    [Fact]
    public void HomeCaptions_MatchTheDesignWording()
    {
        Assert.Equal("Block a whole site (youtube.com) or just part of one (youtube.com/shorts).", HomeModel.AddCaption);
        Assert.Equal("Add a site (e.g. reddit.com)", HomeModel.AddPrompt);
        Assert.Equal("Works in Chrome, Firefox, Edge and Brave. Other browsers can only block whole sites.", BlockedListModel.LimitsNote);
        Assert.Equal("Blocked parts of sites", BlockedListModel.RulesHeading);
    }
}

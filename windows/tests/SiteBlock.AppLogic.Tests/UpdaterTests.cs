using System.ComponentModel;
using SiteBlock.AppLogic;
using SiteBlock.Core;
using static SiteBlock.AppLogic.Tests.Fixtures;

namespace SiteBlock.AppLogic.Tests;

// Each test gets its own folder; the updater's temp root sits two levels down so an escaping zip entry would land inside the test folder, where the test can see it.
public abstract class UpdaterTestBase : IDisposable
{
    protected const int Installed = 100;
    protected readonly string Outer = Path.Combine(Path.GetTempPath(), "sb-applogic-" + Guid.NewGuid().ToString("N"));
    protected readonly string Root;
    protected readonly ManualClock Clock = new();
    protected readonly FakeDownloader Downloader = new();
    protected readonly FakeElevatedRunner Runner = new();
    protected readonly InMemoryDismissedUpdateStore Store = new();

    protected UpdaterTestBase()
    {
        Root = Path.Combine(Outer, "temp");
        Directory.CreateDirectory(Root);
    }

    public void Dispose()
    {
        try { Directory.Delete(Outer, recursive: true); } catch (IOException) { }
        GC.SuppressFinalize(this);
    }

    protected Updater MakeUpdater(IDismissedUpdateStore? store = null) =>
        new(Downloader, Runner, store ?? Store, Clock, new InlineUiDispatcher(), new UpdaterOptions { InstalledBuild = Installed, TempRoot = Root, ArchitectureFolder = "x64" });

    protected string[] DownloadFolders() => Directory.GetDirectories(Root, "SiteBlockUpdate-*");

    // An updater that has found build 143 (shown as 1.0.43) whose version file names the checksum of `package`, or `sha` when given.
    protected async Task<Updater> ReadyToInstall(byte[] package, string? sha = null)
    {
        Downloader.VersionFile = () => VersionFile(143, sha ?? Sha256(package), "1.0.43");
        Downloader.Package = package;
        Updater updater = MakeUpdater();
        await updater.CheckNowAsync();
        Assert.NotNull(updater.Available);
        return updater;
    }
}

public sealed class UpdaterCheckTests : UpdaterTestBase
{
    private static readonly TimeSpan Minute = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan Day = TimeSpan.FromHours(24);

    [Fact]
    public async Task Schedule_FirstCheckSixtySecondsAfterStartThenEveryDay()
    {
        Downloader.VersionFile = () => VersionFile(Installed, new string('a', 64));
        using Updater updater = MakeUpdater();
        updater.Start();
        await Wait.Until(() => Clock.Parked(Minute) == 1, "the first wait");
        Clock.Advance(TimeSpan.FromMilliseconds(59_999));
        await Task.Delay(50);
        Assert.Empty(Downloader.Fetches);
        Clock.Advance(TimeSpan.FromMilliseconds(1));
        await Wait.Until(() => Downloader.Fetches.Count == 1 && Clock.Parked(Day) == 1, "the first check");
        Assert.Equal(UpdateCheck.WindowsVersionUrl, Downloader.Fetches[0]);
        Clock.Advance(Day - TimeSpan.FromMilliseconds(1));
        await Task.Delay(50);
        Assert.Single(Downloader.Fetches);
        Clock.Advance(TimeSpan.FromMilliseconds(1));
        await Wait.Until(() => Downloader.Fetches.Count == 2 && Clock.Parked(Day) == 1, "the second check");
    }

    [Fact]
    public async Task AutomaticCheck_NewerBuild_ShowsBannerWithDisplayVersionAndButtons()
    {
        Downloader.VersionFile = () => VersionFile(143, new string('a', 64), "1.0.43");
        using Updater updater = MakeUpdater();
        updater.Start();
        await Wait.Until(() => Clock.Parked(Minute) == 1, "the first wait");
        Clock.Advance(Minute);
        await Wait.Until(() => updater.Available is not null, "the update to be found");
        Assert.True(updater.ShowsBanner);
        Banner banner = Banners.UpdateBanner(updater.Available!, updater);
        Assert.Equal("SiteBlock 1.0.43 is available.", banner.Text);
        Assert.Equal([("Update", true), ("Not now", false)], banner.Actions.Select(a => (a.Label, a.Prominent)));
        Assert.Null(updater.CheckResult);
    }

    [Fact]
    public async Task AutomaticCheck_FailsAfterAFind_KeepsTheUpdateAndSaysNothing()
    {
        Downloader.VersionFile = () => VersionFile(143, new string('a', 64));
        using Updater updater = MakeUpdater();
        updater.Start();
        await Wait.Until(() => Clock.Parked(Minute) == 1, "the first wait");
        Clock.Advance(Minute);
        await Wait.Until(() => updater.Available is not null && Clock.Parked(Day) == 1, "the update to be found");
        Downloader.VersionFile = () => null;
        Clock.Advance(Day);
        await Wait.Until(() => Downloader.Fetches.Count == 2 && Clock.Parked(Day) == 1, "the failing check");
        Assert.Equal(143, updater.Available?.Build);
        Assert.Null(updater.CheckResult);
        Assert.NotEqual(UpdatePhaseKind.Failed, updater.Phase.Kind);
    }

    [Fact]
    public async Task ManualCheck_SameBuild_SaysUpToDate()
    {
        Downloader.VersionFile = () => VersionFile(Installed, new string('a', 64));
        Updater updater = MakeUpdater();
        await updater.CheckNowAsync();
        Assert.Null(updater.Available);
        Assert.Equal("You're up to date.", updater.CheckResult?.Text());
    }

    [Fact]
    public async Task ManualCheck_OlderBuild_SaysUpToDate()
    {
        Downloader.VersionFile = () => VersionFile(Installed - 1, new string('a', 64));
        Updater updater = MakeUpdater();
        await updater.CheckNowAsync();
        Assert.Equal("You're up to date.", updater.CheckResult?.Text());
    }

    public static TheoryData<string, byte[]?> UnusableAnswers => new()
    {
        { "no answer", null },
        { "not json", "<html>rate limited</html>"u8.ToArray() },
        { "empty", [] },
        { "mac package name", VersionFile(143, new string('a', 64), asset: "SiteBlock.zip") },
        { "uppercase checksum", VersionFile(143, new string('A', 64)) },
    };

    [Theory]
    [MemberData(nameof(UnusableAnswers))]
    public async Task ManualCheck_UnusableAnswer_SaysCouldNotCheck(string why, byte[]? answer)
    {
        Downloader.VersionFile = () => answer;
        Updater updater = MakeUpdater();
        await updater.CheckNowAsync();
        Assert.True(updater.Available is null, why);
        Assert.Equal("Couldn't check for updates. Try again later.", updater.CheckResult?.Text());
    }

    [Fact]
    public async Task SettingsModel_ShowsTheManualCheckResultUnderTheButton()
    {
        Downloader.VersionFile = () => null;
        Updater updater = MakeUpdater();
        var status = new StatusModel(new FakeDaemonClient(Snapshot()), Clock, new InlineUiDispatcher(), updater);
        var settings = new SettingsModel(status);
        await settings.CheckForUpdatesAsync();
        Assert.Equal("Couldn't check for updates. Try again later.", settings.CheckResultText);
        Assert.True(settings.CheckResultIsError);
        Assert.Equal("Check for updates", SettingsModel.CheckForUpdatesTitle);
    }

    [Fact]
    public async Task NotNow_HidesThatBuildEvenAfterRestart_AndANewerBuildShowsAgain()
    {
        Downloader.VersionFile = () => VersionFile(143, new string('a', 64));
        using (Updater first = MakeUpdater())
        {
            first.Start();
            await Wait.Until(() => Clock.Parked(Minute) == 1, "the first wait");
            Clock.Advance(Minute);
            await Wait.Until(() => first.Available is not null && Clock.Parked(Day) == 1, "the first find");
            first.Dismiss();
            Assert.False(first.ShowsBanner);
        }
        Assert.Equal(143, Store.Load());

        using Updater restarted = MakeUpdater();
        restarted.Start();
        await Wait.Until(() => Clock.Parked(Minute) == 1, "the restarted app's first wait");
        Clock.Advance(Minute);
        await Wait.Until(() => restarted.Available is not null && Clock.Parked(Day) == 1, "the restarted app's find");
        Assert.False(restarted.ShowsBanner);

        Downloader.VersionFile = () => VersionFile(144, new string('b', 64));
        Clock.Advance(Day);
        await Wait.Until(() => restarted.Available?.Build == 144, "the newer build");
        Assert.True(restarted.ShowsBanner);
    }

    [Theory]
    [InlineData(UpdatePhaseKind.Downloading, "Downloading…")]
    [InlineData(UpdatePhaseKind.Verifying, "Checking the download…")]
    [InlineData(UpdatePhaseKind.WaitingForPassword, "Waiting for your password…")]
    [InlineData(UpdatePhaseKind.Installing, "Installing…")]
    public void PhaseStepText_MatchesTheBannerWording(UpdatePhaseKind kind, string expected)
    {
        Assert.Equal(expected, new UpdatePhase(kind).StepText);
    }
}

public sealed class UpdaterInstallTests : UpdaterTestBase
{
    private const string ChecksFailed = "The update didn't pass its checks, so nothing was installed.";

    [Fact]
    public async Task Install_GoodPackage_RunsElevatedPowerShellWithChecksumAndProtectedFolder()
    {
        byte[] package = Zip(PackageEntries());
        Updater updater = await ReadyToInstall(package);
        var phases = new List<UpdatePhaseKind>();
        updater.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Updater.Phase)) phases.Add(updater.Phase.Kind); };
        bool zipPresentWhileElevatedRuns = false;
        Runner.WhileRunning = () => zipPresentWhileElevatedRuns = File.Exists(Downloader.Downloads[0].Destination);

        await updater.InstallAsync();

        Assert.Equal([UpdatePhaseKind.Downloading, UpdatePhaseKind.Verifying, UpdatePhaseKind.WaitingForPassword, UpdatePhaseKind.Installing], phases.Take(4));
        var (url, destination) = Assert.Single(Downloader.Downloads);
        Assert.Equal(UpdateCheck.WindowsPackageUrl, url);
        Assert.StartsWith("SiteBlockUpdate-", Path.GetFileName(Path.GetDirectoryName(destination)));
        Assert.Equal(Root, Path.GetDirectoryName(Path.GetDirectoryName(destination)));
        Assert.True(zipPresentWhileElevatedRuns, "the elevated step must be able to copy the downloaded zip");

        var (fileName, arguments) = Assert.Single(Runner.Runs);
        Assert.EndsWith("powershell.exe", fileName, StringComparison.OrdinalIgnoreCase);
        string script = FakeElevatedRunner.DecodeScript(arguments);
        Assert.Contains(Sha256(package), script, StringComparison.Ordinal);
        Assert.True(script.Contains("ProgramData", StringComparison.OrdinalIgnoreCase) || script.Contains("CommonApplicationData", StringComparison.Ordinal), "the script must work in the ProgramData folder");
        Assert.Contains("'update-'", script, StringComparison.Ordinal);
        Assert.Contains("install.ps1", script, StringComparison.Ordinal);
        Assert.Contains("update.log", script, StringComparison.Ordinal);
        Assert.Contains(UpdatePackage.PowerShellQuoted(destination), script, StringComparison.Ordinal);
        Assert.Contains("Get-FileHash", script, StringComparison.Ordinal);

        Assert.Empty(DownloadFolders());
        Assert.Null(updater.Available);
        Assert.Equal(UpdatePhaseKind.Idle, updater.Phase.Kind);
    }

    [Fact]
    public async Task Install_ChecksumMismatch_FailsDeletesFolderAndNeverPrompts()
    {
        byte[] package = Zip(PackageEntries());
        Updater updater = await ReadyToInstall(package, sha: Sha256("something else"u8.ToArray()));
        await updater.InstallAsync();
        Assert.Equal(UpdatePhaseKind.Failed, updater.Phase.Kind);
        Assert.Equal(ChecksFailed, updater.Phase.FailureText);
        Assert.Equal(ChecksFailed, Banners.UpdateBanner(updater.Available!, updater).ErrorText);
        Assert.Empty(Runner.Runs);
        Assert.Single(Downloader.Downloads);
        Assert.Empty(DownloadFolders());
    }

    [Theory]
    [InlineData("SiteBlock/bin/x64/siteblockd.exe")]
    [InlineData("SiteBlock/bin/x64/siteblock.exe")]
    [InlineData("SiteBlock/bin/x64/SiteBlockApp.exe")]
    [InlineData("SiteBlock/scripts/install.ps1")]
    [InlineData("SiteBlock/Install SiteBlock.cmd")]
    public async Task Install_PackageMissingARequiredFile_FailsDeletesFolderAndNeverPrompts(string missing)
    {
        // The other processor's programs are added so the package still looks real; only its bin entries are added, because adding all of
        // PackageEntries("arm64") put the shared scripts/install.ps1 and Install SiteBlock.cmd straight back and the "missing" file was not missing.
        byte[] package = Zip(PackageEntries().Where(e => e != missing).Concat(PackageEntries("arm64").Where(e => e.StartsWith("SiteBlock/bin/", StringComparison.Ordinal))));
        Updater updater = await ReadyToInstall(package);
        await updater.InstallAsync();
        Assert.Equal(ChecksFailed, updater.Phase.FailureText);
        Assert.Empty(Runner.Runs);
        Assert.Empty(DownloadFolders());
    }

    [Fact]
    public async Task Install_PackageHasOnlyTheOtherProcessorsPrograms_Fails()
    {
        byte[] package = Zip(PackageEntries("arm64"));
        Updater updater = await ReadyToInstall(package);
        await updater.InstallAsync();
        Assert.Equal(ChecksFailed, updater.Phase.FailureText);
        Assert.Empty(Runner.Runs);
    }

    [Fact]
    public async Task Install_RequiredProgramIsAFolderNotAFile_Fails()
    {
        var entries = PackageEntries().Where(e => !e.EndsWith("/siteblock.exe", StringComparison.Ordinal)).Append("SiteBlock/bin/x64/siteblock.exe/").Append("SiteBlock/bin/x64/siteblock.exe/inner.txt");
        Updater updater = await ReadyToInstall(Zip(entries));
        await updater.InstallAsync();
        Assert.Equal(ChecksFailed, updater.Phase.FailureText);
        Assert.Empty(Runner.Runs);
    }

    [Fact]
    public async Task Install_ZipEntryPointsOutsideTheFolder_IsRefusedAndNothingEscapes()
    {
        byte[] package = Zip(PackageEntries().Append("../../../escaped.txt"));
        Updater updater = await ReadyToInstall(package);
        await updater.InstallAsync();
        Assert.Equal(ChecksFailed, updater.Phase.FailureText);
        Assert.Empty(Runner.Runs);
        Assert.False(File.Exists(Path.Combine(Outer, "escaped.txt")));
        Assert.Empty(Directory.GetFiles(Outer, "escaped.txt", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task Install_UacCancelled_ReturnsToIdleWithCancelledNoticeAndButtons()
    {
        Runner.Result = new ElevatedRunResult(ElevatedRunOutcome.Cancelled);
        Updater updater = await ReadyToInstall(Zip(PackageEntries()));
        await updater.InstallAsync();
        Assert.Equal(UpdatePhaseKind.Idle, updater.Phase.Kind);
        Assert.Equal("The update was cancelled.", updater.Notice);
        Assert.True(updater.ShowsBanner);
        Banner banner = Banners.UpdateBanner(updater.Available!, updater);
        Assert.Equal("The update was cancelled.", banner.NoticeText);
        Assert.Null(banner.StepText);
        Assert.Equal(["Update", "Not now"], banner.Actions.Select(a => a.Label));
        Assert.Single(Runner.Runs);
        Assert.Empty(DownloadFolders());
    }

    [Fact]
    public async Task Install_WhileStepRuns_BannerShowsStepInPlaceOfButtons()
    {
        Updater updater = await ReadyToInstall(Zip(PackageEntries()));
        Banner? during = null;
        Runner.WhileRunning = () => during = Banners.UpdateBanner(updater.Available!, updater);
        await updater.InstallAsync();
        Assert.NotNull(during);
        Assert.Equal("Installing…", during.StepText);
        Assert.Empty(during.Actions);
    }
}

public sealed class UpdatePackageTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "sb-applogic-pkg-" + Guid.NewGuid().ToString("N"));

    public UpdatePackageTests() => Directory.CreateDirectory(Path.Combine(_folder, "download"));

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); } catch (IOException) { }
    }

    private string WriteZip(IEnumerable<string> entries)
    {
        string zip = Path.Combine(_folder, "download", "SiteBlock-Windows.zip");
        File.WriteAllBytes(zip, Zip(entries));
        return zip;
    }

    [Fact]
    public void Verify_CompletePackageWithMatchingChecksum_Passes()
    {
        string zip = WriteZip(PackageEntries());
        Assert.True(UpdatePackage.Verify(Path.Combine(_folder, "download"), zip, Sha256(File.ReadAllBytes(zip)), "x64"));
    }

    [Theory]
    [InlineData("SiteBlock/../../escaped.txt")]
    [InlineData("../escaped.txt")]
    public void Verify_EntryLeavingTheFolder_IsRefusedAndWritesNothingOutside(string evil)
    {
        string zip = WriteZip(PackageEntries().Append(evil));
        Assert.False(UpdatePackage.Verify(Path.Combine(_folder, "download"), zip, Sha256(File.ReadAllBytes(zip)), "x64"));
        Assert.False(File.Exists(Path.Combine(_folder, "escaped.txt")));
        Assert.False(File.Exists(Path.Combine(_folder, "download", "escaped.txt")));
    }

    [Fact]
    public void PowerShellQuoted_PathWithApostrophe_DoublesIt()
    {
        Assert.Equal(@"'C:\Users\O''Brien\AppData\Local\Temp\x.zip'", UpdatePackage.PowerShellQuoted(@"C:\Users\O'Brien\AppData\Local\Temp\x.zip"));
    }

    [Fact]
    public void ElevatedScript_DownloadPathWithApostrophe_IsQuotedSafely()
    {
        string script = UpdatePackage.ElevatedScript(@"C:\Users\O'Brien\Temp\SiteBlockUpdate-1\SiteBlock-Windows.zip", @"C:\Users\O'Brien\Temp\SiteBlockUpdate-1", new string('c', 64), "x64");
        Assert.Contains(@"'C:\Users\O''Brien\Temp\SiteBlockUpdate-1\SiteBlock-Windows.zip'", script, StringComparison.Ordinal);
        Assert.DoesNotContain(@"O'Brien", script, StringComparison.Ordinal);
    }
}

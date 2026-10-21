using System.Runtime.InteropServices;
using System.Text;
using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>Where the updater is in a check or an install.</summary>
public enum UpdatePhaseKind
{
    /// <summary>Nothing is happening.</summary>
    Idle,
    /// <summary>A check for a newer version is running.</summary>
    Checking,
    /// <summary>The package is being downloaded.</summary>
    Downloading,
    /// <summary>The download is being checked and unzipped.</summary>
    Verifying,
    /// <summary>The UAC prompt is on screen.</summary>
    WaitingForPassword,
    /// <summary>The installer is running.</summary>
    Installing,
    /// <summary>The install failed; <see cref="UpdatePhase.FailureText"/> is the sentence to show.</summary>
    Failed,
    /// <summary>A manual check found nothing newer.</summary>
    UpToDate,
}

/// <summary>The updater's phase, plus the sentence to show when it is <see cref="UpdatePhaseKind.Failed"/>.</summary>
/// <param name="Kind">The phase.</param>
/// <param name="FailureText">The failure sentence for <see cref="UpdatePhaseKind.Failed"/>; null otherwise.</param>
public sealed record UpdatePhase(UpdatePhaseKind Kind, string? FailureText = null)
{
    /// <summary>Nothing is happening.</summary>
    public static UpdatePhase Idle { get; } = new(UpdatePhaseKind.Idle);

    /// <summary>A failure with its sentence.</summary>
    public static UpdatePhase Failed(string text) => new(UpdatePhaseKind.Failed, text);

    /// <summary>The words the banner shows while an install step runs ("Downloading…", "Checking the download…", "Waiting for your password…", "Installing…"), or null when no install step runs.</summary>
    public string? StepText => Kind switch
    {
        UpdatePhaseKind.Downloading => "Downloading…",
        UpdatePhaseKind.Verifying => "Checking the download…",
        UpdatePhaseKind.WaitingForPassword => "Waiting for your password…",
        UpdatePhaseKind.Installing => "Installing…",
        _ => null,
    };
}

/// <summary>What a manual check reported, shown under the "Check for updates" button.</summary>
public enum UpdateCheckResult
{
    /// <summary>The published build is not newer than the installed one.</summary>
    UpToDate,
    /// <summary>GitHub could not be reached, or its answer was not usable.</summary>
    CouldNotCheck,
}

/// <summary>The sentences for <see cref="UpdateCheckResult"/>.</summary>
public static class UpdateCheckResultText
{
    /// <summary>"You're up to date." or "Couldn't check for updates. Try again later."</summary>
    public static string Text(this UpdateCheckResult result) => result == UpdateCheckResult.UpToDate ? "You're up to date." : "Couldn't check for updates. Try again later.";

    /// <summary>True when the sentence is shown as an error.</summary>
    public static bool IsError(this UpdateCheckResult result) => result == UpdateCheckResult.CouldNotCheck;
}

/// <summary>The settings an <see cref="Updater"/> runs with. Production uses the defaults; tests shorten the waits and point the folders somewhere safe.</summary>
public sealed record UpdaterOptions
{
    /// <summary>The build number of the running app; a published build above it is newer.</summary>
    public int InstalledBuild { get; init; } = BuildInfo.BuildNumber;

    /// <summary>The package folder for this PC's processor: "x64" or "arm64".</summary>
    public string ArchitectureFolder { get; init; } = UpdatePackage.ArchitectureFolderFor(RuntimeInformation.OSArchitecture);

    /// <summary>The folder that receives the download folders (the user's temp folder).</summary>
    public string TempRoot { get; init; } = Path.GetTempPath();

    /// <summary>The program that runs the elevated install step.</summary>
    public string PowerShellPath { get; init; } = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");

    /// <summary>Where the version file is published.</summary>
    public Uri VersionUrl { get; init; } = UpdateCheck.WindowsVersionUrl;

    /// <summary>Where the package is published.</summary>
    public Uri PackageUrl { get; init; } = UpdateCheck.WindowsPackageUrl;

    /// <summary>The wait from <see cref="Updater.Start"/> to the first automatic check.</summary>
    public TimeSpan FirstCheckDelay { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>The wait between automatic checks.</summary>
    public TimeSpan CheckInterval { get; init; } = TimeSpan.FromHours(24);

    /// <summary>How long the version file request may take.</summary>
    public TimeSpan VersionTimeout { get; init; } = TimeSpan.FromSeconds(15);

    /// <summary>How long the package download may take.</summary>
    public TimeSpan DownloadTimeout { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>How long the elevated install step may run before the updater stops waiting for it.</summary>
    public TimeSpan InstallerTimeout { get; init; } = TimeSpan.FromMinutes(10);
}

/// <summary>
/// Finds out whether a newer SiteBlock for Windows has been published, and installs it when the person presses "Update". It never installs anything by itself.
/// Checks run 60 seconds after <see cref="Start"/>, then every 24 hours, plus whenever the person presses "Check for updates". An install downloads the zip, checks it, and runs an elevated PowerShell (which shows the UAC prompt) that checks it again and runs its install.ps1.
/// Every property changes only inside the screen dispatcher.
/// </summary>
public sealed class Updater : ObservableModel, IDisposable
{
    /// <summary>The largest answer accepted as a version file; a real one is under 300 bytes.</summary>
    public const int MaxVersionFileBytes = 65_536;

    /// <summary>The sentence after the person answered "No" in the UAC prompt.</summary>
    public const string CancelledText = "The update was cancelled.";
    /// <summary>The failure sentence when the package could not be downloaded.</summary>
    public const string DownloadFailedText = "The update couldn't be downloaded. Try again later.";
    /// <summary>The failure sentence when the checksum, the unzip or the layout check failed.</summary>
    public const string ChecksFailedText = "The update didn't pass its checks, so nothing was installed.";
    /// <summary>The failure sentence when the elevated install step could not be started.</summary>
    public const string StartFailedText = "The installer couldn't be started, so nothing was installed.";

    /// <summary>The failure sentence when the installer ran but did not finish well; it names the log file.</summary>
    public static string InstallFailedText => $"The install didn't finish. Details are in {UpdatePackage.UpdateLogPath}.";

    private readonly IUpdateDownloader _downloader;
    private readonly IElevatedRunner _runner;
    private readonly IDismissedUpdateStore _store;
    private readonly IClock _clock;
    private readonly IUiDispatcher _ui;
    private readonly UpdaterOptions _options;
    private readonly CancellationTokenSource _stop = new();

    private UpdateInfo? _available;
    private UpdatePhase _phase = UpdatePhase.Idle;
    private string? _notice;
    private UpdateCheckResult? _checkResult;
    private int _dismissedBuild;
    private int _started;

    /// <summary>Creates the updater and reads the dismissed build from the store. Nothing is checked until <see cref="Start"/>.</summary>
    public Updater(IUpdateDownloader downloader, IElevatedRunner runner, IDismissedUpdateStore store, IClock clock, IUiDispatcher ui, UpdaterOptions? options = null)
    {
        _downloader = downloader ?? throw new ArgumentNullException(nameof(downloader));
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _ui = ui ?? throw new ArgumentNullException(nameof(ui));
        _options = options ?? new UpdaterOptions();
        _dismissedBuild = SafeLoad();
    }

    /// <summary>The newest published build when it is newer than the installed one, otherwise null.</summary>
    public UpdateInfo? Available { get => _available; private set => SetField(ref _available, value); }

    /// <summary>What the updater is doing right now.</summary>
    public UpdatePhase Phase { get => _phase; private set => SetField(ref _phase, value); }

    /// <summary>The sentence shown after the UAC prompt was cancelled, until the next install attempt or "Not now".</summary>
    public string? Notice { get => _notice; private set => SetField(ref _notice, value); }

    /// <summary>The result of the last manual check, shown in Settings until the person leaves that screen.</summary>
    public UpdateCheckResult? CheckResult { get => _checkResult; private set => SetField(ref _checkResult, value); }

    /// <summary>The newest build the person answered "Not now" to; a newer build shows the banner again.</summary>
    public int DismissedBuild { get => _dismissedBuild; private set => SetField(ref _dismissedBuild, value); }

    /// <summary>True while a check or an install runs, so a second one is not started on top of it.</summary>
    public bool IsWorking => Phase.Kind is UpdatePhaseKind.Checking or UpdatePhaseKind.Downloading or UpdatePhaseKind.Verifying or UpdatePhaseKind.WaitingForPassword or UpdatePhaseKind.Installing;

    /// <summary>True while an install runs, which is when the banner shows the step in place of its buttons.</summary>
    public bool IsInstalling => Phase.Kind is UpdatePhaseKind.Downloading or UpdatePhaseKind.Verifying or UpdatePhaseKind.WaitingForPassword or UpdatePhaseKind.Installing;

    /// <summary>
    /// True when the update banner should show: a newer build is known and the person has not dismissed it. A running install, a failure and a cancel notice keep it on screen, so the person always sees what happened.
    /// </summary>
    public bool ShowsBanner
    {
        get
        {
            if (Available is not { } info) return false;
            if (IsInstalling || Notice is not null || Phase.Kind == UpdatePhaseKind.Failed) return true;
            return info.Build > DismissedBuild;
        }
    }

    /// <summary>Starts the schedule: the first check after <see cref="UpdaterOptions.FirstCheckDelay"/>, then one every <see cref="UpdaterOptions.CheckInterval"/>. Calling it again does nothing.</summary>
    public void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) != 0) return;
        CancellationToken token = _stop.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await _clock.Delay(_options.FirstCheckDelay, token).ConfigureAwait(false);
                while (!token.IsCancellationRequested)
                {
                    await CheckAsync(manual: false).ConfigureAwait(false);
                    await _clock.Delay(_options.CheckInterval, token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
                // The app is closing.
            }
        }, CancellationToken.None);
    }

    /// <summary>Stops the schedule. An install that already started its elevated step keeps running, because that step is its own process.</summary>
    public void Dispose()
    {
        // The token source is cancelled but not disposed, because a running check or install may still read its token.
        _stop.Cancel();
    }

    // ---- Checking ----

    /// <summary>Runs a check because the person pressed "Check for updates". The result shows through <see cref="CheckResult"/>.</summary>
    public Task CheckNowAsync() => CheckAsync(manual: true);

    /// <summary>Removes the manual check's result. Settings calls it, on the screen's thread, when the person leaves that screen.</summary>
    public void ClearCheckResult()
    {
        CheckResult = null;
        if (Phase.Kind == UpdatePhaseKind.UpToDate) Phase = UpdatePhase.Idle;
        RaiseDerived();
    }

    /// <summary>
    /// Fetches the version file and updates <see cref="Available"/>. An automatic check says nothing about a failure and leaves <see cref="Available"/> as it was; a manual check also sets <see cref="CheckResult"/>, and a manual check that finds a newer build forgets an earlier "Not now".
    /// </summary>
    private async Task CheckAsync(bool manual)
    {
        bool claimed = false;
        await _ui.InvokeAsync(() =>
        {
            if (IsWorking) return;
            claimed = true;
            Phase = new UpdatePhase(UpdatePhaseKind.Checking);
            CheckResult = null;
            RaiseDerived();
        }).ConfigureAwait(false);
        if (!claimed) return;

        UpdateInfo? info = await FetchVersionInfoAsync().ConfigureAwait(false);
        await _ui.InvokeAsync(() =>
        {
            if (info is null)
            {
                Phase = UpdatePhase.Idle;
                if (manual) CheckResult = UpdateCheckResult.CouldNotCheck;
            }
            else if (UpdateCheck.IsNewer(info, _options.InstalledBuild))
            {
                Available = info;
                Phase = UpdatePhase.Idle;
                // The person asked, so a build they dismissed earlier is shown again.
                if (manual) ForgetDismissal();
            }
            else
            {
                Available = null;
                Phase = manual ? new UpdatePhase(UpdatePhaseKind.UpToDate) : UpdatePhase.Idle;
                if (manual) CheckResult = UpdateCheckResult.UpToDate;
            }
            RaiseDerived();
        }).ConfigureAwait(false);
    }

    /// <summary>Fetches the version file and returns it only when it is a usable Windows version file; any failure gives null.</summary>
    private async Task<UpdateInfo?> FetchVersionInfoAsync()
    {
        try
        {
            byte[]? data = await _downloader.FetchVersionFileAsync(_options.VersionUrl, _options.VersionTimeout, MaxVersionFileBytes, _stop.Token).ConfigureAwait(false);
            if (data is null || data.Length > MaxVersionFileBytes) return null;
            return UpdateCheck.Parse(data, UpdateCheck.WindowsAsset);
        }
        catch (Exception)
        {
            return null;
        }
    }

    // ---- Dismissing ----

    /// <summary>"Not now": hides the banner for the offered build, remembers that, and clears any failure or cancel sentence. Does nothing while an install runs. Call it on the screen's thread.</summary>
    public void Dismiss()
    {
        if (IsInstalling || Available is not { } info) return;
        Notice = null;
        if (Phase.Kind == UpdatePhaseKind.Failed) Phase = UpdatePhase.Idle;
        DismissedBuild = info.Build;
        try
        {
            _store.Save(info.Build);
        }
        catch (Exception)
        {
            // The banner stays hidden for this run of the app even when the value could not be stored.
        }
        RaiseDerived();
    }

    /// <summary>Forgets a dismissal, so the banner shows for the offered build again.</summary>
    private void ForgetDismissal()
    {
        DismissedBuild = 0;
        try
        {
            _store.Clear();
        }
        catch (Exception)
        {
            // Nothing to do: the in-memory value already shows the banner.
        }
    }

    /// <summary>Reads the stored dismissed build, treating a store failure as "nothing dismissed".</summary>
    private int SafeLoad()
    {
        try
        {
            return Math.Max(0, _store.Load());
        }
        catch (Exception)
        {
            return 0;
        }
    }

    // ---- Installing ----

    /// <summary>"Update": starts installing the offered build in the background. Does nothing when no update is known or a check or install already runs.</summary>
    public void Install() => _ = InstallAsync();

    /// <summary>Runs the whole install and completes when it has ended (or stopped early). Tests await it; the panel calls <see cref="Install"/>.</summary>
    public async Task InstallAsync()
    {
        UpdateInfo? offered = null;
        await _ui.InvokeAsync(() =>
        {
            if (Available is not { } info || IsWorking) return;
            offered = info;
            Notice = null;
            Phase = new UpdatePhase(UpdatePhaseKind.Downloading);
            RaiseDerived();
        }).ConfigureAwait(false);
        if (offered is null) return;

        string? folder = null;
        try
        {
            // The version file is read again right before the download. The download address always serves the newest release, so if a newer build was published since the banner appeared, the old checksum would not match. A failed read falls back to what the banner offered.
            UpdateInfo info = offered;
            if (await FetchVersionInfoAsync().ConfigureAwait(false) is { } fresh && UpdateCheck.IsNewer(fresh, _options.InstalledBuild))
            {
                info = fresh;
                await SetOnUi(() => Available = fresh).ConfigureAwait(false);
            }

            folder = Path.Combine(_options.TempRoot, "SiteBlockUpdate-" + Guid.NewGuid().ToString("N"));
            string zip = Path.Combine(folder, UpdateCheck.WindowsAsset);
            if (!await DownloadAsync(folder, zip).ConfigureAwait(false))
            {
                await FailAsync(DownloadFailedText).ConfigureAwait(false);
                return;
            }

            await SetPhaseAsync(new UpdatePhase(UpdatePhaseKind.Verifying)).ConfigureAwait(false);
            bool passed = await Task.Run(() => UpdatePackage.Verify(folder, zip, info.Sha256, _options.ArchitectureFolder)).ConfigureAwait(false);
            if (!passed)
            {
                await FailAsync(ChecksFailedText).ConfigureAwait(false);
                return;
            }

            await SetPhaseAsync(new UpdatePhase(UpdatePhaseKind.WaitingForPassword)).ConfigureAwait(false);
            string script = UpdatePackage.ElevatedScript(zip, folder, info.Sha256, _options.ArchitectureFolder);
            string arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            ElevatedRunResult result;
            try
            {
                result = await _runner.RunAsync(_options.PowerShellPath, arguments, () => _ = SetPhaseAsync(new UpdatePhase(UpdatePhaseKind.Installing)), _options.InstallerTimeout, _stop.Token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                result = new ElevatedRunResult(ElevatedRunOutcome.Failed);
            }

            await _ui.InvokeAsync(() =>
            {
                switch (result.Outcome)
                {
                    case ElevatedRunOutcome.Cancelled:
                        // Nothing changed on the PC; the banner shows its buttons again with this sentence.
                        Phase = UpdatePhase.Idle;
                        Notice = CancelledText;
                        break;
                    case ElevatedRunOutcome.Failed:
                        Phase = UpdatePhase.Failed(StartFailedText);
                        break;
                    case ElevatedRunOutcome.Exited when result.ExitCode == 0:
                        // install.ps1 normally stops this app before this point; if it is still running, the update is done anyway.
                        Available = null;
                        Phase = UpdatePhase.Idle;
                        break;
                    case ElevatedRunOutcome.Exited when result.ExitCode == UpdatePackage.ChecksFailedExitCode:
                        Phase = UpdatePhase.Failed(ChecksFailedText);
                        break;
                    default:
                        Phase = UpdatePhase.Failed(InstallFailedText);
                        break;
                }
                RaiseDerived();
            }).ConfigureAwait(false);
        }
        catch (Exception)
        {
            await FailAsync(StartFailedText).ConfigureAwait(false);
        }
        finally
        {
            // The elevated step has its own copy by now (or never started), so the download folder is no longer needed.
            if (folder is not null) UpdatePackage.DeleteFolder(folder);
        }
    }

    /// <summary>Creates the new download folder and downloads the zip into it. Returns false when either step fails.</summary>
    private async Task<bool> DownloadAsync(string folder, string zip)
    {
        try
        {
            // A fresh random name, so an existing folder is never reused.
            if (Directory.Exists(folder) || File.Exists(folder)) return false;
            Directory.CreateDirectory(folder);
            return await _downloader.DownloadFileAsync(_options.PackageUrl, zip, _options.DownloadTimeout, _stop.Token).ConfigureAwait(false) && File.Exists(zip);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>Sets the phase on the dispatcher.</summary>
    private Task SetPhaseAsync(UpdatePhase phase) => SetOnUi(() => Phase = phase);

    /// <summary>Ends the install with a failure sentence.</summary>
    private Task FailAsync(string text) => SetPhaseAsync(UpdatePhase.Failed(text));

    /// <summary>Runs a change on the dispatcher and then raises the derived properties.</summary>
    private Task SetOnUi(Action change) => _ui.InvokeAsync(() =>
    {
        change();
        RaiseDerived();
    });

    /// <summary>Raises the properties computed from the others, so the banner and Settings redraw.</summary>
    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(IsWorking));
        OnPropertyChanged(nameof(IsInstalling));
        OnPropertyChanged(nameof(ShowsBanner));
    }
}

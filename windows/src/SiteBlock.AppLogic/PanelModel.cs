using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>Which screen the panel shows.</summary>
public enum PanelScreen
{
    /// <summary>"Connecting to SiteBlock…", until the first answer arrives.</summary>
    Connecting,
    /// <summary>The service cannot be reached.</summary>
    NotRunning,
    /// <summary>The home screen: banners, the add field and the blocked list.</summary>
    Home,
    /// <summary>The Settings screen.</summary>
    Settings,
}

/// <summary>
/// The panel's root model: which screen shows, the home, Settings and list models, the header line, and the reset that happens every time the panel closes (typed passwords, open forms and Settings are forgotten, as the Mac panel does).
/// Call its members on the screen's thread.
/// </summary>
public sealed class PanelModel : ObservableModel
{
    /// <summary>The app's name in the header.</summary>
    public const string AppName = "SiteBlock";
    /// <summary>The connecting screen's line.</summary>
    public const string ConnectingText = "Connecting to SiteBlock…";
    /// <summary>The not-running screen's explanation.</summary>
    public const string NotRunningExplanation = "While the service is stopped, nothing repairs the blocks or carries out unblocks. To start it again:";
    /// <summary>The not-running screen's repair step on Windows.</summary>
    public const string NotRunningRepair = "Open the SiteBlock folder you downloaded and double-click Install SiteBlock.cmd again. It asks Windows for administrator rights and repairs the install.";
    /// <summary>The not-running screen's button.</summary>
    public const string TryAgainTitle = "Try again";
    /// <summary>The footer button.</summary>
    public const string SettingsTitle = "Settings";
    /// <summary>The Settings back button.</summary>
    public const string BackTitle = "Back";

    private bool _showingSettings;

    /// <summary>Creates the panel model and its children, and keeps the list in step with every new status.</summary>
    public PanelModel(StatusModel status)
    {
        Status = status ?? throw new ArgumentNullException(nameof(status));
        Home = new HomeModel(status);
        Settings = new SettingsModel(status);
        List = new BlockedListModel(status);
        if (status.Snapshot is { } first) List.Update(first);
        status.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(StatusModel.Snapshot) && status.Snapshot is { } snapshot) List.Update(snapshot);
            if (e.PropertyName is nameof(StatusModel.Snapshot) or nameof(StatusModel.Connection)) OnPropertyChanged(nameof(Screen));
        };
    }

    /// <summary>The status model everything reads from.</summary>
    public StatusModel Status { get; }

    /// <summary>The home screen's state.</summary>
    public HomeModel Home { get; }

    /// <summary>The Settings screen's state.</summary>
    public SettingsModel Settings { get; }

    /// <summary>The blocked list's rows.</summary>
    public BlockedListModel List { get; }

    /// <summary>Whether the person opened Settings. Settings only shows while a password exists, because every setting needs one.</summary>
    public bool ShowingSettings
    {
        get => _showingSettings;
        private set
        {
            if (SetField(ref _showingSettings, value)) OnPropertyChanged(nameof(Screen));
        }
    }

    /// <summary>The screen to show now.</summary>
    public PanelScreen Screen => Status.Connection.State switch
    {
        ConnectionState.NotRunning => PanelScreen.NotRunning,
        ConnectionState.Connected when Status.Snapshot is { } snapshot => ShowingSettings && snapshot.PasswordSet ? PanelScreen.Settings : PanelScreen.Home,
        _ => PanelScreen.Connecting,
    };

    /// <summary>The not-running screen's headline: the client's sentence, such as "The SiteBlock service isn't running."</summary>
    public string NotRunningMessage => Status.Connection.Message ?? new DaemonClientException(ClientError.NotRunning).Message;

    /// <summary>True when the home screen has its footer with the Settings button, which needs a password.</summary>
    public bool ShowsFooter => Status.Snapshot?.PasswordSet == true;

    /// <summary>The header's delay line, such as "Unblock delay: 30 minutes", or null before the first status.</summary>
    public string? HeaderDelayText => Status.Snapshot is { } snapshot ? $"Unblock delay: {Formatting.Duration(CountdownMath.Clamp(snapshot.DelaySeconds))}" : null;

    /// <summary>The tooltip of the header's delay line.</summary>
    public string? HeaderDelayHelp => Status.Snapshot is { } snapshot ? $"After you enter your password, a site stays blocked for {Formatting.Duration(CountdownMath.Clamp(snapshot.DelaySeconds))} before it opens." : null;

    /// <summary>The banners to show right now, with live countdowns.</summary>
    public IReadOnlyList<Banner> CurrentBanners() => Status.Snapshot is { } snapshot ? Banners.Build(snapshot, Status.Remaining, Status.Updater) : [];

    /// <summary>True when the banner area shows at all.</summary>
    public bool HasBannerContent => Status.Snapshot is { } snapshot && Banners.HasContent(snapshot, Status.Feedback, Status.Updater?.ShowsBanner == true);

    /// <summary>Opens Settings (the footer button or the tray menu). It shows only while a password exists.</summary>
    public void OpenSettings() => ShowingSettings = true;

    /// <summary>The Settings back button: returns home and forgets what was typed in Settings.</summary>
    public void CloseSettings()
    {
        Settings.Leave();
        ShowingSettings = false;
    }

    /// <summary>Called when the panel opens or closes. Closing forgets every typed password and open form and returns to the home screen.</summary>
    public async Task PanelVisibilityChangedAsync(bool visible)
    {
        if (!visible)
        {
            Home.Reset();
            Settings.Leave();
            List.Reset();
            if (Status.Snapshot is { } snapshot) List.Update(snapshot);
            ShowingSettings = false;
        }
        await Status.PanelVisibilityChangedAsync(visible);
        if (visible) Home.FocusAddFieldRequested = true;
    }
}

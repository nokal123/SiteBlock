using System.Windows;
using System.Windows.Threading;
using SiteBlock.AppLogic;
using SiteBlock.Core;

namespace SiteBlock.App;

/// <summary>The entry point of SiteBlockApp.exe.</summary>
internal static class Program
{
    /// <summary>The per-session mutex that marks the running copy. "Local\" makes it per signed-in session, so each person at the PC gets their own tray app.</summary>
    private const string MutexName = @"Local\SiteBlockApp.SingleInstance";

    /// <summary>The per-session event a second copy sets to ask the running copy to open its panel.</summary>
    private const string OpenEventName = @"Local\SiteBlockApp.OpenPanel";

    /// <summary>
    /// Starts the tray app, unless a copy already runs in this session: then it asks that copy to open its panel and exits. The event is created before the mutex is checked, so the running copy can never miss a request that arrives while it is starting.
    /// </summary>
    [STAThread]
    public static int Main()
    {
        using var openEvent = new EventWaitHandle(false, EventResetMode.AutoReset, OpenEventName);
        using var mutex = new Mutex(true, MutexName, out bool firstCopy);
        if (!firstCopy)
        {
            // This copy was just started by the person, so it may hand its right to bring a window forward to the running copy.
            NativeMethods.AllowSetForegroundWindow(NativeMethods.AsfwAny);
            openEvent.Set();
            return 0;
        }
        var app = new SiteBlockApplication(openEvent);
        app.Run();
        GC.KeepAlive(mutex);
        return 0;
    }
}

/// <summary>
/// The WPF application: builds the models and their Windows backends, the tray icon and the panel, and keeps them in step. It never exits by itself; the service's AppGuard also restarts it within 5 seconds if it is stopped.
/// </summary>
internal sealed class SiteBlockApplication : Application
{
    private readonly EventWaitHandle _openEvent;
    private RegisteredWaitHandle? _openWait;
    private StatusModel? _status;
    private PanelWindow? _panel;
    private TrayIcon? _tray;
    private readonly FileAppLog _log = new();

    /// <summary>Creates the application; <paramref name="openEvent"/> is set by a second copy that wants the panel opened.</summary>
    public SiteBlockApplication(EventWaitHandle openEvent)
    {
        _openEvent = openEvent;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
    }

    /// <summary>Builds everything and starts polling the service.</summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandledException;

        var context = new DispatcherSynchronizationContext(Dispatcher);
        SynchronizationContext.SetSynchronizationContext(context);
        var ui = new SynchronizationContextDispatcher(context);
        IClock clock = SystemClock.Instance;

        var updater = new Updater(new HttpUpdateDownloader(), new UacElevatedRunner(), new RegistryDismissedUpdateStore(), clock, ui);
        var tabWatcher = new TabWatcher(new UiaBrowserTabs(_log), clock, _log);
        _status = new StatusModel(new CoreDaemonClient(new DaemonClient()), clock, ui, updater, tabWatcher);
        var panelModel = new PanelModel(_status);

        _panel = new PanelWindow(panelModel);
        _tray = new TrayIcon();
        _tray.Clicked += () => _panel.Toggle();
        _tray.OpenRequested += () => _panel.ShowPanel();
        _tray.SettingsRequested += () => _panel.ShowPanel(settings: true);
        _panel.ThemeChanged += UpdateTrayIcon;
        _status.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(StatusModel.ServiceUnreachable)) UpdateTrayIcon();
        };

        // A second copy sets the event; the panel is opened on the window thread.
        _openWait = ThreadPool.RegisterWaitForSingleObject(_openEvent, (_, _) => Dispatcher.BeginInvoke(() => _panel.ShowPanel()), null, Timeout.Infinite, executeOnlyOnce: false);

        _status.Start();
        _log.Info("tray app started");
    }

    /// <summary>Stops the background work and removes the tray icon.</summary>
    protected override void OnExit(ExitEventArgs e)
    {
        _openWait?.Unregister(null);
        _status?.Dispose();
        _tray?.Dispose();
        base.OnExit(e);
    }

    /// <summary>Redraws the tray shield for the service's state and the taskbar's colors.</summary>
    private void UpdateTrayIcon() => _tray?.Update(_status?.ServiceUnreachable == true);

    /// <summary>Logs an unexpected error in the window code by its type only (a message could name a site) and keeps the app running, because the tray icon must stay.</summary>
    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        _log.Info($"unexpected error in the panel: {e.Exception.GetType().FullName}");
        e.Handled = true;
    }
}

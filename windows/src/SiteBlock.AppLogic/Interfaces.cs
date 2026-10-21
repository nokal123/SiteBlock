using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>Sends one request to the SiteBlock service and returns its response. Every failure to get a response is a <see cref="DaemonClientException"/> (not running, timeout, or a reply that could not be read).</summary>
public interface IDaemonClient
{
    /// <summary>Sends <paramref name="request"/> and returns the service's response, or throws <see cref="DaemonClientException"/>. It never blocks the calling thread.</summary>
    Task<Response> SendAsync(Request request, CancellationToken ct = default);
}

/// <summary>The two kinds of time the app needs, behind one interface so tests can move time by hand: a clock that only goes forward (for countdowns) and the wall clock (for "opens at 3:42 PM").</summary>
public interface IClock
{
    /// <summary>Milliseconds on a clock that never goes backwards and ignores changes to the wall clock. Only differences between two readings mean anything.</summary>
    long MonotonicMilliseconds { get; }

    /// <summary>The current wall-clock time.</summary>
    DateTimeOffset Now { get; }

    /// <summary>Completes after <paramref name="delay"/> has passed, or throws <see cref="OperationCanceledException"/> when <paramref name="ct"/> is cancelled first.</summary>
    Task Delay(TimeSpan delay, CancellationToken ct);
}

/// <summary>Runs work on the thread that owns the screen (the WPF dispatcher thread), so the models only change while that thread is the one reading them. Tests use <see cref="InlineUiDispatcher"/>.</summary>
public interface IUiDispatcher
{
    /// <summary>Runs <paramref name="action"/> on the screen's thread and completes once it has run. When called on that thread already, it runs the action at once.</summary>
    Task InvokeAsync(Action action);
}

/// <summary>Where the tray app writes its few log lines. A line must never hold a password, a domain, a web address or a path rule.</summary>
public interface IAppLog
{
    /// <summary>Writes one line.</summary>
    void Info(string message);
}

/// <summary>Keeps the build number of the update the person answered "Not now" to, so the banner stays hidden for that build after the app restarts.</summary>
public interface IDismissedUpdateStore
{
    /// <summary>The dismissed build number, or 0 when nothing is stored or the stored value cannot be read.</summary>
    int Load();

    /// <summary>Stores <paramref name="build"/> as the dismissed build.</summary>
    void Save(int build);

    /// <summary>Forgets the dismissed build, so the banner shows for every newer build again.</summary>
    void Clear();
}

/// <summary>One running Chrome, Edge or Brave process that owns at least one browser window.</summary>
/// <param name="ProcessId">The Windows process id.</param>
/// <param name="DisplayName">The browser's name as people know it, such as "Google Chrome". It is the only thing about a browser the log ever names.</param>
public sealed record BrowserProcess(int ProcessId, string DisplayName);

/// <summary>The address shown in one browser window's address bar, which is the address of that window's visible tab.</summary>
/// <param name="WindowId">The window handle written as a decimal number. The tab watcher uses it as the tab id.</param>
/// <param name="Url">The address with a scheme, such as https://youtube.com/shorts/abc (see <see cref="BrowserAddress.ToUrl"/>).</param>
public sealed record BrowserWindowAddress(string WindowId, string Url);

/// <summary>Reads and reloads the visible tab of each Chrome, Edge and Brave window. On Windows this is UI Automation; tests use a fake. Every method may throw when a browser quits or stops answering; the tab watcher treats that as "skip this one for now".</summary>
public interface IBrowserTabs
{
    /// <summary>The supported browser processes that own a visible, titled browser window right now.</summary>
    IReadOnlyList<BrowserProcess> RunningBrowsers();

    /// <summary>The address of each readable window of one process. A window whose address bar has keyboard focus (the person may be typing) or exposes no address bar is left out.</summary>
    IReadOnlyList<BrowserWindowAddress> ReadWindows(int processId);

    /// <summary>Reads one window's address again, in the same form as <see cref="ReadWindows"/> gives it, or returns null when it cannot be read now (gone, or the address bar has keyboard focus).</summary>
    string? CurrentUrl(int processId, string windowId);

    /// <summary>Presses the window's reload button, which reloads its visible tab. Throws when the button cannot be found or pressed.</summary>
    void Reload(int processId, string windowId);
}

/// <summary>Downloads the update files from GitHub. Production uses HttpClient; tests use a fake.</summary>
public interface IUpdateDownloader
{
    /// <summary>
    /// Fetches the version file at <paramref name="url"/>, following redirects and keeping no cookies. Returns its bytes only for a 200 answer of at most <paramref name="maxBytes"/> bytes that arrived within <paramref name="timeout"/>; any failure returns null.
    /// </summary>
    Task<byte[]?> FetchVersionFileAsync(Uri url, TimeSpan timeout, int maxBytes, CancellationToken ct);

    /// <summary>Downloads the package at <paramref name="url"/> into <paramref name="destinationPath"/> within <paramref name="timeout"/>. Returns false on any failure (no network, an answer other than 200, too slow).</summary>
    Task<bool> DownloadFileAsync(Uri url, string destinationPath, TimeSpan timeout, CancellationToken ct);
}

/// <summary>How a program started with administrator rights ended.</summary>
public enum ElevatedRunOutcome
{
    /// <summary>The program ran and exited; <see cref="ElevatedRunResult.ExitCode"/> holds its exit code.</summary>
    Exited,
    /// <summary>The person answered "No" in the UAC prompt, so nothing ran.</summary>
    Cancelled,
    /// <summary>The program could not be started for another reason.</summary>
    Failed,
    /// <summary>The program started but did not exit within the time allowed.</summary>
    TimedOut,
}

/// <summary>The result of <see cref="IElevatedRunner.RunAsync"/>.</summary>
/// <param name="Outcome">How it ended.</param>
/// <param name="ExitCode">The program's exit code when <paramref name="Outcome"/> is <see cref="ElevatedRunOutcome.Exited"/>, otherwise 0.</param>
public sealed record ElevatedRunResult(ElevatedRunOutcome Outcome, int ExitCode = 0);

/// <summary>Starts a program with administrator rights, which makes Windows show the UAC prompt. Production uses ShellExecute with the "runas" verb; tests use a fake.</summary>
public interface IElevatedRunner
{
    /// <summary>
    /// Starts <paramref name="fileName"/> with <paramref name="arguments"/> elevated and waits up to <paramref name="timeout"/> for it to exit.
    /// <paramref name="onStarted"/> is called once the person has accepted the prompt and the program is running.
    /// </summary>
    Task<ElevatedRunResult> RunAsync(string fileName, string arguments, Action onStarted, TimeSpan timeout, CancellationToken ct);
}

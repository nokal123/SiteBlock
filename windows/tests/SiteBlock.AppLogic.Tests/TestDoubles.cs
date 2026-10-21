using System.Collections.Concurrent;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using SiteBlock.AppLogic;
using SiteBlock.Core;

namespace SiteBlock.AppLogic.Tests;

// A clock that only moves when a test calls Advance. Every Delay call is recorded and parked until enough time has passed or its token is cancelled.
public sealed class ManualClock : IClock
{
    private readonly Lock _gate = new();
    private readonly List<Waiter> _waiters = [];
    private readonly List<TimeSpan> _requested = [];
    private long _nowMs;

    private sealed record Waiter(long DueMs, TimeSpan Delay, TaskCompletionSource Done);

    public long MonotonicMilliseconds { get { lock (_gate) return _nowMs; } }

    public DateTimeOffset Now { get; set; } = new(2026, 10, 22, 15, 0, 0, TimeSpan.Zero);

    // Every delay any caller has asked for, in order.
    public IReadOnlyList<TimeSpan> RequestedDelays { get { lock (_gate) return [.. _requested]; } }

    // How many callers are parked on a delay of exactly this length right now.
    public int Parked(TimeSpan delay) { lock (_gate) return _waiters.Count(w => w.Delay == delay); }

    // Parks the caller until Advance has moved the clock past the due time, or fails it with OperationCanceledException when the token is cancelled first.
    public Task Delay(TimeSpan delay, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) return Task.FromCanceled(ct);
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Waiter waiter;
        lock (_gate)
        {
            waiter = new Waiter(_nowMs + (long)delay.TotalMilliseconds, delay, done);
            _waiters.Add(waiter);
            _requested.Add(delay);
        }
        if (ct.CanBeCanceled)
        {
            ct.Register(() =>
            {
                lock (_gate) _waiters.Remove(waiter);
                done.TrySetCanceled(ct);
            });
        }
        return done.Task;
    }

    // Moves the clock forward and releases every parked caller whose time has come.
    public void Advance(TimeSpan by)
    {
        List<Waiter> due;
        lock (_gate)
        {
            _nowMs += (long)by.TotalMilliseconds;
            due = _waiters.Where(w => w.DueMs <= _nowMs).ToList();
            foreach (Waiter w in due) _waiters.Remove(w);
        }
        foreach (Waiter w in due) w.Done.TrySetResult();
    }
}

// A service stand-in: answers each request with the handler's response (by default the current snapshot) and records every request.
public sealed class FakeDaemonClient : IDaemonClient
{
    private readonly ConcurrentQueue<Request> _requests = new();

    public FakeDaemonClient(StatusSnapshot snapshot) => Snapshot = snapshot;

    // The snapshot a status request returns while no handler is set.
    public StatusSnapshot Snapshot { get; set; }

    // Decides the answer for a request; null means "always ok with the current snapshot".
    public Func<Request, Task<Response>>? Handler { get; set; }

    public IReadOnlyList<Request> Requests => [.. _requests];

    public IReadOnlyList<Request> Commands => Requests.Where(r => r.Command != Command.Status).ToList();

    public int StatusCount => Requests.Count(r => r.Command == Command.Status);

    // Records the request and returns the handler's answer.
    public Task<Response> SendAsync(Request request, CancellationToken ct = default)
    {
        _requests.Enqueue(request);
        return Handler is { } handler ? handler(request) : Task.FromResult(Response.Success(Snapshot));
    }
}

// A browser stand-in: each process has a list of windows; CurrentUrl returns what a test set (or the window's own address); Reload is recorded.
public sealed class FakeBrowserTabs : IBrowserTabs
{
    private readonly Lock _gate = new();

    public List<BrowserProcess> Browsers { get; } = [];
    public Dictionary<int, List<BrowserWindowAddress>> Windows { get; } = [];
    // Overrides for the second read of one window, keyed by (process, window); a null value means "cannot be read now".
    public Dictionary<(int, string), string?> CurrentOverrides { get; } = [];
    public HashSet<int> UnreadableProcesses { get; } = [];
    public bool ReloadThrows { get; set; }
    public Func<IReadOnlyList<BrowserProcess>>? RunningBrowsersHook { get; set; }

    public List<(int Pid, string Window)> Reloads { get; } = [];
    public List<int> ReadWindowsCalls { get; } = [];
    public List<(int Pid, string Window)> CurrentUrlCalls { get; } = [];
    public int RunningBrowsersCalls { get; private set; }

    public int TotalCalls { get { lock (_gate) return RunningBrowsersCalls + ReadWindowsCalls.Count + CurrentUrlCalls.Count + Reloads.Count; } }

    // Lists the browsers the test put in.
    public IReadOnlyList<BrowserProcess> RunningBrowsers()
    {
        lock (_gate) RunningBrowsersCalls++;
        return RunningBrowsersHook is { } hook ? hook() : [.. Browsers];
    }

    // Returns the windows of one process, or throws for a process the test made unreadable.
    public IReadOnlyList<BrowserWindowAddress> ReadWindows(int processId)
    {
        lock (_gate) ReadWindowsCalls.Add(processId);
        if (UnreadableProcesses.Contains(processId)) throw new InvalidOperationException("browser stopped answering");
        return Windows.TryGetValue(processId, out var list) ? [.. list] : [];
    }

    // Returns the override for this window when there is one, otherwise the window's listed address.
    public string? CurrentUrl(int processId, string windowId)
    {
        lock (_gate) CurrentUrlCalls.Add((processId, windowId));
        if (CurrentOverrides.TryGetValue((processId, windowId), out string? over)) return over;
        return Windows.TryGetValue(processId, out var list) ? list.FirstOrDefault(w => w.WindowId == windowId)?.Url : null;
    }

    // Records the reload, or throws when the test asked for a failing reload button.
    public void Reload(int processId, string windowId)
    {
        if (ReloadThrows) throw new InvalidOperationException("no reload button");
        lock (_gate) Reloads.Add((processId, windowId));
    }

    // Puts one process with the given windows in place of any earlier list for it.
    public void SetWindows(int pid, params (string Id, string Url)[] windows) => Windows[pid] = windows.Select(w => new BrowserWindowAddress(w.Id, w.Url)).ToList();
}

// Collects every log line.
public sealed class RecordingLog : IAppLog
{
    private readonly ConcurrentQueue<string> _lines = new();
    public IReadOnlyList<string> Lines => [.. _lines];
    public void Info(string message) => _lines.Enqueue(message);
}

// Serves a version file from memory and "downloads" the package by writing the given bytes, recording every address asked for.
public sealed class FakeDownloader : IUpdateDownloader
{
    private readonly ConcurrentQueue<Uri> _fetches = new();
    private readonly ConcurrentQueue<(Uri Url, string Destination)> _downloads = new();

    public Func<byte[]?> VersionFile { get; set; } = () => null;
    public byte[]? Package { get; set; }

    public IReadOnlyList<Uri> Fetches => [.. _fetches];
    public IReadOnlyList<(Uri Url, string Destination)> Downloads => [.. _downloads];

    public Task<byte[]?> FetchVersionFileAsync(Uri url, TimeSpan timeout, int maxBytes, CancellationToken ct)
    {
        _fetches.Enqueue(url);
        return Task.FromResult(VersionFile());
    }

    public Task<bool> DownloadFileAsync(Uri url, string destinationPath, TimeSpan timeout, CancellationToken ct)
    {
        _downloads.Enqueue((url, destinationPath));
        if (Package is null) return Task.FromResult(false);
        File.WriteAllBytes(destinationPath, Package);
        return Task.FromResult(true);
    }
}

// Stands in for the UAC prompt: returns the configured outcome and records what it was asked to run.
public sealed class FakeElevatedRunner : IElevatedRunner
{
    public ElevatedRunResult Result { get; set; } = new(ElevatedRunOutcome.Exited, 0);
    public List<(string FileName, string Arguments)> Runs { get; } = [];
    // Called while the "program" runs, after onStarted, so a test can look at the disk at that moment.
    public Action? WhileRunning { get; set; }

    public Task<ElevatedRunResult> RunAsync(string fileName, string arguments, Action onStarted, TimeSpan timeout, CancellationToken ct)
    {
        Runs.Add((fileName, arguments));
        if (Result.Outcome is ElevatedRunOutcome.Exited or ElevatedRunOutcome.TimedOut)
        {
            onStarted();
            WhileRunning?.Invoke();
        }
        return Task.FromResult(Result);
    }

    // The PowerShell script inside the -EncodedCommand argument of one run.
    public static string DecodeScript(string arguments)
    {
        const string flag = "-EncodedCommand ";
        int at = arguments.IndexOf(flag, StringComparison.Ordinal);
        Assert.True(at >= 0, "the elevated PowerShell was not given -EncodedCommand");
        string encoded = arguments[(at + flag.Length)..].Split(' ')[0];
        return Encoding.Unicode.GetString(Convert.FromBase64String(encoded));
    }
}

// Builders for the status snapshots and update files the tests feed in.
public static class Fixtures
{
    // A status snapshot with the given parts; everything else is quiet (no banners, hosts healthy, filter on).
    public static StatusSnapshot Snapshot(bool passwordSet = true, IReadOnlyList<BlockedSiteStatus>? sites = null, long delay = 1800, IReadOnlyList<BlockedPathStatus>? paths = null) =>
        new("1.0.5", passwordSet, sites ?? [], delay, null, null, null, null, true, true, paths ?? []);

    public static BlockedSiteStatus Site(string domain, long? pending = null, TemporaryUnblockStatus? temporary = null) => new(domain, [domain, "www." + domain], pending, temporary);

    public static BlockedPathStatus Rule(string domain, string path, long? pending = null, TemporaryUnblockStatus? temporary = null) => new(domain, path, domain + path, pending, temporary);

    // A temporary unblock still waiting to open: opens in `opensIn` seconds and then stays open for `window`.
    public static TemporaryUnblockStatus Waiting(long opensIn, long window) => new(opensIn, window, window, false);

    // A temporary unblock that is open with `left` seconds of a `window`-second window remaining.
    public static TemporaryUnblockStatus Open(long left, long window) => new(null, left, window, true);

    public const string Commit = "0123456789abcdef0123456789abcdef01234567";

    // The bytes of a Windows version file for `build`, with the given checksum and optional display version.
    public static byte[] VersionFile(int build, string sha256, string? displayVersion = null, string asset = "SiteBlock-Windows.zip")
    {
        string display = displayVersion is null ? "" : $",\"displayVersion\":\"{displayVersion}\"";
        return Encoding.UTF8.GetBytes($"{{\"version\":\"1.0.{build}\",\"build\":{build},\"commit\":\"{Commit}\",\"asset\":\"{asset}\",\"sha256\":\"{sha256}\"{display}}}");
    }

    public static string Sha256(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    // The files a complete Windows package holds for one processor folder, as zip entry names.
    public static IReadOnlyList<string> PackageEntries(string arch = "x64") =>
    [
        $"SiteBlock/bin/{arch}/siteblockd.exe",
        $"SiteBlock/bin/{arch}/siteblock.exe",
        $"SiteBlock/bin/{arch}/SiteBlockApp.exe",
        "SiteBlock/scripts/install.ps1",
        "SiteBlock/Install SiteBlock.cmd",
    ];

    // A real zip in memory holding one small file per entry name.
    public static byte[] Zip(IEnumerable<string> entries)
    {
        using var memory = new MemoryStream();
        using (var archive = new ZipArchive(memory, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (string name in entries)
            {
                ZipArchiveEntry entry = archive.CreateEntry(name);
                if (name.EndsWith('/')) continue;
                using Stream stream = entry.Open();
                stream.Write(Encoding.UTF8.GetBytes("content of " + name));
            }
        }
        return memory.ToArray();
    }
}

// Waiting helpers for code that runs on pool threads.
public static class Wait
{
    // Polls the condition until it holds, failing the test after the timeout.
    public static async Task Until(Func<bool> condition, string what, int timeoutMs = 5000)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.ElapsedMilliseconds > timeoutMs) Assert.Fail("timed out waiting for: " + what);
            await Task.Delay(5);
        }
    }
}

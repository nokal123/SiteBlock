using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using SiteBlock.Core;

namespace SiteBlock.Integration.Tests.Support;

// A real siteblockd started in sandbox mode in its own short temporary folder (06-windows.md § Testing item 2; 05-testing-and-operations.md § Integration Tests).
// Dispose stops the process and deletes the folder, so a failing test still cleans up.
internal sealed class SandboxDaemon : IDisposable
{
    // The starting hosts file: comment lines and the loopback lines a Windows hosts file carries, plus one user line SiteBlock must keep.
    public const string StartingHosts = "# Copyright (c) 1993-2009 Microsoft Corp.\n#\n# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.\n127.0.0.1 localhost\n::1 localhost\n10.1.2.3 intranet.example.org\n";

    private readonly StringBuilder _stderr = new();
    private Process? _process;

    public string Root { get; }
    public double TickSeconds { get; }
    public string PipePath => Path.Combine(Root, "siteblock.pipe");
    public string HostsPath => Path.Combine(Root, "hosts");
    public string StatePath => Path.Combine(Root, "state", "state.json");
    public string StateBackupPath => Path.Combine(Root, "backup", "state.backup.json");
    public string RegistryPath => Path.Combine(Root, "registry.json");
    public string NetworkServicesPath => Path.Combine(Root, "network-services.json");
    public string LogPath => Path.Combine(Root, "logs", "siteblockd.log");
    public string UnreachableMarkerPath => Path.Combine(Root, "family-dns-unreachable");
    public Process Process => _process ?? throw new InvalidOperationException("the daemon was not started");

    private SandboxDaemon(string root, double tickSeconds)
    {
        Root = root;
        TickSeconds = tickSeconds;
    }

    // A new folder with a short random name: under /tmp on macOS and Linux (a Unix socket path must stay within 103 bytes), under the temp folder on Windows.
    public static string NewRoot()
    {
        string parent = OperatingSystem.IsWindows() ? Path.GetTempPath() : "/tmp";
        string root = Path.Combine(parent, "sbq" + Guid.NewGuid().ToString("N")[..10]);
        Directory.CreateDirectory(root);
        return root;
    }

    // Creates the sandbox folder and its starting files without starting the daemon; prepare may add more files (registry.json, network-services.json, state).
    public static SandboxDaemon Create(double tickSeconds = 0.2, string? hosts = StartingHosts, Action<SandboxDaemon>? prepare = null)
    {
        var daemon = new SandboxDaemon(NewRoot(), tickSeconds);
        if (hosts is not null) File.WriteAllText(daemon.HostsPath, hosts);
        prepare?.Invoke(daemon);
        return daemon;
    }

    // Creates the sandbox and starts the daemon, waiting until it answers status.
    public static SandboxDaemon Start(double tickSeconds = 0.2, string? hosts = StartingHosts, Action<SandboxDaemon>? prepare = null)
    {
        var daemon = Create(tickSeconds, hosts, prepare);
        try
        {
            daemon.Launch();
            daemon.WaitUntilReady();
            return daemon;
        }
        catch
        {
            daemon.Dispose();
            throw;
        }
    }

    // The flags every sandbox run uses.
    public IReadOnlyList<string> Arguments => ["--daemon", "--sandbox", Root, "--tick", TickSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture), "--policy-fast"];

    // Starts (or restarts) the siteblockd child process. Its standard error is read in the background so a full pipe can never stall the daemon's log writes.
    public void Launch()
    {
        var process = Process.Start(Programs.StartInfo(Programs.DaemonDll, Arguments)) ?? throw new InvalidOperationException("could not start siteblockd");
        process.ErrorDataReceived += (_, line) => { if (line.Data is not null) lock (_stderr) _stderr.AppendLine(line.Data); };
        process.OutputDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        _process = process;
    }

    // Everything the daemon has written to standard error so far.
    public string StandardError
    {
        get { lock (_stderr) return _stderr.ToString(); }
    }

    // Polls status until the daemon answers, or fails with what it printed when it exits or takes longer than the limit.
    public void WaitUntilReady(double seconds = 15)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < TimeSpan.FromSeconds(seconds))
        {
            if (Process.HasExited) throw new InvalidOperationException($"siteblockd exited with code {Process.ExitCode} before it was ready:\n{StandardError}");
            try
            {
                if (Client(TimeSpan.FromSeconds(2)).Send(new Request(Command.Status)).Ok) return;
            }
            catch (DaemonClientException) { }
            Thread.Sleep(50);
        }
        throw new TimeoutException($"siteblockd did not answer status within {seconds} s:\n{StandardError}");
    }

    // A real client for this sandbox's pipe.
    public DaemonClient Client(TimeSpan? timeout = null) => new(PipePath, timeout ?? TimeSpan.FromSeconds(15));

    // Sends one request with the real client and returns the response.
    public Response Send(Request request) => Client().Send(request);

    // Sends a request, retrying (up to about 2 s) only when no reply arrives at all. A connection over the per-user limit is closed without a reply by design, and a slot is freed only
    // once the server has seen the previous client hang up, so back-to-back requests on a loaded machine can meet a slot that is still being released.
    public Response SendPatiently(Request request)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { return Client().Send(request); }
            catch (DaemonClientException error) when (error.Error == ClientError.BadResponse && attempt < 40) { Thread.Sleep(50); }
        }
    }

    // Sets the first password with setup, failing the test when it is refused.
    public void Setup(string password = Defaults.Password)
    {
        var response = Send(new Request(Command.Setup, Password: password));
        Assert.True(response.Ok, $"setup refused: {response.ErrorCode} {response.Error}");
    }

    // Sets the password and blocks the given sites, failing the test when anything is refused.
    public void SetupAndAdd(params string[] sites)
    {
        Setup();
        foreach (string site in sites)
        {
            var response = Send(new Request(Command.Add, Domain: site));
            Assert.True(response.Ok, $"add {site} refused: {response.ErrorCode} {response.Error}");
        }
    }

    public StatusSnapshot Status() => Send(new Request(Command.Status)).Status ?? throw new InvalidOperationException("status reply without a snapshot");

    public string HostsText() => ReadShared(HostsPath);

    public string LogText() => File.Exists(LogPath) ? ReadShared(LogPath) : "";

    // Reads a file that the daemon may be rewriting at the same moment, retrying briefly when it is locked or replaced mid-read (Windows).
    public static string ReadShared(string path)
    {
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream, Encoding.UTF8);
                return reader.ReadToEnd();
            }
            catch (IOException) when (attempt < 50)
            {
                Thread.Sleep(20);
            }
            catch (UnauthorizedAccessException) when (attempt < 50)
            {
                Thread.Sleep(20);
            }
        }
    }

    // The sandbox registry as a JSON object (empty when the file is missing).
    public JsonObject Registry() => File.Exists(RegistryPath) ? (JsonNode.Parse(ReadShared(RegistryPath)) as JsonObject ?? []) : [];

    // The sandbox adapters file as a JSON object.
    public JsonObject NetworkServices() => JsonNode.Parse(ReadShared(NetworkServicesPath)) as JsonObject ?? [];

    // The saved state file as a JSON object.
    public JsonObject StateJson() => JsonNode.Parse(ReadShared(StatePath)) as JsonObject ?? throw new InvalidOperationException("state.json is not an object");

    // Writes a file the way a person editing it would: in place, all at once.
    public static void WriteAllText(string path, string text)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { File.WriteAllText(path, text); return; }
            catch (IOException) when (attempt < 50) { Thread.Sleep(20); }
            catch (UnauthorizedAccessException) when (attempt < 50) { Thread.Sleep(20); }
        }
    }

    // How many lines of the log contain the text.
    public int LogCount(string text) => LogText().Split('\n').Count(line => line.Contains(text, StringComparison.Ordinal));

    // Waits until the log holds at least the given number of lines with the text.
    public bool WaitForLogCount(string text, int atLeast, double seconds = 5) => Wait.Until(() => LogCount(text) >= atLeast, seconds);

    // Sends the polite stop: SIGTERM on macOS and Linux. Windows has no signal a test can send to a console child without sharing its console, so callers skip there.
    public void SendTerminate()
    {
        if (OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("SIGTERM is not available on Windows");
        if (Kill(Process.Id, 15) != 0) throw new InvalidOperationException("kill(SIGTERM) failed");
    }

    [DllImport("libc", EntryPoint = "kill", SetLastError = true)]
    private static extern int Kill(int pid, int signal);

    // Waits for the daemon to exit by itself and returns its exit code, or null when it is still running after the limit.
    public int? WaitForExit(double seconds)
    {
        if (!Process.WaitForExit(TimeSpan.FromSeconds(seconds))) return null;
        return Process.ExitCode;
    }

    // Kills the daemon at once (no save), as a crash would.
    public void KillHard()
    {
        if (_process is null || _process.HasExited) return;
        try { _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        _process.WaitForExit(TimeSpan.FromSeconds(10));
    }

    public void Dispose()
    {
        KillHard();
        _process?.Dispose();
        for (int attempt = 0; attempt < 20 && Directory.Exists(Root); attempt++)
        {
            try { Directory.Delete(Root, recursive: true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Thread.Sleep(50); }
        }
    }
}

// Shared test values.
internal static class Defaults
{
    // A password long enough for the 6-character minimum; it must never appear in the daemon log.
    public const string Password = "Qz7-lantern-Pw";
}

// Polling helpers.
internal static class Wait
{
    // Polls the condition every 20 ms until it holds or the time runs out; returns the last result.
    public static bool Until(Func<bool> condition, double seconds)
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            if (condition()) return true;
            if (clock.Elapsed > TimeSpan.FromSeconds(seconds)) return condition();
            Thread.Sleep(20);
        }
    }
}

// Runs a test only on macOS and Linux, with the reason shown on Windows.
public sealed class UnixFactAttribute : FactAttribute
{
    public UnixFactAttribute(string reason)
    {
        if (OperatingSystem.IsWindows()) Skip = reason;
    }
}

// Runs a test only on Windows, with the reason shown elsewhere.
public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute(string reason)
    {
        if (!OperatingSystem.IsWindows()) Skip = reason;
    }
}

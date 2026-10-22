using System.Collections.Concurrent;
using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// Runs work items one at a time, in the order they arrive, on one dedicated thread. The runtime puts every touch of the engine on it,
/// so a command and a timer tick can never run at the same time (the Mac uses a serial dispatch queue for the same job).
/// </summary>
internal sealed class EngineThread
{
    private readonly BlockingCollection<Action> _queue = new();
    private readonly Thread _thread;
    private readonly Action<Exception> _onError;

    /// <summary>Starts the thread. <paramref name="onError"/> is told about any exception a work item throws; the thread keeps running afterwards.</summary>
    public EngineThread(string name, Action<Exception> onError)
    {
        _onError = onError;
        _thread = new Thread(Loop) { IsBackground = true, Name = name };
        _thread.Start();
    }

    /// <summary>Queues a work item. Returns false when the thread has been shut down, so the item will never run.</summary>
    public bool Post(Action work)
    {
        try
        {
            _queue.Add(work);
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>Runs the function on the engine thread and returns a task for its result. A function that throws faults the task, and a shut-down thread cancels it.</summary>
    public Task<T> InvokeAsync<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        bool queued = Post(() =>
        {
            try { done.SetResult(work()); }
            catch (Exception error) { done.SetException(error); }
        });
        if (!queued) done.TrySetCanceled();
        return done.Task;
    }

    /// <summary>Stops taking new work. Items already queued still run.</summary>
    public void Shutdown() => _queue.CompleteAdding();

    /// <summary>Takes items off the queue and runs them until the queue is shut down. An exception in one item is reported and never stops the thread.</summary>
    private void Loop()
    {
        foreach (var work in _queue.GetConsumingEnumerable())
        {
            try { work(); }
            catch (Exception error) { _onError(error); }
        }
    }
}

/// <summary>
/// Counts requests that were turned away, per caller, and writes one summary line per caller each minute, such as
/// "37 rejected requests from user S-1-5-21-…-1001 in the last minute". This keeps a flood of bad requests from filling the log with one line each. Safe to call from any thread.
/// </summary>
internal sealed class RejectedRequestCounter
{
    private readonly object _lock = new();
    private readonly Dictionary<string, int> _counts = new(StringComparer.OrdinalIgnoreCase);
    private readonly Log _log;
    private Timer? _timer;

    /// <summary>Creates a counter that writes its summary lines to the log. Nothing is written until <see cref="Start"/> or <see cref="Flush"/>.</summary>
    public RejectedRequestCounter(Log log) => _log = log;

    /// <summary>Adds one rejected request from this caller to the running count.</summary>
    public void Record(Peer peer)
    {
        lock (_lock) _counts[peer.UserId] = _counts.GetValueOrDefault(peer.UserId) + 1;
    }

    /// <summary>Starts the timer that writes the summary lines once a minute.</summary>
    public void Start()
    {
        lock (_lock) _timer ??= new Timer(_ => Flush(), null, TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));
    }

    /// <summary>Writes one line for each caller with rejected requests since the last flush, then starts counting from zero. It also runs at shutdown so the last partial minute is not lost. Writes nothing when nothing was rejected.</summary>
    public void Flush()
    {
        KeyValuePair<string, int>[] snapshot;
        lock (_lock)
        {
            snapshot = [.. _counts.OrderBy(entry => entry.Key, StringComparer.Ordinal)];
            _counts.Clear();
        }
        foreach (var (user, count) in snapshot)
        {
            _log.Write($"{count} rejected {(count == 1 ? "request" : "requests")} from user {user} in the last minute");
        }
    }

    /// <summary>Stops the minute timer.</summary>
    public void Stop()
    {
        lock (_lock)
        {
            _timer?.Dispose();
            _timer = null;
        }
    }
}

/// <summary>
/// Everything the runtime calls outside the engine: the enforcers, the guards and the uninstaller's Windows steps.
/// Production fills it with the Windows implementations; a sandbox run fills it with file-backed stand-ins and leaves the service guard out.
/// </summary>
/// <param name="Hosts">Keeps the hosts file equal to the block list.</param>
/// <param name="Browsers">Keeps the browsers' registry policy equal to the block lists.</param>
/// <param name="Dns">Keeps every adapter on the family DNS servers.</param>
/// <param name="AppGuard">Keeps the tray app installed and running.</param>
/// <param name="ServiceGuard">Keeps the watchdog service running; null in a sandbox, which has no services.</param>
/// <param name="AclGuard">Keeps the data folders' access lists right; null when nothing should check them.</param>
/// <param name="ConsoleUser">Returns the SID of the person signed in at the screen, for the engine's setup rule; null in a sandbox, where any caller may set up.</param>
public sealed record DaemonServices(IHostsEnforcer Hosts, IBrowserPolicyEnforcer Browsers, IDnsEnforcer Dns, IAppGuard AppGuard, IServiceGuard? ServiceGuard, IAclGuard? AclGuard, Func<string?>? ConsoleUser)
{
    /// <summary>
    /// Builds the services for these paths. A sandbox gets the file-backed stand-ins (the sandbox hosts file, registry.json and network-services.json) and no service guard;
    /// production gets the Windows implementations. <paramref name="isUninstalling"/> lets the app guard stop at once when an uninstall begins.
    /// </summary>
    public static DaemonServices Create(Paths paths, Log log, TimeSpan tickInterval, Func<bool> isUninstalling)
    {
        var hosts = new HostsEnforcer(paths, log);
        var browsers = new BrowserPolicyEnforcer(PolicyStores.For(paths), log);
        var dns = DnsEnforcer.Create(paths, log, tickInterval);
        var appGuard = new AppGuard(paths, log, isUninstalling);
        if (paths.IsSandbox || !OperatingSystem.IsWindows()) return new DaemonServices(hosts, browsers, dns, appGuard, null, new AclGuard(paths, log), null);
        // The guard also gets the uninstall check, so a pass that began just before the uninstall cannot recreate the watchdog the uninstaller just deleted.
        IServiceGuard serviceGuard = new ServiceGuard(paths, log, new ScServiceControl(), isUninstalling);
        return new DaemonServices(hosts, browsers, dns, appGuard, serviceGuard, new AclGuard(paths, log), ConsoleSession.UserSidOrSystem);
    }
}

/// <summary>
/// Connects the policy engine to the outside world: the pipe, the hosts file, the browsers' registry policy, the DNS settings, the state files, the clock and the guards.
/// It follows 03-daemon-cli-app.md § DaemonRuntime with the Windows differences in 06-windows.md § DaemonRuntime: one engine thread, elapsed time from
/// <see cref="Environment.TickCount64"/>, and a stop request that saves the state and exits with code 0.
/// </summary>
public sealed class DaemonRuntime
{
    // The longest stretch of time one tick may count (7 days). TickCount64 keeps counting while the PC sleeps and cannot be set by the person, so a long sleep counts; the cap only stops an absurd reading from finishing every countdown at once.
    private const double MaxElapsedPerTick = 604_800;
    // How often the guard timer runs: the watchdog check (production), the folder access lists and the tray app guard.
    private static readonly TimeSpan GuardInterval = TimeSpan.FromSeconds(5);
    // After a failed attempt to repair the state files, wait this long before trying again, so a full disk does not fill the log.
    private const long RepairRetryMs = 30_000;
    // If an uninstall started but nothing has stopped the service after this long, exit so the service restarts and the uninstall is retried.
    private static readonly TimeSpan UninstallGiveUp = TimeSpan.FromSeconds(120);

    /// <summary>The commands that compare a password against the stored one.</summary>
    private static readonly HashSet<Command> PasswordCommands = [Command.Unblock, Command.UnblockPath, Command.TemporaryUnblock, Command.TemporaryUnblockPath, Command.SetDelay, Command.ChangePassword, Command.Uninstall];

    private readonly Paths _paths;
    private readonly Policy _policy;
    private readonly TimeSpan _tickInterval;
    private readonly Log _log;
    private readonly StateStore _store;
    private readonly DaemonServices _services;
    private readonly RejectedRequestCounter _rejections;
    private readonly EngineThread _thread;
    private readonly Engine _engine;
    // Held while a guard pass runs, so the uninstall can wait for one that is in progress before it deletes what the guards would restore.
    private readonly object _guardLock = new();
    // Completed with the process exit code when the runtime must stop: 0 after a stop request or a sandbox uninstall, 1 after a fatal startup error.
    private readonly TaskCompletionSource<int> _exit = new(TaskCreationOptions.RunContinuationsAsynchronously);
    // True when the saved state had `uninstalling` set without a finished uninstall countdown; startup logs it and saves the corrected state.
    private readonly bool _ignoredUninstallFlag;
    private readonly bool _loadedState;

    private PipeServer? _server;
    // Tries to open the pipe again after it could not be created; true while that is going on, so the failure is logged once.
    private Timer? _pipeRetryTimer;
    private bool _pipeRetrying;
    private static readonly TimeSpan PipeRetryInterval = TimeSpan.FromSeconds(5);
    private Timer? _tickTimer;
    private Timer? _guardTimer;
    // 1 while a tick is queued on the engine thread and has not started, so a slow tick never lets timer callbacks pile up behind it.
    private int _tickQueued;
    // 1 while a DNS pass is queued and has not started, for the same reason.
    private int _dnsQueued;
    // The one clock reading countdowns are measured from (milliseconds from Environment.TickCount64). The tick and the catch-up before each command both read it and move it to now, so no stretch of time is counted twice or skipped.
    private long _lastTick;
    private long _lastSave;
    private long? _lastFailedRepair;
    // 1 once an uninstall has begun; from then on nothing may rewrite the hosts file or the state. Read from several threads, so it is an int changed with Interlocked.
    private int _uninstallStarted;

    /// <summary>
    /// Creates the runtime: makes the state folder, loads the saved state (or a fresh one with the policy's default delay), clears an `uninstalling` flag that has no finished
    /// uninstall countdown behind it, and builds the engine. Nothing runs until <see cref="Run"/>. <paramref name="services"/> replaces the real enforcers and guards in tests.
    /// </summary>
    public DaemonRuntime(Paths paths, Policy policy, TimeSpan tickInterval, Log log, DaemonServices? services = null)
    {
        _paths = paths;
        _policy = policy;
        _tickInterval = tickInterval;
        _log = log;
        _store = new StateStore(paths.StateFile, paths.StateBackup);
        _rejections = new RejectedRequestCounter(log);
        _services = services ?? DaemonServices.Create(paths, log, tickInterval, () => IsUninstalling);

        // Startup step 1: the state folder. In production its access list (SYSTEM and Administrators only) is set by the installer and kept by the folder guard, because it holds the password hash.
        try { Directory.CreateDirectory(paths.StateDir); } catch (Exception error) { log.Write($"cannot create the state folder: {error.Message}"); }

        // Startup step 2: load the saved state (from the main file, or from the backup when the main file is missing or damaged).
        PersistedState? loaded = _store.Load();
        _loadedState = loaded is not null;
        // The `uninstalling` flag is only believed when the uninstall countdown has really finished. A flag with no finished countdown behind it is treated as tampering and cleared, so editing the state file cannot trigger an uninstall.
        if (loaded is { Uninstalling: true, HasFinishedUninstall: false })
        {
            loaded.Uninstalling = false;
            _ignoredUninstallFlag = true;
        }
        _engine = new Engine(loaded ?? PersistedState.Fresh(policy.DefaultDelaySeconds), policy);
        // In production only an administrator or the person signed in at the screen may set the first password. Sandbox runs leave the rule off, because the test user is not the console user.
        if (_services.ConsoleUser is { } consoleUser) _engine.ConsoleUser = consoleUser;
        // Each temporary unblock that is approved, opens, ends or is cancelled gets one log line. The engine builds the sentence and it never names the site or rule.
        _engine.OnTemporaryUnblockEvent = message => _log.Write(message);
        _thread = new EngineThread("siteblockd.engine", error => _log.Write($"internal error on the engine thread: {error.GetType().Name}"));
    }

    /// <summary>True once an uninstall has begun. Safe to read from any thread.</summary>
    public bool IsUninstalling => Volatile.Read(ref _uninstallStarted) == 1;

    /// <summary>
    /// Runs the startup steps in order on the engine thread, then keeps running until a stop request, a sandbox uninstall or a fatal error, and returns the process exit code.
    /// </summary>
    public int Run()
    {
        _thread.Post(() =>
        {
            // A startup step that throws must end the run with code 1; otherwise Run would wait forever on a service that never started.
            try { StartUp(); }
            catch (Exception error)
            {
                _log.Write($"startup failed: {error.GetType().Name}: {error.Message}");
                StopEverything();
                _exit.TrySetResult(1);
            }
        });
        int code = _exit.Task.GetAwaiter().GetResult();
        _thread.Shutdown();
        return code;
    }

    /// <summary>
    /// Asks the runtime to stop: on the engine thread it saves the state (unless an uninstall has begun, because the state folder is about to be deleted), closes the pipe, writes the last rejected-request summary and makes <see cref="Run"/> return 0.
    /// The service control manager's stop request and Ctrl+C in a console run both call it. Safe to call from any thread and more than once.
    /// </summary>
    public void RequestStop(string reason)
    {
        bool queued = _thread.Post(() =>
        {
            if (_exit.Task.IsCompleted) return;
            if (!IsUninstalling) SaveState();
            StopEverything();
            _log.Write($"{reason}; exiting");
            _exit.TrySetResult(0);
        });
        if (!queued) _exit.TrySetResult(0);
    }

    // MARK: Startup

    /// <summary>The startup steps after loading the state. Runs on the engine thread.</summary>
    private void StartUp()
    {
        var state = _engine.State;
        _log.Write($"siteblockd {BuildInfo.VersionWithBuild} starting ({(_paths.IsSandbox ? "sandbox" : "production")}, tick {_tickInterval.TotalSeconds:0.###}s, blocked sites: {state.Blocked.Count}, path rules: {state.BlockedPaths?.Count ?? 0})");

        // Before anything is saved or enforced: a second copy (a live service already answers on the pipe) exits with code 1 and leaves the hosts file, the state and the pipe alone.
        var server = new PipeServer(_paths.PipeName, _paths.IsSandbox, HandleAsync, _rejections.Record, _log);
        try
        {
            server.CheckAvailable();
        }
        catch (PipeServerException error)
        {
            _log.Write($"cannot start the pipe server: {error.Message}");
            _exit.TrySetResult(1);
            return;
        }
        if (!_loadedState) _log.Write("no saved state found; starting fresh");

        // A cleared tampered flag is reported and written back to both state files at once, so the bad value does not linger on disk.
        if (_ignoredUninstallFlag)
        {
            _log.Write("ignored uninstalling flag without a finished uninstall countdown");
            SaveState();
        }

        // Startup step 3: an uninstall that was interrupted (for example by a crash) is finished instead of starting normal service.
        if (state.HasFinishedUninstall)
        {
            _log.Write("state says an uninstall was in progress; finishing it");
            BeginUninstall();
            return;
        }

        // Startup step 4: the engine tells the runtime when the uninstall countdown ends.
        _engine.OnUninstall = BeginUninstall;

        // Startup step 5: enforce at once, so blocks apply at boot before any client connects. This pass is not caused by a command, so tampering that happened while the service was stopped is logged.
        _engine.SetHostsHealthy(EnforceBlocks(causedByCommand: false));
        // The adult content filter is on from the moment the service starts, even before a password exists. The first reachability check starts on its own thread; until it answers, the DNS settings are left as they are.
        _services.Dns.StartMonitoring(QueueDnsPass);
        // If the state came from the backup, or the backup does not exist yet, write both files now.
        if (!_store.MatchesLastSave() && SaveState()) _log.Write("state file repaired");

        // Startup step 6, on Windows taken before the pipe: the tick timer. Its callback only queues a tick, so every tick runs on the engine thread. The timers start before the pipe,
        // so blocks are enforced and repaired even while the pipe cannot be created.
        _lastTick = Environment.TickCount64;
        _lastSave = _lastTick;
        _tickTimer = new Timer(_ => QueueTick(), null, _tickInterval, _tickInterval);

        // The guard timer keeps the watchdog service running (production), the folders' access lists right and the tray app in place. It runs on the thread pool, never on the engine thread, so a slow service call cannot delay ticks or commands.
        _guardTimer = new Timer(_ => GuardPass(), null, TimeSpan.FromSeconds(1), GuardInterval);

        // Startup step 7: open the pipe (whether another service answers was checked first thing).
        _rejections.Start();
        TryStartServer(server);
    }

    /// <summary>
    /// Opens the pipe. When it cannot be created (for example another program created a pipe of the same name while the service was restarting), the service keeps enforcing and tries
    /// again every 5 seconds instead of exiting, because exiting would leave the blocks without their tick and the restart would meet the same pipe. Runs on the engine thread.
    /// </summary>
    private void TryStartServer(PipeServer server)
    {
        if (IsUninstalling || _exit.Task.IsCompleted) return;
        try
        {
            server.Start();
        }
        catch (PipeServerException error)
        {
            if (!_pipeRetrying) _log.Write($"cannot start the pipe server: {error.Message}; trying again every 5 seconds");
            _pipeRetrying = true;
            _pipeRetryTimer?.Dispose();
            _pipeRetryTimer = new Timer(_ => _thread.Post(() => TryStartServer(server)), null, PipeRetryInterval, Timeout.InfiniteTimeSpan);
            return;
        }
        _server = server;
        _pipeRetrying = false;
        _log.Write($"siteblockd ready; pipe {(_paths.IsSandbox ? _paths.PipeName : @"\\.\pipe\" + _paths.PipeName)}");
    }

    /// <summary>Queues one DNS pass on the engine thread unless one is already waiting there, so a burst of change notices (or a fast sandbox timer) never builds a backlog.</summary>
    private void QueueDnsPass()
    {
        if (Interlocked.Exchange(ref _dnsQueued, 1) == 1) return;
        if (!_thread.Post(() => { Volatile.Write(ref _dnsQueued, 0); EnforceDns(); })) Volatile.Write(ref _dnsQueued, 0);
    }

    /// <summary>Queues one tick on the engine thread unless one is already waiting there.</summary>
    private void QueueTick()
    {
        if (Interlocked.Exchange(ref _tickQueued, 1) == 1) return;
        if (!_thread.Post(() => { Volatile.Write(ref _tickQueued, 0); Tick(); })) Volatile.Write(ref _tickQueued, 0);
    }

    /// <summary>
    /// One guard pass, every 5 seconds: in production make sure the watchdog service is installed and running, then check the folders' access lists and the tray app.
    /// Each step is guarded on its own, so a failure in one never skips the others. Does nothing once an uninstall has begun.
    /// </summary>
    private void GuardPass()
    {
        // A pass still running when the timer fires again is not doubled up.
        if (!Monitor.TryEnter(_guardLock)) return;
        try
        {
            if (IsUninstalling) return;
            // The watchdog check goes first because it is the quick and critical one; a slow app copy must not delay it.
            Guarded("watchdog guard", () => _services.ServiceGuard?.EnsureRunning(ServiceJob.Watchdog));
            Guarded("folder access guard", () => _services.AclGuard?.Ensure());
            Guarded("tray app guard", _services.AppGuard.Check);
        }
        finally
        {
            Monitor.Exit(_guardLock);
        }
    }

    /// <summary>Runs one guard step and logs (by exception type only) when it throws, so one broken guard never stops the others or the service.</summary>
    private void Guarded(string what, Action step)
    {
        try { step(); }
        catch (Exception error) { _log.Write($"{what} failed: {error.GetType().Name}"); }
    }

    // MARK: Commands

    /// <summary>
    /// Called on a pipe connection's thread. It first checks any site name or rule in the request there and rejects an invalid one at once, then runs the request on the engine thread.
    /// Rejecting on the connection's thread means a flood of bad names never queues behind, or in front of, real commands and ticks.
    /// </summary>
    internal Task<Response> HandleAsync(Request request, Peer peer)
    {
        // A request that is also missing a required argument (the password for an unblock; the password or the window for a temporary unblock) is left to the engine, which answers badRequest first, the same as for any other missing argument.
        bool usesDomain = request.Command is Command.Add or Command.Unblock or Command.CancelUnblock or Command.TemporaryUnblock;
        bool usesRule = request.Command is Command.AddPath or Command.UnblockPath or Command.CancelUnblockPath or Command.TemporaryUnblockPath;
        bool missingArgument = request.Command switch
        {
            Command.Unblock or Command.UnblockPath => request.Password is null,
            Command.TemporaryUnblock or Command.TemporaryUnblockPath => request.Password is null || request.Seconds is null,
            _ => false,
        };
        if (usesDomain && !missingArgument && request.Domain is string domain)
        {
            try { DomainNormalizer.Normalize(domain); }
            catch (DomainException error)
            {
                _rejections.Record(peer);
                return Task.FromResult(Response.Failure(ErrorCode.InvalidDomain, error.Message));
            }
        }
        if (usesRule && !missingArgument && request.Domain is string rule)
        {
            try { PathRuleParser.Parse(rule); }
            catch (PathRuleException error)
            {
                _rejections.Record(peer);
                return Task.FromResult(Response.Failure(ErrorCode.InvalidPath, error.Message));
            }
            catch (DomainException error)
            {
                _rejections.Record(peer);
                return Task.FromResult(Response.Failure(ErrorCode.InvalidDomain, error.Message));
            }
        }
        // The engine gets the original text and normalizes it once itself; passing the normalized name would strip a second "www." from "www.www.example.com".
        return _thread.InvokeAsync(() => Process(request, peer));
    }

    /// <summary>True when the command really compared a password, whatever the outcome. A changePassword refused only because the new password is too weak did compare the old one, and it was right.</summary>
    private static bool ComparedPassword(Command command, Response response)
    {
        if (!PasswordCommands.Contains(command)) return false;
        return response.Ok || response.ErrorCode == ErrorCode.WrongPassword || (command == Command.ChangePassword && response.ErrorCode == ErrorCode.WeakPassword);
    }

    /// <summary>
    /// Writes the log line for one finished command. Status polling is never logged, because the tray app asks once a second. A successful command and every password check get one line each
    /// with the command name, the caller's SID and the outcome; any other refused command is only counted. Passwords, domains and path rules are never written.
    /// </summary>
    private void LogOutcome(Command command, Response response, Peer peer)
    {
        if (command == Command.Status) return;
        if (response.Ok || ComparedPassword(command, response))
        {
            string outcome = response.Ok ? "ok" : $"failed ({response.ErrorCode?.WireName() ?? "unknown"})";
            _log.Write($"command {command.WireName()} from user {peer.UserId}: {outcome}");
        }
        else
        {
            _rejections.Record(peer);
        }
    }

    /// <summary>
    /// Runs one command on the engine thread: bring every countdown up to date with the clock, apply the command, save the state if it changed, enforce, and build the reply
    /// from the state as it is after enforcement, so a block is in the hosts file before the reply is sent.
    /// </summary>
    private Response Process(Request request, Peer peer)
    {
        // The countdowns are brought up to date first; otherwise a countdown this command starts would be charged, at the next tick, for time that passed before it existed.
        CatchUpCountdowns();
        // After the uninstall has begun, nothing may change the block list or touch the hosts file again. A status request is read-only and still answered, from memory, with no save and no enforcement pass.
        if (IsUninstalling)
        {
            if (request.Command != Command.Status)
            {
                _rejections.Record(peer);
                return Response.Failure(ErrorCode.Internal, "SiteBlock is uninstalling and is not accepting commands.");
            }
            return _engine.Handle(request, peer);
        }

        var stateBefore = _engine.State;
        var listsBefore = CurrentBlockLists();
        var response = _engine.Handle(request, peer);
        // A refused command can change state too (the wrong-password count, a lockout), so every outcome is compared. A read-only command writes nothing.
        if (!_engine.State.Equals(stateBefore)) SaveState();
        // The handler may have started the uninstall (an uninstall countdown that finished inside the command); then nothing else may happen.
        if (IsUninstalling) return response;

        // Enforce after every command, even a read-only one: the pass only reads when nothing is wrong, and it makes the reported health current.
        bool healthy = EnforceBlocks(causedByCommand: !SameLists(CurrentBlockLists(), listsBefore));
        _engine.SetHostsHealthy(healthy);
        // The app asks for status once a second, so status skips the DNS pass; every other command runs it. The pass reads the stored reachability result and sends no query.
        if (request.Command != Command.Status) EnforceDns();

        LogOutcome(request.Command, response, peer);
        // Rebuild the snapshot so hostsFileHealthy reflects the pass that just ran, not the one before it.
        if (response.Status is null) return response;
        return response with { Status = _engine.Snapshot(healthy) };
    }

    // MARK: Enforcement

    /// <summary>Everything SiteBlock writes outside its own files: the hosts to block and the browsers' lists. Two readings that compare equal mean nothing the enforcers write would change.</summary>
    private (List<string> Hosts, BrowserBlockLists Browsers) CurrentBlockLists() => (_engine.HostsToWrite, _engine.BrowserBlockLists);

    /// <summary>True when two block-list readings would make the enforcers write the same thing.</summary>
    private static bool SameLists((List<string> Hosts, BrowserBlockLists Browsers) a, (List<string> Hosts, BrowserBlockLists Browsers) b) =>
        a.Hosts.SequenceEqual(b.Hosts, StringComparer.Ordinal) && a.Browsers.Equals(b.Browsers);

    /// <summary>
    /// Makes the hosts file, then the browsers' registry policy, match the engine's block list and the adult filter. Both always run, so a failure in one never stops the other from being repaired.
    /// Returns true only when both ended correct. <paramref name="causedByCommand"/> is true when the block list was just changed on purpose, so the rewrite is not logged as tampering.
    /// </summary>
    private bool EnforceBlocks(bool causedByCommand)
    {
        bool hostsHealthy = false;
        bool browsersHealthy = false;
        try { hostsHealthy = _services.Hosts.Enforce(_engine.HostsToWrite, causedByCommand); }
        catch (Exception error) { _log.Write($"hosts file pass failed: {error.GetType().Name}"); }
        try { browsersHealthy = _services.Browsers.Enforce(_engine.BrowserBlockLists, _engine.AdultFilterActive, causedByCommand); }
        catch (Exception error) { _log.Write($"browser policy pass failed: {error.GetType().Name}"); }
        return hostsHealthy && browsersHealthy;
    }

    /// <summary>
    /// Runs one DNS pass on the engine thread from the latest stored reachability result. The originals are recorded in the state first (the enforcer calls back before it changes anything), so the uninstaller can put them back.
    /// Does nothing once an uninstall has begun, because the uninstaller restores the servers itself.
    /// </summary>
    private void EnforceDns()
    {
        if (IsUninstalling) return;
        try
        {
            var savedBefore = _engine.State.SavedDNS;
            _services.Dns.Enforce(_engine.AdultFilterActive, savedBefore, saved =>
            {
                _engine.SetSavedDNS(saved);
                if (SaveState()) return true;
                // The new record never reached the disk, so memory goes back to what the disk holds; otherwise the next pass would think the originals were saved and overwrite them.
                _engine.SetSavedDNS(savedBefore);
                return false;
            });
        }
        catch (Exception error)
        {
            _log.Write($"DNS pass failed: {error.GetType().Name}");
        }
    }

    // MARK: Tick

    /// <summary>True when any countdown is running (a temporary unblock counts while it waits and while it is open), which means the state must be saved regularly.</summary>
    private bool AnyCountdownRunning()
    {
        var state = _engine.State;
        return state.Blocked.Any(site => site.PendingUnblock is not null || site.TemporaryUnblock is not null)
            || (state.BlockedPaths ?? []).Any(rule => rule.PendingUnblock is not null || rule.TemporaryUnblock is not null)
            || state.PendingDelayChange is not null || state.PendingUninstall is not null || state.Recovery is not null || state.Lockout is not null;
    }

    /// <summary>
    /// Advances every countdown by the time since the last tick or command and moves that time to now. The elapsed time comes from TickCount64, clamped to 0 through 7 days.
    /// Returns true when the state changed and must be saved, as <see cref="Engine.Tick"/> does.
    /// </summary>
    private bool AdvanceCountdowns(long now)
    {
        double elapsed = Math.Clamp((now - _lastTick) / 1000.0, 0, MaxElapsedPerTick);
        _lastTick = now;
        return _engine.Tick(elapsed);
    }

    /// <summary>
    /// Runs at the start of every command: advances every countdown and applies whatever finished the way a tick would, saving the state and enforcing, so a site whose wait just ended
    /// is already out of the hosts file (and a site whose window just ended is already back in it) when the command runs. Does nothing once an uninstall has begun.
    /// </summary>
    private void CatchUpCountdowns()
    {
        if (IsUninstalling) return;
        var listsBefore = CurrentBlockLists();
        bool changed = AdvanceCountdowns(Environment.TickCount64);
        // A countdown that ended inside the engine's tick may have started the uninstall; nothing else may happen then.
        if (IsUninstalling || !changed) return;
        SaveState();
        _engine.SetHostsHealthy(EnforceBlocks(causedByCommand: !SameLists(CurrentBlockLists(), listsBefore)));
    }

    /// <summary>One timer tick: advance the countdowns, enforce the hosts file and the browser policy, undo hand edits to the state files, and save the state when needed.</summary>
    private void Tick()
    {
        if (IsUninstalling) return;
        long now = Environment.TickCount64;
        var listsBefore = CurrentBlockLists();
        bool changed = AdvanceCountdowns(now);
        // When the uninstall countdown ended inside the engine's tick, the uninstall has already run; nothing else may happen.
        if (IsUninstalling) return;

        // A finished countdown, or a temporary unblock that opened or ended, changes the block list on purpose, so that rewrite is not tampering. It happens in this same tick.
        _engine.SetHostsHealthy(EnforceBlocks(causedByCommand: !SameLists(CurrentBlockLists(), listsBefore)));

        // The state files must hold exactly what was last written. This is checked before any routine save, so a hand edit is logged rather than silently overwritten.
        bool filesTampered = !_store.MatchesLastSave();
        bool mayRepair = _lastFailedRepair is not long failedAt || now - failedAt >= RepairRetryMs;
        if (filesTampered && mayRepair)
        {
            // While the service runs, its memory is the source of truth, so the files are rewritten from it.
            if (SaveState())
            {
                _lastFailedRepair = null;
                _log.Write("state file repaired");
            }
            else
            {
                _lastFailedRepair = now;
            }
        }
        else if (changed || (AnyCountdownRunning() && now - _lastSave >= _policy.SaveIntervalSeconds * 1000))
        {
            // While any countdown runs the state is saved every SaveIntervalSeconds (15 in production), so a crash loses at most that much progress.
            SaveState();
        }
    }

    /// <summary>Writes the engine's state to both state files. Returns false (after logging why) when it fails; the service keeps running on its in-memory state.</summary>
    private bool SaveState()
    {
        try
        {
            _store.Save(_engine.State);
            _lastSave = Environment.TickCount64;
            return true;
        }
        catch (Exception error) when (error is StateStoreException or IOException or UnauthorizedAccessException)
        {
            _log.Write($"could not save state: {error.Message}");
            return false;
        }
    }

    // MARK: Uninstall

    /// <summary>Stops the timers, the DNS watching, the pipe and the rejected-request timer. Safe to call more than once.</summary>
    private void StopEverything()
    {
        _tickTimer?.Dispose();
        _tickTimer = null;
        _guardTimer?.Dispose();
        _guardTimer = null;
        _pipeRetryTimer?.Dispose();
        _pipeRetryTimer = null;
        try { _services.Dns.StopMonitoring(); } catch (Exception error) { _log.Write($"stopping the DNS watch failed: {error.GetType().Name}"); }
        _server?.Stop();
        _rejections.Stop();
        _rejections.Flush();
    }

    /// <summary>
    /// Starts the uninstall on the engine thread: stops everything that could rewrite the hosts file or restore a file, waits for a guard pass already in progress, then runs the uninstaller.
    /// A sandbox uninstall, and a failure, make <see cref="Run"/> return; in production the service waits for the cleanup step to stop it, and exits on its own after 2 minutes so the uninstall is retried.
    /// </summary>
    private void BeginUninstall()
    {
        if (Interlocked.Exchange(ref _uninstallStarted, 1) == 1) return;
        _log.Write("uninstall starting");
        StopEverything();
        // Wait for a guard pass that is already running, so it cannot restart the watchdog or restore the app after the uninstaller has removed them. The wait is capped at 30 seconds;
        // the guards also check the uninstall flag themselves, so a pass still running after that stops at its next step.
        if (Monitor.TryEnter(_guardLock, TimeSpan.FromSeconds(30))) Monitor.Exit(_guardLock);
        else _log.Write("uninstall: a guard pass was still running after 30 seconds; going ahead");

        var outcome = Uninstaller.Run(_paths, _services, _engine.State.SavedDNS, SaveUninstallingState, _log);
        switch (outcome)
        {
            case UninstallOutcome.Finished:
                _exit.TrySetResult(0);
                break;
            case UninstallOutcome.Failed:
                _exit.TrySetResult(1);
                break;
            case UninstallOutcome.WaitForStop:
                _log.Write("waiting for the cleanup step to stop the service");
                _ = Task.Delay(UninstallGiveUp).ContinueWith(_ =>
                {
                    _log.Write("the service was not stopped in time; exiting so the uninstall is retried");
                    _exit.TrySetResult(0);
                }, TaskScheduler.Default);
                break;
        }
    }

    /// <summary>Saves the engine's state with `uninstalling` set. Returns false when the save fails, so the uninstaller stops before touching anything.</summary>
    private bool SaveUninstallingState()
    {
        var state = _engine.State;
        state.Uninstalling = true;
        try
        {
            _store.Save(state);
            return true;
        }
        catch (Exception error) when (error is StateStoreException or IOException or UnauthorizedAccessException)
        {
            _log.Write($"could not save the uninstall marker: {error.Message}");
            return false;
        }
    }
}

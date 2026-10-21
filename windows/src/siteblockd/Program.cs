using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.ServiceProcess;
using SiteBlock.Core;
using SiteBlock.Service;

namespace SiteBlock.Daemon;

/// <summary>What the program was asked to do.</summary>
internal enum Mode
{
    /// Run the main service (the block list and its enforcement).
    Daemon,
    /// Run the watchdog loop that keeps the main service installed and running.
    Watchdog,
    /// Print the version and exit.
    Version,
    /// Print the read-only DNS report and exit.
    PrintDnsPlan,
}

/// <summary>The parsed command line.</summary>
internal sealed class Options
{
    /// The one mode flag that was given.
    public Mode? Mode { get; set; }
    /// The sandbox folder, made absolute, or null for the real installation.
    public string? SandboxRoot { get; set; }
    /// The tick interval in seconds, or null for the default of 2.
    public double? TickSeconds { get; set; }
    /// True for the short test policy (sandbox only).
    public bool PolicyFast { get; set; }
}

/// <summary>Thrown by the flag parser for a command-line mistake; the entry point prints it with the usage text and exits with code 64.</summary>
internal sealed class UsageException(string? message) : Exception(message);

/// <summary>
/// Entry point of siteblockd.exe (06-windows.md § Flags): reads the flags and runs the daemon or the watchdog, either under the Windows service control manager or as a plain
/// console process (sandbox runs and tests), or prints something and exits.
/// </summary>
internal static class Program
{
    /// <summary>The usage text printed after a command-line mistake.</summary>
    internal const string UsageText =
        "usage: siteblockd --daemon [--sandbox <dir> [--tick <seconds>] [--policy-fast]]\n" +
        "       siteblockd --watchdog\n" +
        "       siteblockd --version\n" +
        "       siteblockd --print-dns-plan [--sandbox <dir>]\n";

    /// <summary>Runs the program and returns its exit code: 0 success, 1 failure, 64 a command-line mistake, 77 not allowed to run as this account.</summary>
    private static int Main(string[] args)
    {
        Options options;
        try
        {
            options = Parse(args, Environment.IsPrivilegedProcess);
        }
        catch (UsageException error)
        {
            if (error.Message.Length > 0) Console.Error.WriteLine($"siteblockd: {error.Message}");
            Console.Error.Write(UsageText);
            return 64;
        }

        var paths = options.SandboxRoot is string root ? Paths.Sandbox(root) : Paths.Production;
        switch (options.Mode!.Value)
        {
            case Mode.Version:
                // The build scripts read both numbers from this line: "siteblockd 1.0.3 (build 51)".
                Console.WriteLine($"siteblockd {BuildInfo.VersionWithBuild}");
                return 0;
            case Mode.PrintDnsPlan:
                // A read-only diagnostic that needs no administrator rights.
                try
                {
                    Console.Write(DnsPlan.Text(paths));
                    return 0;
                }
                catch (IOException error)
                {
                    Console.Error.WriteLine($"siteblockd: cannot read the network settings: {error.Message}");
                    return 1;
                }
            case Mode.Watchdog:
                // The installed services run as SYSTEM; anything else would only fail halfway, so it is refused with 77 (the Unix code for "permission denied").
                if (!Environment.IsPrivilegedProcess)
                {
                    Console.Error.WriteLine("siteblockd: the watchdog must run as an administrator or as SYSTEM");
                    return 77;
                }
                return RunWatchdog(paths);
            default:
                if (options.SandboxRoot is null && !Environment.IsPrivilegedProcess)
                {
                    Console.Error.WriteLine("siteblockd: the installed service must run as an administrator or as SYSTEM (use --sandbox <dir> for a test run)");
                    return 77;
                }
                var policy = options.PolicyFast ? Policy.FastForTests : Policy.Production;
                return RunDaemon(paths, policy, TimeSpan.FromSeconds(options.TickSeconds ?? 2));
        }
    }

    /// <summary>
    /// Reads the flags by hand. Any unknown flag, repeated flag, missing value or forbidden combination throws <see cref="UsageException"/>, and so does --sandbox when the process runs
    /// as SYSTEM or elevated (<paramref name="privileged"/>), because a sandbox pointed at the real hosts folder would fight the installed service.
    /// </summary>
    internal static Options Parse(IReadOnlyList<string> arguments, bool privileged)
    {
        var options = new Options();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int index = 0;
        // Returns the value after a flag, or throws when it is missing or looks like another flag.
        string Value(string flag)
        {
            index++;
            if (index >= arguments.Count || arguments[index].StartsWith("--", StringComparison.Ordinal)) throw new UsageException($"{flag} needs a value");
            return arguments[index];
        }
        // Records a mode flag; exactly one is allowed.
        void SetMode(Mode mode)
        {
            if (options.Mode is not null) throw new UsageException("only one of --daemon, --watchdog, --version and --print-dns-plan may be given");
            options.Mode = mode;
        }
        while (index < arguments.Count)
        {
            string flag = arguments[index];
            if (!seen.Add(flag)) throw new UsageException($"{flag} was given more than once");
            switch (flag)
            {
                case "--daemon": SetMode(Mode.Daemon); break;
                case "--watchdog": SetMode(Mode.Watchdog); break;
                case "--version": SetMode(Mode.Version); break;
                case "--print-dns-plan": SetMode(Mode.PrintDnsPlan); break;
                case "--sandbox":
                    // A relative folder would resolve differently for the service and for clients started elsewhere, so it is made absolute here.
                    options.SandboxRoot = Path.GetFullPath(Value(flag));
                    break;
                case "--tick":
                    string text = Value(flag);
                    if (!double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double seconds) || !double.IsFinite(seconds) || seconds <= 0)
                    {
                        throw new UsageException("--tick needs a positive number of seconds");
                    }
                    options.TickSeconds = seconds;
                    break;
                case "--policy-fast": options.PolicyFast = true; break;
                default: throw new UsageException($"unknown option {flag}");
            }
            index++;
        }
        if (options.Mode is null) throw new UsageException("one of --daemon, --watchdog, --version or --print-dns-plan is required");
        // Short waits and fast ticks are only for sandbox runs, so the installed service can never be started with them.
        if (options.SandboxRoot is null && options.TickSeconds is not null) throw new UsageException("--tick is only accepted together with --sandbox");
        if (options.SandboxRoot is null && options.PolicyFast) throw new UsageException("--policy-fast is only accepted together with --sandbox");
        // The watchdog's whole job is to manage services, which a sandbox forbids, so the combination is refused instead of silently doing nothing.
        if (options.Mode == Mode.Watchdog && options.SandboxRoot is not null) throw new UsageException("--watchdog cannot be combined with --sandbox");
        if (options.SandboxRoot is string root)
        {
            // A sandbox must never touch the real installation, or it would fight the installed service over the real hosts file. On Windows that is ruled out by the folder
            // (elevated runs are allowed, because test machines such as GitHub's run everything elevated); on macOS and Linux root is refused, as the Mac does.
            if (OperatingSystem.IsWindows())
            {
                if (ProtectedFolderFor(root, ProtectedFolders()) is string folder) throw new UsageException($"--sandbox cannot use a folder that is, contains or is inside {folder}");
            }
            else if (privileged)
            {
                throw new UsageException("--sandbox cannot be used while running as root");
            }
        }
        return options;
    }

    /// <summary>The real folders a sandbox may not overlap: the hosts file's folder, the program folder and the data folder.</summary>
    internal static IReadOnlyList<string> ProtectedFolders()
    {
        var production = Paths.Production;
        return [Path.GetDirectoryName(production.HostsFile)!, production.ProgramDir, production.DataDir];
    }

    /// <summary>
    /// The first protected folder that the sandbox folder is equal to, lies inside, or contains, or null when it overlaps none. Paths are compared without regard to letter case
    /// and a trailing separator, as Windows does.
    /// </summary>
    internal static string? ProtectedFolderFor(string sandboxRoot, IReadOnlyList<string> protectedFolders)
    {
        // Full path, without the \\?\ prefix (which names the same folder), always ending in exactly one separator, so a drive root such as C:\ stays C:\ and contains everything on it.
        static string Normalize(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal) && !path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = path[4..];
            string full = Path.GetFullPath(path);
            return Path.EndsInDirectorySeparator(full) ? full : full + Path.DirectorySeparatorChar;
        }
        string root = Normalize(sandboxRoot);
        foreach (string folder in protectedFolders)
        {
            string guarded = Normalize(folder);
            if (root.StartsWith(guarded, StringComparison.OrdinalIgnoreCase) || guarded.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return folder;
        }
        return null;
    }

    /// <summary>Runs the daemon: under the service control manager when Windows started it as the SiteBlock service, otherwise in the console until Ctrl+C or a stop.</summary>
    private static int RunDaemon(Paths paths, Policy policy, TimeSpan tick)
    {
        var log = new Log(paths.DaemonLog);
        DaemonRuntime runtime;
        try
        {
            runtime = new DaemonRuntime(paths, policy, tick, log);
        }
        catch (Exception error)
        {
            // Without this line a failure here would end the process with nothing in siteblockd.log; the service's recovery action restarts it.
            log.Write($"cannot start: {error.GetType().Name}: {error.Message}");
            return 1;
        }
        if (OperatingSystem.IsWindows() && StartedByServiceManager())
        {
            ServiceBase.Run(new DaemonService(runtime));
            return 0;
        }
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            // The runtime saves and exits on its own thread; the process must not be killed before it has.
            eventArgs.Cancel = true;
            runtime.RequestStop("received Ctrl+C");
        };
        // A polite stop signal (SIGTERM, which test harnesses and macOS send) cancels the default "terminate now" and instead asks the runtime to save and return, so Run ends normally.
        // A system that does not offer the signal leaves Ctrl+C as the only polite stop.
        PosixSignalRegistration? termination = null;
        try
        {
            termination = PosixSignalRegistration.Create(PosixSignal.SIGTERM, context =>
            {
                context.Cancel = true;
                runtime.RequestStop("received a stop signal");
            });
        }
        catch (PlatformNotSupportedException)
        {
        }
        using (termination) return runtime.Run();
    }

    /// <summary>Runs the watchdog loop: as the SiteBlockWatchdog service when Windows started it, otherwise in the console until Ctrl+C.</summary>
    private static int RunWatchdog(Paths paths)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("siteblockd: the watchdog runs only on Windows");
            return 1;
        }
        var log = new Log(paths.WatchdogLog);
        var guard = new ServiceGuard(paths, log, new ScServiceControl());
        if (StartedByServiceManager())
        {
            ServiceBase.Run(new WatchdogService(paths, guard, log));
            return 0;
        }
        using var stop = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            stop.Cancel();
        };
        Watchdog.RunLoop(paths, guard, log, stop.Token);
        return 0;
    }

    /// <summary>
    /// True when the service control manager started this process: its parent is services.exe and it runs in session 0, where services live.
    /// A terminal run, even one with no desktop such as a remote shell, has some other parent.
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static bool StartedByServiceManager()
    {
        try
        {
            using var self = Process.GetCurrentProcess();
            if (self.SessionId != 0) return false;
            var info = new ProcessBasicInformation();
            if (NtQueryInformationProcess(self.Handle, 0, ref info, Marshal.SizeOf<ProcessBasicInformation>(), out _) != 0) return false;
            using var parent = Process.GetProcessById((int)info.InheritedFromUniqueProcessId);
            return string.Equals(parent.ProcessName, "services", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    /// <summary>PROCESS_BASIC_INFORMATION from winternl.h; only the parent's process ID is read.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref ProcessBasicInformation information, int length, out int returnLength);
}

/// <summary>
/// The SiteBlock service as the service control manager sees it. Start runs the daemon runtime on its own thread; a stop request saves the state and waits for the runtime to finish.
/// When the runtime ends by itself (a fatal error, or an uninstall that was not finished in time) the process exits without reporting a stop, which Windows treats as a failure
/// and answers with the recovery action: a restart 5 seconds later.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class DaemonService : ServiceBase
{
    // How long a stop request may take before the service reports itself stopped anyway.
    private static readonly TimeSpan StopTimeout = TimeSpan.FromSeconds(20);

    private readonly DaemonRuntime _runtime;
    private Thread? _thread;
    private volatile bool _stopping;

    /// <summary>Creates the service around a runtime that has not started yet.</summary>
    public DaemonService(DaemonRuntime runtime)
    {
        _runtime = runtime;
        ServiceName = ServiceNames.Daemon;
        CanStop = true;
        CanShutdown = true;
    }

    /// <summary>Starts the runtime on a thread of its own, so the service control manager hears back at once.</summary>
    protected override void OnStart(string[] args)
    {
        _thread = new Thread(() =>
        {
            int code = _runtime.Run();
            // Exiting without reporting a stop is what makes Windows run the recovery action, whatever the code.
            if (!_stopping) Environment.Exit(code);
        }) { Name = "siteblockd.runtime", IsBackground = true };
        _thread.Start();
    }

    /// <summary>Saves the state and stops the runtime, waiting up to 20 seconds.</summary>
    protected override void OnStop()
    {
        _stopping = true;
        _runtime.RequestStop("received a stop request from the service control manager");
        _thread?.Join(StopTimeout);
    }

    /// <summary>Treats Windows shutting down like a stop request.</summary>
    protected override void OnShutdown() => OnStop();
}

/// <summary>The SiteBlockWatchdog service as the service control manager sees it: the watchdog loop on its own thread, stopped by a cancellation.</summary>
[SupportedOSPlatform("windows")]
internal sealed class WatchdogService : ServiceBase
{
    private readonly Paths _paths;
    private readonly IServiceGuard _guard;
    private readonly Log _log;
    private readonly CancellationTokenSource _stop = new();
    private Thread? _thread;

    /// <summary>Creates the service around the guard it calls every 5 seconds.</summary>
    public WatchdogService(Paths paths, IServiceGuard guard, Log log)
    {
        _paths = paths;
        _guard = guard;
        _log = log;
        ServiceName = ServiceNames.Watchdog;
        CanStop = true;
        CanShutdown = true;
    }

    /// <summary>Starts the loop on its own thread.</summary>
    protected override void OnStart(string[] args)
    {
        _thread = new Thread(() => Watchdog.RunLoop(_paths, _guard, _log, _stop.Token)) { Name = "siteblockd.watchdog", IsBackground = true };
        _thread.Start();
    }

    /// <summary>Stops the loop and waits for it.</summary>
    protected override void OnStop()
    {
        _stop.Cancel();
        _thread?.Join(TimeSpan.FromSeconds(10));
        _log.Write("watchdog stopped");
    }

    /// <summary>Treats Windows shutting down like a stop request.</summary>
    protected override void OnShutdown() => OnStop();
}

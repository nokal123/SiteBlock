using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>The two Windows services SiteBlock runs.</summary>
public enum ServiceJob
{
    /// The main service, `siteblockd.exe --daemon`, which owns the block list.
    Daemon,
    /// The watchdog, `siteblockd.exe --watchdog`, which keeps the main service installed and running.
    Watchdog,
}

/// <summary>The fixed names of the two services and the tray app's start-at-sign-in entry.</summary>
public static class ServiceNames
{
    /// The main service's name.
    public const string Daemon = "SiteBlock";
    /// The main service's display name.
    public const string DaemonDisplay = "SiteBlock";
    /// The watchdog's name.
    public const string Watchdog = "SiteBlockWatchdog";
    /// The watchdog's display name.
    public const string WatchdogDisplay = "SiteBlock Watchdog";
    /// The name of the value under HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run that starts the tray app at sign-in.
    public const string RunValue = "SiteBlock";
    /// The tray app's process name (its file name without ".exe").
    public const string AppProcess = "SiteBlockApp";

    /// The service name of a job.
    public static string Name(ServiceJob job) => job == ServiceJob.Daemon ? Daemon : Watchdog;
    /// The command-line flag the job's service runs siteblockd.exe with.
    public static string Flag(ServiceJob job) => job == ServiceJob.Daemon ? "--daemon" : "--watchdog";
}

/// <summary>Makes the hosts file hold exactly SiteBlock's section for the given names (see 06-windows.md § HostsEnforcer).</summary>
public interface IHostsEnforcer
{
    /// Runs one pass and returns true when the file is correct afterwards. `causedByCommand` stops the pass from logging an intended change as tampering.
    bool Enforce(IReadOnlyList<string> hosts, bool causedByCommand);
}

/// <summary>Keeps every browser's registry policy equal to the wanted one (see 06-windows.md § BrowserPolicyEnforcer).</summary>
public interface IBrowserPolicyEnforcer
{
    /// Runs one pass for all four browsers and returns true when every write succeeded. With `adultFilter` false and empty lists (the uninstaller's call) every value and list SiteBlock owns is removed.
    bool Enforce(BrowserBlockLists lists, bool adultFilter, bool causedByCommand);
}

/// <summary>Keeps every network adapter's DNS servers on Cloudflare for Families (see 06-windows.md § DNSEnforcer).</summary>
public interface IDnsEnforcer
{
    /// Runs one pass and returns the saved-servers map the state should hold afterwards. Before changing any adapter for the first time it calls `persist` with the new map, and changes nothing when `persist` returns false (the save failed), so the originals are always on disk before they are overwritten.
    Dictionary<string, List<string>>? Enforce(bool adultFilterActive, IReadOnlyDictionary<string, List<string>>? savedDNS, Func<Dictionary<string, List<string>>?, bool> persist);

    /// Starts watching for network changes, registry edits of the DNS settings and changes in the family servers' reachability. `schedulePass` may be called from any thread; the runtime runs the pass on its engine thread.
    void StartMonitoring(Action schedulePass);

    /// Stops all watching (called when an uninstall begins and at shutdown).
    void StopMonitoring();
}

/// <summary>Keeps both services installed, set to start automatically and running (see 06-windows.md § ServiceGuard).</summary>
public interface IServiceGuard
{
    /// Repairs and starts the job's service when it is missing, disabled, misconfigured or stopped, and restores its program from the backup.
    void EnsureRunning(ServiceJob job);

    /// Stops the job's service (waiting at most `timeout`) and deletes it. Returns true when it is gone. Used by the uninstaller.
    bool StopAndDelete(ServiceJob job, TimeSpan timeout);
}

/// <summary>Keeps the tray app installed, starting at sign-in and running for the person at the screen (see 06-windows.md § AppGuard).</summary>
public interface IAppGuard
{
    /// Runs one check: restores the app from the backup when needed, repairs the start-at-sign-in entry and (in production) starts the app in the console session when it is not running.
    void Check();

    /// Stops every running tray app and removes its start-at-sign-in entry. Used by the uninstaller.
    void StopAppsAndRemoveStartEntry();
}

/// <summary>Keeps the access lists of SiteBlock's data folders as the design says (see 06-windows.md § Installed Paths and Permissions).</summary>
public interface IAclGuard
{
    /// Creates the folders when missing and puts their access lists back when they differ. Does nothing in sandbox mode on systems without access lists.
    void Ensure();
}

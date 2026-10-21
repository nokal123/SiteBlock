using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// Every file, folder and name the service uses. <see cref="Production"/> points at the real Windows locations;
/// <see cref="Sandbox"/> puts everything under one folder so tests can run the real daemon as an ordinary user.
/// </summary>
public sealed record Paths
{
    /// True for a sandbox run, which never touches the real hosts file, registry, network adapters or services.
    public required bool IsSandbox { get; init; }
    /// The sandbox folder, or null in production.
    public string? SandboxRoot { get; init; }
    /// The hosts file the resolver reads.
    public required string HostsFile { get; init; }
    /// The folder that holds the state file.
    public required string StateDir { get; init; }
    /// The daemon's saved state.
    public required string StateFile { get; init; }
    /// A second copy of the state, in another folder, read when the main file is missing at startup.
    public required string StateBackup { get; init; }
    /// The pipe name clients connect to (a plain name such as "siteblock" in production; see PipeNames for sandboxes).
    public required string PipeName { get; init; }
    /// The folder that holds the logs.
    public required string LogDir { get; init; }
    /// The daemon's log file.
    public required string DaemonLog { get; init; }
    /// The watchdog's log file.
    public required string WatchdogLog { get; init; }
    /// The folder the three programs run from.
    public required string ProgramDir { get; init; }
    /// siteblockd.exe in the program folder.
    public required string DaemonExe { get; init; }
    /// The tray app in the program folder.
    public required string AppExe { get; init; }
    /// The root of SiteBlock's data folder (C:\ProgramData\SiteBlock in production), whose access list the service guards.
    public required string DataDir { get; init; }
    /// The full backup copy of the program folder, restored by the guards when a program file is deleted.
    public required string BackupAppDir { get; init; }
    /// The tray app inside the backup copy.
    public required string BackupAppExe { get; init; }
    /// siteblockd.exe inside the backup copy.
    public required string BackupDaemonExe { get; init; }
    /// Sandbox only: the JSON file that stands in for the registry's browser policy keys.
    public required string RegistryFile { get; init; }
    /// Sandbox only: the JSON file that stands in for the network adapters' DNS settings.
    public required string NetworkServicesFile { get; init; }
    /// Sandbox only: while this file exists the family DNS servers count as unreachable.
    public required string FamilyDnsUnreachableMarker { get; init; }
    /// Sandbox only: a file holding a number of seconds that slows each family DNS check, for tests.
    public required string FamilyDnsProbeDelayFile { get; init; }

    /// The real Windows locations, built from the Program Files and ProgramData folders so they follow the PC's own drive and language.
    public static Paths Production
    {
        get
        {
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var programDir = System.IO.Path.Combine(programFiles, "SiteBlock");
            var dataDir = System.IO.Path.Combine(programData, "SiteBlock");
            var logDir = System.IO.Path.Combine(dataDir, "Logs");
            var stateDir = System.IO.Path.Combine(dataDir, "state");
            var backupDir = System.IO.Path.Combine(dataDir, "backup");
            var backupAppDir = System.IO.Path.Combine(backupDir, "app");
            return new Paths
            {
                IsSandbox = false,
                HostsFile = System.IO.Path.Combine(system, "drivers", "etc", "hosts"),
                StateDir = stateDir,
                StateFile = System.IO.Path.Combine(stateDir, "state.json"),
                StateBackup = System.IO.Path.Combine(backupDir, "state.backup.json"),
                PipeName = PipeNames.Production,
                LogDir = logDir,
                DaemonLog = System.IO.Path.Combine(logDir, "siteblockd.log"),
                WatchdogLog = System.IO.Path.Combine(logDir, "watchdog.log"),
                ProgramDir = programDir,
                DaemonExe = System.IO.Path.Combine(programDir, "siteblockd.exe"),
                AppExe = System.IO.Path.Combine(programDir, "SiteBlockApp.exe"),
                DataDir = dataDir,
                BackupAppDir = backupAppDir,
                BackupAppExe = System.IO.Path.Combine(backupAppDir, "SiteBlockApp.exe"),
                BackupDaemonExe = System.IO.Path.Combine(backupAppDir, "siteblockd.exe"),
                // The sandbox-only files are never read in production; they point inside the data folder so nothing outside it is ever named.
                RegistryFile = System.IO.Path.Combine(dataDir, "unused-registry.json"),
                NetworkServicesFile = System.IO.Path.Combine(dataDir, "unused-network-services.json"),
                FamilyDnsUnreachableMarker = System.IO.Path.Combine(dataDir, "unused-family-dns-unreachable"),
                FamilyDnsProbeDelayFile = System.IO.Path.Combine(dataDir, "unused-family-dns-probe-delay"),
            };
        }
    }

    /// Every location under one sandbox folder, laid out like the Mac's sandbox so tests can read and tamper with each file.
    public static Paths Sandbox(string root)
    {
        root = System.IO.Path.GetFullPath(root);
        string P(params string[] parts) => System.IO.Path.Combine([root, .. parts]);
        return new Paths
        {
            IsSandbox = true,
            SandboxRoot = root,
            HostsFile = P("hosts"),
            StateDir = P("state"),
            StateFile = P("state", "state.json"),
            StateBackup = P("backup", "state.backup.json"),
            PipeName = PipeNames.FromSandboxPath(P("siteblock.pipe")),
            LogDir = P("logs"),
            DaemonLog = P("logs", "siteblockd.log"),
            WatchdogLog = P("logs", "watchdog.log"),
            ProgramDir = P("app"),
            DaemonExe = P("app", "siteblockd.exe"),
            AppExe = P("app", "SiteBlockApp.exe"),
            DataDir = root,
            BackupAppDir = P("backup", "app"),
            BackupAppExe = P("backup", "app", "SiteBlockApp.exe"),
            BackupDaemonExe = P("backup", "app", "siteblockd.exe"),
            RegistryFile = P("registry.json"),
            NetworkServicesFile = P("network-services.json"),
            FamilyDnsUnreachableMarker = P("family-dns-unreachable"),
            FamilyDnsProbeDelayFile = P("family-dns-probe-delay"),
        };
    }
}

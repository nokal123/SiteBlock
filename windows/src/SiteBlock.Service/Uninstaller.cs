using System.Diagnostics;
using System.Runtime.Versioning;
using Microsoft.Win32;
using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>How an uninstall ended, which tells the runtime what to do next.</summary>
public enum UninstallOutcome
{
    /// A sandbox uninstall finished; the process exits with code 0.
    Finished,
    /// The uninstall stopped before deleting anything further; the process exits with code 1 so the service restarts and retries from the saved finished countdown.
    Failed,
    /// Production: the detached cleanup step is running and will stop the service; the process waits for that.
    WaitForStop,
}

/// <summary>Removes SiteBlock from the PC once the uninstall countdown has finished (06-windows.md § Uninstaller).</summary>
public static class Uninstaller
{
    // How long to wait for the watchdog service to stop before deleting it.
    private static readonly TimeSpan WatchdogStopTimeout = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Runs the uninstall steps in order. <paramref name="saveUninstallingState"/> must write the state with `uninstalling` set and return false when the write fails.
    /// In a sandbox, after the hosts section, the browser policy and the DNS servers are put back, it deletes the sandbox's own pipe marker and app stand-ins and returns
    /// <see cref="UninstallOutcome.Finished"/>. In production it stops and deletes the watchdog, stops the tray app, deletes the files that can go while the service runs,
    /// and starts a detached cleanup step that stops and deletes the service and its folders.
    /// </summary>
    public static UninstallOutcome Run(Paths paths, DaemonServices services, IReadOnlyDictionary<string, List<string>>? savedDNS, Func<bool> saveUninstallingState, Log log)
    {
        // Step 1: record that an uninstall is under way before anything is touched, so a crash part-way is finished on the next start. If the save fails nothing has changed yet, so stop here.
        if (!saveUninstallingState())
        {
            log.Write("uninstall stopped: the uninstall marker could not be saved; exiting so it is retried");
            return UninstallOutcome.Failed;
        }

        if (!paths.IsSandbox)
        {
            // Safety check before anything is deleted: the cleanup step deletes two whole folders, so each must be a full path whose last part is "SiteBlock". An empty system folder
            // lookup can then never turn into a relative path or a drive root.
            if (!IsSiteBlockFolder(paths.ProgramDir) || !IsSiteBlockFolder(paths.DataDir))
            {
                log.Write("uninstall stopped: refusing to delete unexpected paths");
                return UninstallOutcome.Failed;
            }
            // Step 2: stop and delete the watchdog before any file is deleted, because a running watchdog would put back what is removed below.
            if (services.ServiceGuard is not { } guard || !guard.StopAndDelete(ServiceJob.Watchdog, WatchdogStopTimeout))
            {
                log.Write("uninstall stopped: the watchdog service could not be stopped and deleted; exiting so it is retried");
                return UninstallOutcome.Failed;
            }
            log.Write("uninstall: watchdog service removed");
        }

        // Step 3: take SiteBlock's lines out of the hosts file, every owned browser policy value and list out of the registry, and put the original DNS servers back.
        // A failure here is logged by the enforcer and does not stop the uninstall: a retry that can never succeed would leave SiteBlock installed for good.
        Attempt(log, "hosts file", () => services.Hosts.Enforce([], causedByCommand: true));
        Attempt(log, "browser policy", () => services.Browsers.Enforce(BrowserBlockLists.Empty, adultFilter: false, causedByCommand: true));
        // The saved record is not cleared on disk: the state folder is deleted a moment later, and a retry after a crash restores the same servers again.
        Attempt(log, "DNS restore", () => services.Dns.Enforce(adultFilterActive: false, savedDNS, _ => true) is null);
        if (!paths.IsSandbox) DnsCache.Flush();

        if (paths.IsSandbox)
        {
            // A sandbox has no services and no installed files, so it only removes its own stand-ins: the pipe marker, the app and the app's backup.
            DeleteFile(Path.Combine(paths.SandboxRoot ?? paths.DataDir, "siteblock.pipe"));
            DeleteFile(paths.AppExe);
            DeleteFolder(paths.BackupAppDir);
            log.Write("uninstall finished (sandbox); exiting");
            return UninstallOutcome.Finished;
        }
        if (!OperatingSystem.IsWindows()) return UninstallOutcome.Failed;

        // Step 4: stop the tray app and remove its start-at-sign-in entry, so it does not keep running after its files are gone.
        Attempt(log, "tray app stop", () => { services.AppGuard.StopAppsAndRemoveStartEntry(); return true; });

        // Step 5: delete what can go while the service still runs: the backup folder (the program copy and the state backup), the program folder's entry in the system PATH and the Start menu shortcut.
        DeleteFolder(Path.GetDirectoryName(paths.BackupAppDir)!);
        DeleteFile(paths.StateBackup);
        Attempt(log, "PATH entry removal", () => OperatingSystem.IsWindows() && RemoveFromSystemPath(paths.ProgramDir));
        DeleteFile(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "SiteBlock.lnk"));

        // Step 6: the service cannot delete its own program or stop itself cleanly, so a detached PowerShell does it after a short wait. A child started by a service keeps running after the service stops.
        if (!StartCleanup(paths, log))
        {
            log.Write("uninstall: could not start the cleanup step; exiting so the service restarts and retries");
            return UninstallOutcome.Failed;
        }
        log.Write("uninstall: files removed; cleanup step started");
        return UninstallOutcome.WaitForStop;
    }

    /// <summary>Runs one step, logging (by exception type only) when it throws or reports failure, and carries on either way.</summary>
    private static void Attempt(Log log, string what, Func<bool> step)
    {
        try
        {
            if (!step()) log.Write($"uninstall: {what} did not finish cleanly");
        }
        catch (Exception error)
        {
            log.Write($"uninstall: {what} failed: {error.GetType().Name}");
        }
    }

    /// <summary>
    /// True when the path is fully qualified (it starts at a drive or share), has no "." or ".." parts (it is already its own full form, so C:\X\..\SiteBlock is refused), and its last
    /// part is "SiteBlock": the only folders the cleanup step may delete.
    /// </summary>
    internal static bool IsSiteBlockFolder(string path)
    {
        if (!Path.IsPathFullyQualified(path)) return false;
        string trimmed = Path.TrimEndingDirectorySeparator(path);
        return string.Equals(Path.GetFullPath(trimmed), trimmed, StringComparison.Ordinal)
            && string.Equals(Path.GetFileName(trimmed), "SiteBlock", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Deletes a file; a missing file or one that cannot be deleted is ignored like every other file in the uninstall.</summary>
    private static void DeleteFile(string path)
    {
        try { File.Delete(path); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Deletes a folder and everything in it; a missing folder or one that cannot be deleted is ignored.</summary>
    private static void DeleteFolder(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>
    /// Removes the program folder from the machine-wide PATH (the Path value under HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment). Entries are compared without regard to
    /// letter case or a trailing backslash; every other entry, and any %VARIABLE% in it, is kept as written. Returns true when the value is right afterwards.
    /// </summary>
    [SupportedOSPlatform("windows")]
    internal static bool RemoveFromSystemPath(string programDir)
    {
        const string environmentKey = @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment";
        using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = root.OpenSubKey(environmentKey, writable: true);
        if (key?.GetValue("Path", null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not string current) return true;
        string? kept = WithoutEntry(current, programDir);
        if (kept is null) return true;
        key.SetValue("Path", kept, RegistryValueKind.ExpandString);
        return true;
    }

    /// <summary>The PATH text with every entry equal to <paramref name="folder"/> removed, or null when there was none to remove.</summary>
    internal static string? WithoutEntry(string path, string folder)
    {
        string wanted = folder.TrimEnd('\\');
        var entries = path.Split(';');
        var kept = entries.Where(entry => !string.Equals(entry.Trim().TrimEnd('\\'), wanted, StringComparison.OrdinalIgnoreCase)).ToArray();
        return kept.Length == entries.Length ? null : string.Join(';', kept);
    }

    /// <summary>Puts a text inside single quotes for PowerShell, doubling any single quote in it.</summary>
    private static string PowerShellQuote(string text) => "'" + text.Replace("'", "''") + "'";

    /// <summary>
    /// Starts a hidden, detached PowerShell that waits 2 seconds, stops the SiteBlock service, waits up to 30 seconds for siteblockd.exe to exit (the service reports Stopped a moment before
    /// the program has let go of its files), deletes the service, and deletes the program and data folders, retrying each up to 10 times a second apart in case a file is still locked.
    /// Returns false when it could not be started.
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static bool StartCleanup(Paths paths, Log log)
    {
        string service = ServiceNames.Daemon;
        // Deletes one folder, trying again a second later while anything is left, up to 10 times.
        string RemoveWithRetry(string folder) =>
            $"for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath {PowerShellQuote(folder)}); $i++) {{ Remove-Item -LiteralPath {PowerShellQuote(folder)} -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath {PowerShellQuote(folder)}) {{ Start-Sleep -Seconds 1 }} }}";
        string script = string.Join("; ",
            "$ErrorActionPreference = 'SilentlyContinue'",
            "Start-Sleep -Seconds 2",
            $"Stop-Service -Name {service} -Force",
            "Wait-Process -Name siteblockd -Timeout 30",
            $"& sc.exe delete {service} | Out-Null",
            RemoveWithRetry(paths.ProgramDir),
            RemoveWithRetry(paths.DataDir));
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        var info = new ProcessStartInfo(powershell)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            // The working folder must be outside the folders it deletes.
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System),
        };
        foreach (string argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script }) info.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(info);
            return process is not null;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            log.Write($"uninstall: cleanup step could not start: {error.Message}");
            return false;
        }
    }
}

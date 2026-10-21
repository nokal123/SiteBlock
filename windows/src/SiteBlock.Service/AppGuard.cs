using System.Diagnostics;
using System.Runtime.Versioning;

namespace SiteBlock.Service;

/// <summary>
/// Keeps the tray app installed, starting at sign-in and running for the person at the screen. Every guard pass calls
/// <see cref="Check"/>, which copies back from the backup every program file that is missing or a different size, repairs the
/// start-at-sign-in entry, and (on a real Windows system) starts the app in the console user's session when the real app is
/// not running there. The blocking never depends on the app; this stops the app (and the tab watcher inside it) from being
/// closed or deleted to make SiteBlock disappear from view. Every call comes from the guard's single thread, one at a time, so
/// the plain mutable state here needs no lock.
/// </summary>
public sealed class AppGuard : IAppGuard
{
    // A failure of the same kind is written at most once this often, so a lasting problem does not fill the log every few seconds.
    private const long RepeatedFailureLogIntervalMs = 60_000;
    // After one start attempt the next is skipped for this long, so a fast guard tick cannot launch the app again and again while it is still coming up and not yet listed.
    private const long StartThrottleMs = 5_000;
    // A start that comes this soon after the previous one means the app closed again almost at once; an app seen running this long after its start counts as staying up.
    private const long QuickExitWindowMs = 30_000;
    // After this many quick closes in a row the app is started only once a minute until it stays up, so a broken app does not flash an error at the person every 5 seconds.
    private const int QuickExitLimit = 3;
    private const long CrashBackoffMs = 60_000;

    /// The kinds of failure that are rate-limited apart, so one lasting problem cannot hide another.
    private enum FailureKind
    {
        /// The backup is missing or incomplete, so nothing can be restored from it.
        BackupUnusable,
        /// A file could not be copied from the backup into the program folder.
        CopyFailed,
        /// The copy finished but the app's own program file was not put back.
        RestoreExeMissing,
        /// The app could not be started in the signed-in user's session.
        LaunchFailed,
        /// The app keeps closing right after it is started.
        KeepsClosing,
        /// The start-at-sign-in registry value could not be repaired.
        RegistryFailed,
    }

    /// What the restore step of a pass ended with.
    private enum RestoreOutcome
    {
        /// Every program file was present and matched the backup's size.
        Intact,
        /// At least one program file was missing or replaced and has been copied back from the backup.
        Restored,
        /// The backup cannot be used, so nothing was checked or restored.
        BackupUnusable,
        /// A program file was broken and the restore failed (the reason was logged).
        Failed,
    }

    private readonly Paths _paths;
    private readonly Log _log;
    // Returns true once an uninstall has begun, so a pass stops before it restores anything the uninstaller is tearing down.
    private readonly Func<bool> _isCancelled;
    // When each kind of failure was last written to the log, as an Environment.TickCount64 reading.
    private readonly Dictionary<FailureKind, long> _lastFailureLogged = new();
    // The TickCount64 reading of the last start attempt, or null when the app has not been started yet this run.
    private long? _lastStartAttemptTick;
    // How many starts in a row came within QuickExitWindowMs of the one before, meaning the app closed again almost at once. It goes back to 0 only when the app is seen running QuickExitWindowMs after its last start.
    private int _quickExits;

    /// <summary>Creates a guard for the app and backup locations in <paramref name="paths"/>. <paramref name="isCancelled"/> is asked between the steps of a pass and must return true once an uninstall has started.</summary>
    public AppGuard(Paths paths, Log log, Func<bool> isCancelled)
    {
        _paths = paths;
        _log = log;
        _isCancelled = isCancelled;
    }

    /// <summary>Runs one check: restores the program files from the backup when needed, repairs the start-at-sign-in entry and (in production) starts the app in the console session when it is not running.</summary>
    public void Check()
    {
        if (_isCancelled()) return;
        var outcome = RestoreAppIfNeeded();
        // The registry and console work only exist on a real Windows system, so sandbox runs and non-Windows builds stop after the file work.
        if (_paths.IsSandbox || _isCancelled()) return;
        if (!OperatingSystem.IsWindows()) return;
        // A missing backup only stops the restore. The start-at-sign-in entry is still repaired and an intact app is still kept running; only with no app at all is there nothing to start.
        if (outcome == RestoreOutcome.BackupUnusable && !File.Exists(_paths.AppExe)) return;
        // A just-restored app starts without waiting out the start throttle.
        KeepAppRunning(justRestored: outcome == RestoreOutcome.Restored);
    }

    /// <summary>Stops every running tray app and removes its start-at-sign-in entry. Used by the uninstaller.</summary>
    public void StopAppsAndRemoveStartEntry()
    {
        // Kill every running tray app; a failure is ignored because a process may already be gone or belong to a session this one cannot touch.
        foreach (var process in Process.GetProcessesByName(ServiceNames.AppProcess))
        {
            try { process.Kill(); } catch { /* already exiting or not ours */ } finally { process.Dispose(); }
        }
        // The Run value only exists on a real Windows system; a sandbox or non-Windows run stops after the process kill.
        if (_paths.IsSandbox) return;
        if (!OperatingSystem.IsWindows()) return;
        AppGuardNative.DeleteRunValue(ServiceNames.RunValue);
    }

    // --- File check (production and sandbox) ---

    // Compares every program file with the backup and copies back each one that is missing or a different size. The app is a set of files (a small launcher .exe plus its .dll and the .NET runtime files), so a deleted .dll breaks it just as a deleted .exe does.
    private RestoreOutcome RestoreAppIfNeeded()
    {
        // The backup must itself be usable; restoring from a missing or half-written backup would only make another broken app and repeat every few seconds.
        if (!File.Exists(_paths.BackupAppExe))
        {
            LogFailure(FailureKind.BackupUnusable, $"cannot check the tray app: the backup at {_paths.BackupAppDir} is missing or incomplete");
            return RestoreOutcome.BackupUnusable;
        }

        var result = ProgramFolder.Restore(_paths.BackupAppDir, _paths.ProgramDir, _isCancelled);
        if (result.BackupUnreadable)
        {
            LogFailure(FailureKind.CopyFailed, $"cannot restore the tray app: the backup at {_paths.BackupAppDir} could not be read");
            return RestoreOutcome.Failed;
        }
        if (result.Restored.Count == 0 && result.Failed.Count == 0) return RestoreOutcome.Intact;

        // If the exe could not be put back (for example a replacement program is running and holds the file open), the restore failed whatever else was copied.
        var appExeName = Path.GetFileName(_paths.AppExe);
        if (result.Failed.Contains(appExeName, StringComparer.OrdinalIgnoreCase))
        {
            LogFailure(FailureKind.RestoreExeMissing, "cannot restore the tray app: its program could not be put back");
            return RestoreOutcome.Failed;
        }
        if (result.Failed.Count > 0) LogFailure(FailureKind.CopyFailed, "cannot restore some of the tray app's files from the backup");
        if (result.Restored.Count == 0) return RestoreOutcome.Failed;
        _log.Write("tray app restored");
        return RestoreOutcome.Restored;
    }

    // --- Start-at-sign-in and running checks (production only) ---

    // Repairs the Run value, then starts the app in the console user's session when the real app is not running there.
    [SupportedOSPlatform("windows")]
    private void KeepAppRunning(bool justRestored)
    {
        EnsureRunValue();
        if (_isCancelled()) return;
        // With no session on the physical console there is nobody to start the app for.
        if (AppGuardNative.ConsoleSessionId() is not uint session) return;
        // No user token means nobody is signed in to that session yet.
        if (!AppGuardNative.WTSQueryUserToken(session, out var token)) return;
        try
        {
            // Starting a second copy next to a running one would only make the first open its panel, so a running app is always left alone.
            if (AppIsRunningInSession(session))
            {
                // An app still running well after its last start has stayed up, so earlier quick closes no longer count.
                if (_lastStartAttemptTick is not long started || Environment.TickCount64 - started >= QuickExitWindowMs) _quickExits = 0;
                return;
            }
            if (!MayStartNow(justRestored)) return;
            if (AppGuardNative.StartProcessAsUser(token, _paths.AppExe, _paths.ProgramDir, out var error)) _log.Write("tray app restarted");
            else LogFailure(FailureKind.LaunchFailed, $"cannot start the tray app: {error}");
        }
        finally { AppGuardNative.CloseHandle(token); }
    }

    // Decides whether a start may happen now, and records the attempt when it may. Starts are at least 5 seconds apart (a just-restored app skips this wait). After three starts in a row that each came within 30 seconds of the one before, starts are a minute apart, and they stay a minute apart until the app is seen running 30 seconds after a start.
    private bool MayStartNow(bool justRestored)
    {
        long now = Environment.TickCount64;
        if (_lastStartAttemptTick is long last)
        {
            long since = now - last;
            if (_quickExits >= QuickExitLimit)
            {
                if (since < CrashBackoffMs)
                {
                    LogFailure(FailureKind.KeepsClosing, "the tray app keeps closing right after it starts; trying again once a minute");
                    return false;
                }
            }
            else
            {
                if (!justRestored && since < StartThrottleMs) return false;
                if (since < QuickExitWindowMs) _quickExits++;
            }
        }
        _lastStartAttemptTick = now;
        return true;
    }

    // Makes the Run value hold the quoted path of the app, rewriting it only when it is missing or different.
    [SupportedOSPlatform("windows")]
    private void EnsureRunValue()
    {
        // Windows runs this value's command at every sign-in; the quotes keep a path with spaces in one piece.
        var wanted = $"\"{_paths.AppExe}\"";
        // A small repair is not logged, matching the Mac, which does not log the start-at-sign-in rewrite unless something downstream changed.
        if (string.Equals(AppGuardNative.ReadRunValue(ServiceNames.RunValue), wanted, StringComparison.Ordinal)) return;
        if (!AppGuardNative.WriteRunValue(ServiceNames.RunValue, wanted))
            LogFailure(FailureKind.RegistryFailed, "cannot repair the tray app's start-at-sign-in entry");
    }

    // Returns true when the real tray app runs in the given console session. A process only counts when it runs from the installed program path, so any other program renamed to SiteBlockApp.exe cannot stand in for it.
    [SupportedOSPlatform("windows")]
    private bool AppIsRunningInSession(uint session)
    {
        var processes = Process.GetProcessesByName(ServiceNames.AppProcess);
        try
        {
            foreach (var process in processes)
            {
                try
                {
                    // SessionId ties a process to one sign-in; only a copy in the console session counts, so a copy left in another session is ignored.
                    if ((uint)process.SessionId != session) continue;
                    var image = AppGuardNative.ProcessImagePath(process.Id);
                    // A path that cannot be read counts as the real app. SYSTEM can read the path of every process a user can start, so this only happens for a process that is exiting, and starting a second app beside a real one would pop its panel open.
                    if (image is null || string.Equals(image, _paths.AppExe, StringComparison.OrdinalIgnoreCase)) return true;
                }
                catch { /* the process ended or its session cannot be read; it does not count */ }
            }
            return false;
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
    }

    // --- Logging ---

    // Writes a failure line, but only when a failure of the same kind was not written within the last minute.
    private void LogFailure(FailureKind kind, string message)
    {
        var now = Environment.TickCount64;
        // Different kinds are tracked apart so a lasting problem of one kind does not silence a new problem of another.
        if (_lastFailureLogged.TryGetValue(kind, out var last) && (now - last) < RepeatedFailureLogIntervalMs) return;
        _lastFailureLogged[kind] = now;
        _log.Write(message);
    }
}

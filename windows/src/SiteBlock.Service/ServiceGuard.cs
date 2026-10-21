namespace SiteBlock.Service;

/// <summary>
/// Keeps both of SiteBlock's Windows services installed, set to start automatically and running, so stopping, disabling,
/// deleting or misconfiguring one is undone within a few seconds. It does the Mac's LaunchdGuard job: the daemon guards the
/// watchdog and the watchdog guards the daemon. Every service-control step goes through <see cref="IServiceControl"/>, so the
/// decisions here hold no sc.exe text and can be driven by a fake. Only the writes that are actually needed are made, so a
/// healthy service produces no log lines; a repair is logged only when it worked, and a failed one is logged once a minute.
/// Nothing here runs in a sandbox or off Windows.
/// </summary>
public sealed class ServiceGuard : IServiceGuard
{
    // How long the same failure message stays quiet after it has been logged once, in milliseconds of Environment.TickCount64, which the person cannot change by setting the clock.
    private const long FailureQuietForMs = 60_000;
    // The service type code of a service that runs in its own process (WIN32_OWN_PROCESS).
    private const int OwnProcessType = 0x10;

    private readonly Paths _paths;
    private readonly Log _log;
    private readonly IServiceControl _control;
    // Returns true once an uninstall has begun, so a pass stops before it restores or recreates what the uninstaller is removing.
    private readonly Func<bool> _isCancelled;
    private readonly object _rateLock = new();
    // When each failure message was last logged (Environment.TickCount64). Keyed by the message, which names the service, so one service's lasting problem never hides the other's.
    private readonly Dictionary<string, long> _lastFailureLog = new(StringComparer.Ordinal);

    /// <summary>Builds a guard that repairs services through <paramref name="control"/> (the real one in production, a fake in tests). <paramref name="isCancelled"/>, when given, must return true once an uninstall has started; it is asked before each step that writes.</summary>
    public ServiceGuard(Paths paths, Log log, IServiceControl control, Func<bool>? isCancelled = null)
    {
        _paths = paths;
        _log = log;
        _control = control;
        _isCancelled = isCancelled ?? (() => false);
    }

    /// <summary>Repairs and starts the job's service when it is missing, disabled, misconfigured or stopped, and restores the program files from the backup. Makes only the writes that are needed.</summary>
    public void EnsureRunning(ServiceJob job)
    {
        // A sandbox run has no Windows services, so there is nothing to repair (the Mac's LaunchdGuard gates on sandbox the same way).
        // The decisions below all go through IServiceControl, whose real sc.exe-backed implementation is only ever constructed on Windows,
        // so the branch logic can also be exercised on the Mac with a fake control; it is never driven against a real service off Windows.
        if (_paths.IsSandbox || _isCancelled()) return;

        RestoreProgram();
        if (_isCancelled()) return;

        var name = ServiceNames.Name(job);
        // The image path the service manager stores and reports: the program in quotes, a space, then the flag.
        var wantedBinaryPath = $"\"{_paths.DaemonExe}\" {ServiceNames.Flag(job)}";
        var config = _control.GetConfig(name);

        if (config.ReadFailed)
        {
            // Nothing is known about the settings, so none are changed; the start check below still runs, because a stopped service can be started without knowing them.
            LogFailure($"could not read the {name} service's settings");
        }
        else if (!config.Exists)
        {
            var display = job == ServiceJob.Daemon ? ServiceNames.DaemonDisplay : ServiceNames.WatchdogDisplay;
            if (_control.Create(name, display, wantedBinaryPath))
            {
                _log.Write("service recreated");
                if (!_control.SetRecoveryActions(name)) LogFailure($"could not set the {name} service's recovery actions");
            }
            else
            {
                // The service could not be recreated, so there is no point trying to start it this pass.
                LogFailure($"could not recreate the {name} service");
                return;
            }
        }
        else
        {
            RepairStartSettings(name, config, wantedBinaryPath);
            RepairRunSettings(name, config);
        }

        if (_isCancelled()) return;
        // A stopped service (one just created, one just re-enabled, or one stopped by hand) is started again; a pending one is left to finish coming up.
        if (_control.GetRunState(name) == ServiceRunState.Stopped)
        {
            if (_control.Start(name)) _log.Write("service restarted");
            else LogFailure($"could not start the {name} service");
        }
    }

    /// <summary>Stops the job's service (waiting at most <paramref name="timeout"/>) and deletes it. Returns true when it is gone. Used by the uninstaller.</summary>
    public bool StopAndDelete(ServiceJob job, TimeSpan timeout)
    {
        // A sandbox run never installed a service, so it is already "gone"; the control handles the real work on Windows.
        if (_paths.IsSandbox) return true;

        var name = ServiceNames.Name(job);
        _control.StopAndWait(name, timeout);
        _control.Delete(name);
        // The service is only reported gone when a fresh read confirms it no longer exists; a read that fails proves nothing, so it does not count as gone.
        var after = _control.GetConfig(name);
        return !after.ReadFailed && !after.Exists;
    }

    // Puts the start type back to automatic and the image path back to the wanted program and flag when either differs, then sets the recovery actions again. Logs "service start type repaired" only when every step worked.
    private void RepairStartSettings(string name, ServiceConfig config, string wantedBinaryPath)
    {
        var wrongStartType = config.StartType != ServiceStartType.Automatic;
        var wrongBinaryPath = !string.Equals((config.BinaryPath ?? "").Trim(), wantedBinaryPath, StringComparison.OrdinalIgnoreCase);
        if (!wrongStartType && !wrongBinaryPath) return;

        var ok = true;
        if (wrongStartType) ok &= _control.SetStartAutomatic(name);
        if (wrongBinaryPath) ok &= _control.SetBinaryPath(name, wantedBinaryPath);
        ok &= _control.SetRecoveryActions(name);
        // The binary-path fix is logged with the same line as the start-type fix because both just put the service's startup configuration back.
        if (ok) _log.Write("service start type repaired");
        else LogFailure($"could not repair the {name} service's start settings");
    }

    // Puts back the settings that decide whether the service can run at all: a dependency on another service (a made-up one can never start), a different account (one without the rights to edit the hosts file), or a shared-process type. Each one is checked only when it was read; an unknown value is left alone.
    private void RepairRunSettings(string name, ServiceConfig config)
    {
        var wrongType = config.TypeCode is int type && type != OwnProcessType;
        var wrongAccount = config.Account is string account && !IsLocalSystem(account);
        var hasDependencies = config.Dependencies is { Count: > 0 };
        if (!wrongType && !wrongAccount && !hasDependencies) return;

        if (_control.SetRunSettings(name)) _log.Write("service account and dependencies repaired");
        else LogFailure($"could not repair the {name} service's account and dependencies");
    }

    // True for the names Windows uses for the built-in SYSTEM account in a service's settings.
    private static bool IsLocalSystem(string account) =>
        account.Equals("LocalSystem", StringComparison.OrdinalIgnoreCase) || account.Equals(@"NT AUTHORITY\SYSTEM", StringComparison.OrdinalIgnoreCase);

    // Copies back from the backup every program file that is missing or a different size. The three programs are published as many files (a small launcher .exe plus its .dll and the .NET runtime files), so a deleted or renamed .dll would stop both services at their next start even though siteblockd.exe looks fine. Never throws: a running program's files are locked on Windows, and the next pass tries again.
    private void RestoreProgram()
    {
        // The backup's siteblockd.exe marks a usable backup. Without it there is nothing to restore from; that is only worth logging when the program itself is also gone.
        if (!File.Exists(_paths.BackupDaemonExe))
        {
            if (!File.Exists(_paths.DaemonExe)) LogFailure("cannot restore siteblockd.exe: the backup copy is missing");
            return;
        }

        var result = ProgramFolder.Restore(_paths.BackupAppDir, _paths.ProgramDir, _isCancelled);
        if (result.BackupUnreadable)
        {
            LogFailure("cannot restore the program files: the backup could not be read");
            return;
        }
        var daemonExeName = Path.GetFileName(_paths.DaemonExe);
        if (result.Restored.Contains(daemonExeName, StringComparer.OrdinalIgnoreCase)) _log.Write("siteblockd.exe restored from backup");
        if (result.Restored.Any(file => !file.Equals(daemonExeName, StringComparison.OrdinalIgnoreCase))) _log.Write("program files restored from backup");
        if (result.Failed.Count > 0) LogFailure("could not restore some program files from backup (they may be running and locked, or access was denied)");
    }

    // Writes a failure line, but only when the same line has not been logged in the last minute, so a repeating problem logs once a minute rather than on every pass.
    private void LogFailure(string message)
    {
        var now = Environment.TickCount64;
        lock (_rateLock)
        {
            if (_lastFailureLog.TryGetValue(message, out var last) && now - last < FailureQuietForMs) return;
            _lastFailureLog[message] = now;
        }
        _log.Write(message);
    }
}

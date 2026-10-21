using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// The watchdog loop that <c>siteblockd.exe --watchdog</c> runs. Every 5 seconds it makes sure the main daemon service is
/// installed and running, unless the state file records a finished uninstall. It mirrors the Mac's <c>runWatchdog</c>: it
/// never touches the hosts file or the pipe, and a missing install folder or state file is a thing to repair, not an
/// uninstall. The daemon guards the watchdog the other way on its own 5-second guard timer.
/// </summary>
public static class Watchdog
{
    // How long between checks, matching the Mac's 5-second guard interval.
    private const int CheckIntervalMs = 5000;

    /// <summary>Runs one check: unless a finished uninstall is recorded in the state file, make sure the daemon service is installed and running. This is the one iteration tests drive directly.</summary>
    public static void RunOnce(Paths paths, IServiceGuard guard, Log log)
    {
        byte[]? stateBytes = ReadStateBytes(paths);
        // A finished uninstall is the one case where the watchdog must stand down; every other case (missing, unreadable or hand-edited state) means keep guarding.
        if (!UninstallRule.WatchdogShouldStandDown(stateBytes)) guard.EnsureRunning(ServiceJob.Daemon);
    }

    /// <summary>Logs that the watchdog started, then runs <see cref="RunOnce"/> right away and every 5 seconds until <paramref name="token"/> is cancelled.</summary>
    public static void RunLoop(Paths paths, IServiceGuard guard, Log log, CancellationToken token)
    {
        log.Write("watchdog started");
        while (!token.IsCancellationRequested)
        {
            RunOnce(paths, guard, log);
            // A cancellable wait, not a sleep, so the loop stops promptly: WaitOne returns true when the token is cancelled and false on the 5-second timeout.
            if (token.WaitHandle.WaitOne(CheckIntervalMs)) break;
        }
    }

    // Reads the state file's raw bytes, treating a missing file, a missing folder or any read error as null, so an unreadable state can never be mistaken for a finished uninstall.
    private static byte[]? ReadStateBytes(Paths paths)
    {
        try { return File.ReadAllBytes(paths.StateFile); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}

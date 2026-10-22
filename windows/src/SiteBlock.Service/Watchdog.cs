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
    // A failed check is logged at most this often, so a lasting problem does not fill the log every 5 seconds.
    private const long FailureLogIntervalMs = 60_000;

    /// <summary>Runs one check: unless a finished uninstall is recorded in the state file, make sure the daemon service is installed and running. This is the one iteration tests drive directly.</summary>
    public static void RunOnce(Paths paths, IServiceGuard guard, Log log)
    {
        byte[]? stateBytes = ReadStateBytes(paths);
        // A finished uninstall is the one case where the watchdog must stand down; every other case (missing, unreadable or hand-edited state) means keep guarding.
        if (!UninstallRule.WatchdogShouldStandDown(stateBytes)) guard.EnsureRunning(ServiceJob.Daemon);
    }

    /// <summary>Logs that the watchdog started, then runs <see cref="RunOnce"/> right away and every 5 seconds until <paramref name="token"/> is cancelled. A check that throws is logged (at most once a minute) and the loop goes on, because a dead watchdog leaves the daemon unguarded.</summary>
    public static void RunLoop(Paths paths, IServiceGuard guard, Log log, CancellationToken token)
    {
        log.Write("watchdog started");
        long? lastFailureLogged = null;
        while (!token.IsCancellationRequested)
        {
            try
            {
                RunOnce(paths, guard, log);
            }
            catch (Exception error)
            {
                // Only the error's type is logged; its message could name a file path. TickCount64 is used so setting the clock back cannot silence the log.
                long now = Environment.TickCount64;
                if (lastFailureLogged is not long last || now - last >= FailureLogIntervalMs)
                {
                    lastFailureLogged = now;
                    log.Write($"watchdog check failed ({error.GetType().Name})");
                }
            }
            // A cancellable wait, not a sleep, so the loop stops promptly: WaitOne returns true when the token is cancelled and false on the 5-second timeout.
            if (token.WaitHandle.WaitOne(CheckIntervalMs)) break;
        }
    }

    // Reads the state file's raw bytes, treating a missing file, a missing folder or any read error as null, so an unreadable state can never be mistaken for a finished uninstall.
    // The file is opened with read, write and delete sharing, so this read never makes the daemon's save fail: the daemon replaces state.json by moving a new file over it, which Windows refuses while another handle lacks delete sharing.
    private static byte[]? ReadStateBytes(Paths paths)
    {
        try
        {
            using var stream = new FileStream(paths.StateFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            return buffer.ToArray();
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}

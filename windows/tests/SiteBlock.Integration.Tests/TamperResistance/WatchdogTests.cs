using SiteBlock.Core;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// Expected values come from 06-windows.md § ServiceGuard (watchdog loop) and the macOS runWatchdog + UninstallRule it mirrors.
public sealed class WatchdogTests
{
    // Writes the encoded state to the sandbox state file, creating the folder first.
    private static void WriteState(TempSandbox s, PersistedState state)
    {
        Directory.CreateDirectory(s.Paths.StateDir);
        File.WriteAllBytes(s.Paths.StateFile, JsonCoding.Encode(state));
    }

    [Fact]
    public void RunOnce_FinishedUninstall_DoesNotGuard()
    {
        using var s = new TempSandbox();
        // A real finished uninstall: the flag is set and the uninstall countdown has run out.
        WriteState(s, new PersistedState(1800, uninstalling: true, pendingUninstall: new Countdown(0)));
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Empty(guard.EnsureCalls);
    }

    [Fact]
    public void RunOnce_UninstallingFlagButNoCountdown_StillGuards()
    {
        using var s = new TempSandbox();
        // Hand-editing the flag without the finished countdown must not switch the guard off.
        WriteState(s, new PersistedState(1800, uninstalling: true));
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Equal([ServiceJob.Daemon], guard.EnsureCalls);
    }

    [Fact]
    public void RunOnce_UninstallingWithUnfinishedCountdown_StillGuards()
    {
        using var s = new TempSandbox();
        WriteState(s, new PersistedState(1800, uninstalling: true, pendingUninstall: new Countdown(100)));
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Equal([ServiceJob.Daemon], guard.EnsureCalls);
    }

    [Fact]
    public void RunOnce_FinishedCountdownButNotUninstalling_StillGuards()
    {
        using var s = new TempSandbox();
        // The countdown alone, without the uninstalling flag, is not a finished uninstall.
        WriteState(s, new PersistedState(1800, uninstalling: false, pendingUninstall: new Countdown(0)));
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Equal([ServiceJob.Daemon], guard.EnsureCalls);
    }

    [Fact]
    public void RunOnce_MissingStateFile_StillGuards()
    {
        using var s = new TempSandbox();
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Equal([ServiceJob.Daemon], guard.EnsureCalls);
    }

    [Fact]
    public void RunOnce_UnreadableBytes_StillGuards()
    {
        using var s = new TempSandbox();
        Directory.CreateDirectory(s.Paths.StateDir);
        File.WriteAllBytes(s.Paths.StateFile, [0x00, 0x01, 0x02, 0xFF]);
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Equal([ServiceJob.Daemon], guard.EnsureCalls);
    }

    [Fact]
    public void RunOnce_ValidJsonButNotAState_StillGuards()
    {
        using var s = new TempSandbox();
        Directory.CreateDirectory(s.Paths.StateDir);
        // Well-formed JSON that is missing the required state fields decodes to null, which is not a finished uninstall.
        File.WriteAllText(s.Paths.StateFile, "{}");
        var guard = new FakeServiceGuard();

        Watchdog.RunOnce(s.Paths, guard, s.Log);

        Assert.Equal([ServiceJob.Daemon], guard.EnsureCalls);
    }

    [Fact]
    public void RunLoop_WhenACheckThrows_LogsOnceAndReturnsWithoutThrowing()
    {
        using var s = new TempSandbox();
        var cts = new CancellationTokenSource();
        // The guard cancels the loop and then throws, so the single pass logs the failure and the WaitOne sees the token already
        // cancelled and returns at once: the catch and the type-only message are pinned with no 5-second wait. The "keeps looping
        // over many passes" property and the once-a-minute throttle need a real 5 s WaitOne, so they are left to the e2e run.
        var guard = new CancelThenThrowServiceGuard(cts);

        var error = Record.Exception(() => Watchdog.RunLoop(s.Paths, guard, s.Log, cts.Token));

        Assert.Null(error);
        Assert.Equal(["watchdog started", "watchdog check failed (InvalidOperationException)"], s.LogMessages());
    }

    // A guard that cancels the loop's token and then throws on its one and only call.
    private sealed class CancelThenThrowServiceGuard(CancellationTokenSource cts) : IServiceGuard
    {
        public void EnsureRunning(ServiceJob job)
        {
            cts.Cancel();
            throw new InvalidOperationException("simulated check failure");
        }

        public bool StopAndDelete(ServiceJob job, TimeSpan timeout) => true;
    }
}

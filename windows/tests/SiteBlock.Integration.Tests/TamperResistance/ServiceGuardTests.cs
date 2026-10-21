using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// Expected values come from 06-windows.md § ServiceGuard and the macOS LaunchdGuard it mirrors, never from ServiceGuard.cs.
public sealed class ServiceGuardTests
{
    // The image path the design says the service manager must hold: the program in quotes, a space, then the job's flag.
    private static string WantedBinPath(Paths paths, string flag) => $"\"{paths.DaemonExe}\" {flag}";

    // Makes the program and its backup present and the same size, so RestoreProgram is a no-op and cannot add log noise to a service-decision test.
    private static void WriteHealthyProgram(TempSandbox s)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.DaemonExe)!);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.BackupDaemonExe)!);
        File.WriteAllBytes(s.Paths.DaemonExe, new byte[64]);
        File.WriteAllBytes(s.Paths.BackupDaemonExe, new byte[64]);
    }

    [Fact]
    public void EnsureRunning_MissingDaemonService_RecreatesWithRightConfigThenStarts()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl { Config = new ServiceConfig(false, ServiceStartType.Unknown, null), RunState = ServiceRunState.Stopped };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Equal("SiteBlock", control.CreatedName);
        Assert.Equal("SiteBlock", control.CreatedDisplay);
        Assert.Equal(WantedBinPath(s.Paths, "--daemon"), control.CreatedBinPath);
        Assert.Contains("SetRecoveryActions", control.Calls);
        Assert.Contains("Start", control.Calls);
        Assert.Equal(["service recreated", "service restarted"], s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_MissingWatchdogService_RecreatesWithWatchdogNameDisplayAndFlag()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl { Config = new ServiceConfig(false, ServiceStartType.Unknown, null), RunState = ServiceRunState.Running };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Watchdog);

        Assert.Equal("SiteBlockWatchdog", control.CreatedName);
        Assert.Equal("SiteBlock Watchdog", control.CreatedDisplay);
        Assert.Equal(WantedBinPath(s.Paths, "--watchdog"), control.CreatedBinPath);
    }

    [Fact]
    public void EnsureRunning_CreateFails_DoesNotAttemptStart()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl { Config = new ServiceConfig(false, ServiceStartType.Unknown, null), CreateResult = false, RunState = ServiceRunState.Stopped };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Contains("Create", control.Calls);
        Assert.DoesNotContain("Start", control.Calls);
        Assert.DoesNotContain("SetRecoveryActions", control.Calls);
        Assert.DoesNotContain("service recreated", s.LogMessages());
    }

    [Theory]
    [InlineData(ServiceStartType.Disabled)]
    [InlineData(ServiceStartType.Manual)]
    public void EnsureRunning_WrongStartType_RepairsStartTypeAndRecovery(ServiceStartType startType)
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, startType, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Contains("SetStartAutomatic", control.Calls);
        Assert.DoesNotContain("SetBinaryPath", control.Calls);
        Assert.Contains("SetRecoveryActions", control.Calls);
        Assert.Equal(["service start type repaired"], s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_WrongBinaryPath_RepairsBinaryPathAndRecovery()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, "\"C:\\somewhere\\else.exe\" --daemon"),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Contains("SetBinaryPath", control.Calls);
        Assert.Equal(WantedBinPath(s.Paths, "--daemon"), control.SetBinPathValue);
        Assert.DoesNotContain("SetStartAutomatic", control.Calls);
        Assert.Contains("SetRecoveryActions", control.Calls);
        Assert.Equal(["service start type repaired"], s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_HealthyRunningService_MakesNoWritesAndLogsNothing()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.DoesNotContain("Create", control.Calls);
        Assert.DoesNotContain("SetStartAutomatic", control.Calls);
        Assert.DoesNotContain("SetBinaryPath", control.Calls);
        Assert.DoesNotContain("SetRecoveryActions", control.Calls);
        Assert.DoesNotContain("Start", control.Calls);
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_HealthyButStopped_StartsAndLogsRestarted()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Stopped,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.DoesNotContain("SetStartAutomatic", control.Calls);
        Assert.DoesNotContain("SetBinaryPath", control.Calls);
        Assert.Contains("Start", control.Calls);
        Assert.Equal(["service restarted"], s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_PendingRunState_DoesNotStart()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Other,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.DoesNotContain("Start", control.Calls);
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void RestoreProgram_ProgramMissing_CopiesFromBackup()
    {
        using var s = new TempSandbox(isSandbox: false);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.DaemonExe)!);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.BackupDaemonExe)!);
        byte[] backup = [1, 2, 3, 4, 5];
        File.WriteAllBytes(s.Paths.BackupDaemonExe, backup);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.True(File.Exists(s.Paths.DaemonExe));
        Assert.Equal(backup, File.ReadAllBytes(s.Paths.DaemonExe));
        // Only siteblockd.exe was restored, so only its line appears, not the "program files" line.
        Assert.Contains("siteblockd.exe restored from backup", s.LogMessages());
        Assert.DoesNotContain("program files restored from backup", s.LogMessages());
    }

    [Fact]
    public void RestoreProgram_OtherFilesMissing_LogsBothRestoreLines()
    {
        using var s = new TempSandbox(isSandbox: false);
        Directory.CreateDirectory(s.Paths.BackupAppDir);
        // The backup holds siteblockd.exe plus a runtime .dll; the program folder is empty, so both are copied back.
        File.WriteAllBytes(s.Paths.BackupDaemonExe, [1, 2, 3]);
        File.WriteAllBytes(Path.Combine(s.Paths.BackupAppDir, "App.dll"), [4, 5]);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Contains("siteblockd.exe restored from backup", s.LogMessages());
        Assert.Contains("program files restored from backup", s.LogMessages());
        Assert.Equal(new byte[] { 4, 5 }, File.ReadAllBytes(Path.Combine(s.Paths.ProgramDir, "App.dll")));
    }

    [Fact]
    public void EnsureRunning_ConfigReadFailed_ChangesNoSettingsButStillStarts()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Unknown, null, ReadFailed: true),
            RunState = ServiceRunState.Stopped,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.DoesNotContain("Create", control.Calls);
        Assert.DoesNotContain("SetStartAutomatic", control.Calls);
        Assert.DoesNotContain("SetBinaryPath", control.Calls);
        Assert.DoesNotContain("SetRunSettings", control.Calls);
        Assert.DoesNotContain("SetRecoveryActions", control.Calls);
        Assert.Contains("Start", control.Calls);
        Assert.Equal(["could not read the SiteBlock service's settings", "service restarted"], s.LogMessages());
    }

    [Theory]
    [InlineData(0x20, "LocalSystem", false)]
    [InlineData(0x10, "NT AUTHORITY\\NetworkService", false)]
    [InlineData(0x10, "LocalSystem", true)]
    public void EnsureRunning_WrongRunSettings_RepairsThem(int typeCode, string account, bool hasDependency)
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var dependencies = hasDependency ? new List<string> { "Tcpip" } : new List<string>();
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon"), typeCode, account, dependencies),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Contains("SetRunSettings", control.Calls);
        Assert.Equal(["service account and dependencies repaired"], s.LogMessages());
    }

    [Theory]
    [InlineData("LocalSystem")]
    [InlineData("NT AUTHORITY\\SYSTEM")]
    public void EnsureRunning_GoodRunSettings_MakesNoRunSettingsWrite(string account)
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon"), 0x10, account, new List<string>()),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.DoesNotContain("SetRunSettings", control.Calls);
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_StartSettingsRepairFails_LogsFailureNotRepaired()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Disabled, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
            SetStartAutomaticResult = false,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.DoesNotContain("service start type repaired", s.LogMessages());
        Assert.Contains("could not repair the SiteBlock service's start settings", s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_RecoveryActionsFailAfterCreate_StillLogsRecreatedPlusFailure()
    {
        using var s = new TempSandbox(isSandbox: false);
        WriteHealthyProgram(s);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(false, ServiceStartType.Unknown, null),
            RunState = ServiceRunState.Running,
            SetRecoveryActionsResult = false,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Contains("service recreated", s.LogMessages());
        Assert.Contains("could not set the SiteBlock service's recovery actions", s.LogMessages());
    }

    [Fact]
    public void EnsureRunning_Cancelled_MakesNoWrites()
    {
        using var s = new TempSandbox(isSandbox: false);
        var control = new FakeServiceControl { Config = new ServiceConfig(false, ServiceStartType.Unknown, null), RunState = ServiceRunState.Stopped };
        var guard = new ServiceGuard(s.Paths, s.Log, control, isCancelled: () => true);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Empty(control.Calls);
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void StopAndDelete_FreshReadFails_ReturnsFalse()
    {
        using var s = new TempSandbox(isSandbox: false);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            DeleteResult = true,
            // After the delete, the read fails and reports the service absent. Only code that checks !ReadFailed (not just !Exists)
            // will refuse to report it gone, so Exists:false here forces that check rather than letting an Exists-only test pass.
            ConfigAfterDelete = new ServiceConfig(false, ServiceStartType.Unknown, null, ReadFailed: true),
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        bool gone = guard.StopAndDelete(ServiceJob.Daemon, TimeSpan.FromSeconds(10));

        Assert.False(gone);
    }

    [Fact]
    public void RestoreProgram_DifferentSize_CopiesFromBackup()
    {
        using var s = new TempSandbox(isSandbox: false);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.DaemonExe)!);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.BackupDaemonExe)!);
        byte[] backup = [9, 9, 9, 9, 9, 9];
        File.WriteAllBytes(s.Paths.BackupDaemonExe, backup);
        File.WriteAllBytes(s.Paths.DaemonExe, [0, 0]);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Equal(backup, File.ReadAllBytes(s.Paths.DaemonExe));
    }

    [Fact]
    public void RestoreProgram_SameSize_DoesNotCopy()
    {
        using var s = new TempSandbox(isSandbox: false);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.DaemonExe)!);
        Directory.CreateDirectory(Path.GetDirectoryName(s.Paths.BackupDaemonExe)!);
        // Same length, different content: if the guard wrongly copied, the program's bytes would turn into the backup's.
        byte[] program = [1, 1, 1, 1];
        byte[] backup = [2, 2, 2, 2];
        File.WriteAllBytes(s.Paths.DaemonExe, program);
        File.WriteAllBytes(s.Paths.BackupDaemonExe, backup);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Equal(program, File.ReadAllBytes(s.Paths.DaemonExe));
    }

    [Fact]
    public void RestoreProgram_BackupAndProgramBothMissing_LogsOnlyOncePerMinute()
    {
        using var s = new TempSandbox(isSandbox: false);
        // Neither the program nor its backup exists, so each pass hits the backup-missing failure; the second pass within a minute must stay silent.
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            RunState = ServiceRunState.Running,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);
        guard.EnsureRunning(ServiceJob.Daemon);

        var backupLines = s.LogMessages().Where(m => m.Contains("backup")).ToList();
        Assert.Single(backupLines);
    }

    [Fact]
    public void EnsureRunning_Sandbox_DoesNothing()
    {
        using var s = new TempSandbox(isSandbox: true);
        var control = new FakeServiceControl { Config = new ServiceConfig(false, ServiceStartType.Unknown, null) };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        guard.EnsureRunning(ServiceJob.Daemon);

        Assert.Empty(control.Calls);
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void StopAndDelete_Sandbox_ReturnsTrueWithoutTouchingControl()
    {
        using var s = new TempSandbox(isSandbox: true);
        var control = new FakeServiceControl();
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        bool gone = guard.StopAndDelete(ServiceJob.Daemon, TimeSpan.FromSeconds(10));

        Assert.True(gone);
        Assert.Empty(control.Calls);
    }

    [Fact]
    public void StopAndDelete_StopsThenDeletesAndReportsGone()
    {
        using var s = new TempSandbox(isSandbox: false);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            DeleteResult = true,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        bool gone = guard.StopAndDelete(ServiceJob.Watchdog, TimeSpan.FromSeconds(7));

        Assert.True(gone);
        Assert.Contains("StopAndWait", control.Calls);
        Assert.Contains("Delete", control.Calls);
        Assert.Equal(TimeSpan.FromSeconds(7), control.StopTimeout);
    }

    [Fact]
    public void StopAndDelete_DeleteLeavesServicePresent_ReturnsFalse()
    {
        using var s = new TempSandbox(isSandbox: false);
        var control = new FakeServiceControl
        {
            Config = new ServiceConfig(true, ServiceStartType.Automatic, WantedBinPath(s.Paths, "--daemon")),
            DeleteResult = false,
        };
        var guard = new ServiceGuard(s.Paths, s.Log, control);

        bool gone = guard.StopAndDelete(ServiceJob.Daemon, TimeSpan.FromSeconds(10));

        Assert.False(gone);
    }
}

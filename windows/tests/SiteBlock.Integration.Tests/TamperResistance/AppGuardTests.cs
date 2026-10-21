using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// Expected values come from 06-windows.md § AppGuard and the macOS AppGuard it mirrors. Only the file-restore step runs in a sandbox; the registry and console steps are skipped off Windows.
public sealed class AppGuardTests
{
    // Writes the backup's tray-app exe and any extra program files under the backup folder.
    private static void SeedBackup(TempSandbox s, byte[] exeBytes, params (string Relative, byte[] Data)[] extra)
    {
        Directory.CreateDirectory(s.Paths.BackupAppDir);
        File.WriteAllBytes(s.Paths.BackupAppExe, exeBytes);
        foreach (var (relative, data) in extra)
        {
            string full = Path.Combine(s.Paths.BackupAppDir, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllBytes(full, data);
        }
    }

    [Fact]
    public void Check_BackupExeMissing_LogsOncePerMinuteAndCopiesNothing()
    {
        using var s = new TempSandbox();
        // No backup folder at all, so there is nothing to restore from.
        var guard = new AppGuard(s.Paths, s.Log, () => false);

        guard.Check();
        guard.Check();

        Assert.False(File.Exists(s.Paths.AppExe));
        var lines = s.LogMessages();
        Assert.Single(lines);
        Assert.Contains("backup", lines[0]);
    }

    [Fact]
    public void Check_AppPresentAndSameSize_DoesNothing()
    {
        using var s = new TempSandbox();
        SeedBackup(s, [1, 1, 1, 1]);
        Directory.CreateDirectory(s.Paths.ProgramDir);
        // Same length, different content: if the guard wrongly restored, the app's bytes would become the backup's.
        byte[] appBytes = [2, 2, 2, 2];
        File.WriteAllBytes(s.Paths.AppExe, appBytes);
        var guard = new AppGuard(s.Paths, s.Log, () => false);

        guard.Check();

        Assert.Equal(appBytes, File.ReadAllBytes(s.Paths.AppExe));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void Check_AppMissing_CopiesEveryBackupFileAndLogsRestored()
    {
        using var s = new TempSandbox();
        byte[] exeBytes = [9, 8, 7, 6];
        byte[] dllBytes = [5, 5, 5];
        byte[] nestedBytes = [4, 4];
        SeedBackup(s, exeBytes, ("App.dll", dllBytes), (Path.Combine("runtime", "extra.txt"), nestedBytes));
        var guard = new AppGuard(s.Paths, s.Log, () => false);

        guard.Check();

        Assert.Equal(exeBytes, File.ReadAllBytes(s.Paths.AppExe));
        Assert.Equal(dllBytes, File.ReadAllBytes(Path.Combine(s.Paths.ProgramDir, "App.dll")));
        Assert.Equal(nestedBytes, File.ReadAllBytes(Path.Combine(s.Paths.ProgramDir, "runtime", "extra.txt")));
        Assert.Contains("tray app restored", s.LogMessages());
    }

    [Fact]
    public void Check_AppDifferentSize_RestoresFromBackup()
    {
        using var s = new TempSandbox();
        byte[] exeBytes = [1, 2, 3, 4, 5, 6];
        SeedBackup(s, exeBytes);
        Directory.CreateDirectory(s.Paths.ProgramDir);
        File.WriteAllBytes(s.Paths.AppExe, [0, 0]);
        var guard = new AppGuard(s.Paths, s.Log, () => false);

        guard.Check();

        Assert.Equal(exeBytes, File.ReadAllBytes(s.Paths.AppExe));
        Assert.Contains("tray app restored", s.LogMessages());
    }

    [Fact]
    public void Check_AppExeCannotBePutBack_LogsFailureNotRestored()
    {
        using var s = new TempSandbox();
        SeedBackup(s, [1, 2, 3, 4]);
        // A directory sitting at the app's exe path cannot be overwritten by a file copy, so the exe restore fails.
        Directory.CreateDirectory(s.Paths.AppExe);
        var guard = new AppGuard(s.Paths, s.Log, () => false);

        guard.Check();

        var lines = s.LogMessages();
        Assert.DoesNotContain("tray app restored", lines);
        Assert.NotEmpty(lines);
    }

    [Fact]
    public void Check_Cancelled_DoesNotRestore()
    {
        using var s = new TempSandbox();
        SeedBackup(s, [1, 2, 3, 4]);
        var guard = new AppGuard(s.Paths, s.Log, () => true);

        guard.Check();

        Assert.False(File.Exists(s.Paths.AppExe));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void StopAppsAndRemoveStartEntry_Sandbox_DoesNotReachRegistry()
    {
        using var s = new TempSandbox();
        var guard = new AppGuard(s.Paths, s.Log, () => false);

        // In a sandbox this kills any tray-app process (none in the test) and returns before any Windows registry call, so it must not throw off Windows.
        var error = Record.Exception(() => guard.StopAppsAndRemoveStartEntry());

        Assert.Null(error);
    }
}

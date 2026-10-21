using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// Expected values come from 06-windows.md § Installed Paths and Permissions. Off Windows the guard only creates the folders and never applies an access list.
public sealed class AclGuardTests
{
    [Fact]
    public void Ensure_Sandbox_CreatesAllFoldersWithoutLoggingOrThrowing()
    {
        using var s = new TempSandbox();
        var guard = new AclGuard(s.Paths, s.Log);

        guard.Ensure();

        Assert.True(Directory.Exists(s.Paths.DataDir));
        Assert.True(Directory.Exists(s.Paths.StateDir));
        Assert.True(Directory.Exists(s.Paths.LogDir));
        Assert.True(Directory.Exists(s.Paths.BackupAppDir));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void Ensure_NonWindows_CreatesFoldersAndSkipsAccessLists()
    {
        // A non-sandbox Paths whose folders live under the temp dir reaches the Windows-only branch, which is skipped off Windows: the folders are still created and no access-list log line appears.
        using var s = new TempSandbox(isSandbox: false);
        var guard = new AclGuard(s.Paths, s.Log);

        guard.Ensure();

        Assert.True(Directory.Exists(s.Paths.DataDir));
        Assert.True(Directory.Exists(s.Paths.StateDir));
        Assert.True(Directory.Exists(s.Paths.LogDir));
        Assert.True(Directory.Exists(s.Paths.BackupAppDir));
        Assert.Empty(s.LogMessages());
    }

    [Fact]
    public void Ensure_FoldersAlreadyPresent_IsANoOp()
    {
        using var s = new TempSandbox();
        Directory.CreateDirectory(s.Paths.DataDir);
        Directory.CreateDirectory(s.Paths.StateDir);
        Directory.CreateDirectory(s.Paths.LogDir);
        Directory.CreateDirectory(s.Paths.BackupAppDir);
        var guard = new AclGuard(s.Paths, s.Log);

        var error = Record.Exception(() => guard.Ensure());

        Assert.Null(error);
        Assert.Empty(s.LogMessages());
    }
}

using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.Daemon;

// What an uninstall deletes, and the folder check that guards the production cleanup step.
// Expected values come from 06-windows.md § Uninstaller (step 6: each folder path must be fully qualified, start at a drive root, have no relative parts, and end in "SiteBlock";
// the sandbox run replaces steps 2, 4, 5 and 6 by deleting <sandbox>/siteblock.pipe, <sandbox>/app/SiteBlockApp.exe and the folder <sandbox>/backup/app) and
// § Installed Paths and Permissions (Sandbox: the stand-in paths).
public sealed class UninstallCleanupTests
{
    [Fact]
    public void SandboxUninstall_DeletesTheAppStandInAndTheAppBackupFolderButNothingElse()
    {
        byte[] app = [1, 2, 3, 4];
        using var daemon = SandboxDaemon.Start(prepare: d =>
        {
            Directory.CreateDirectory(Path.Combine(d.Root, "app"));
            File.WriteAllBytes(Path.Combine(d.Root, "app", "SiteBlockApp.exe"), app);
            Directory.CreateDirectory(Path.Combine(d.Root, "backup", "app", "runtimes"));
            File.WriteAllBytes(Path.Combine(d.Root, "backup", "app", "SiteBlockApp.exe"), app);
            File.WriteAllBytes(Path.Combine(d.Root, "backup", "app", "runtimes", "SiteBlock.Core.dll"), [5, 6]);
        });
        daemon.SetupAndAdd("reddit.com");
        Assert.True(File.Exists(daemon.StateBackupPath), "the state backup was never written, so the control below would prove nothing");

        Assert.True(daemon.Send(new Request(Command.Uninstall, Password: Defaults.Password)).Ok);
        Assert.Equal(0, daemon.WaitForExit(15));

        Assert.False(File.Exists(Path.Combine(daemon.Root, "app", "SiteBlockApp.exe")));
        Assert.False(Directory.Exists(Path.Combine(daemon.Root, "backup", "app")));
        Assert.False(File.Exists(daemon.PipePath));
        // Control: the sandbox deletes only its stand-ins. Step 5 (which removes the state backup) is replaced in a sandbox, and the hosts file is cleaned, not deleted.
        Assert.True(File.Exists(daemon.StateBackupPath));
        Assert.Equal(SandboxDaemon.StartingHosts, daemon.HostsText());
    }

    [Theory]
    [InlineData(@"C:\Program Files\SiteBlock")]
    [InlineData(@"C:\ProgramData\SiteBlock\")]
    [InlineData(@"D:\Apps\SiteBlock")]
    public void IsSiteBlockFolder_FullWindowsPathEndingInSiteBlock_IsTrueWhereThePlatformTreatsItAsFullyQualified(string path)
    {
        // A drive-letter path is fully qualified only on Windows; on macOS and Linux it is a relative name, which the rule refuses.
        Assert.Equal(OperatingSystem.IsWindows(), Uninstaller.IsSiteBlockFolder(path));
    }

    [Theory]
    [InlineData("/x/SiteBlock")]
    [InlineData("/Library/Application Support/SiteBlock/")]
    public void IsSiteBlockFolder_FullUnixPathEndingInSiteBlock_IsTrueOffWindows(string path)
    {
        // On Windows a path starting with "/" is relative to the current drive, so it is not fully qualified there.
        Assert.Equal(!OperatingSystem.IsWindows(), Uninstaller.IsSiteBlockFolder(path));
    }

    public static TheoryData<string> NeverDeleted => new()
    {
        "",
        "SiteBlock",
        @"Program Files\SiteBlock",
        "x/SiteBlock",
        "/",
        @"C:\",
        "/x/SiteBlock.old",
        "/x/NotSiteBlock",
        "/x/SiteBlock/bin",
        @"C:\Program Files\SiteBlock\bin",
        @"C:\Program Files",
        "/x/../SiteBlock",
        "/x/./SiteBlock",
        "/x/SiteBlock/..",
        @"C:\x\..\SiteBlock",
        @"C:\x\.\SiteBlock",
    };

    [Theory]
    [MemberData(nameof(NeverDeleted))]
    public void IsSiteBlockFolder_RelativeEmptyRootOtherNameOrDotParts_IsFalse(string path)
    {
        Assert.False(Uninstaller.IsSiteBlockFolder(path), path);
    }
}

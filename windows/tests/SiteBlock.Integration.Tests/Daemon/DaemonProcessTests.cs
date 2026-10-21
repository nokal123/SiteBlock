using System.Text.Json.Nodes;
using System.Xml.Linq;
using SiteBlock.Core;
using SiteBlock.Daemon;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// siteblockd as a process: its flags, its version line, a second copy, and a polite stop.
// Expected values: 03-daemon-cli-app.md § siteblockd Entry Point (flags, exit code 64) and § Daemon Runtime (second daemon exits 1; SIGTERM saves and exits 0),
// 06-windows.md § Flags (--version text) and § Install, Package and Release (version numbers), and the user's 2026-10-22 decision on --sandbox:
// on Windows it is allowed elevated but refused (exit 64) for a folder that is, is inside, or contains the hosts folder, C:\Program Files\SiteBlock or C:\ProgramData\SiteBlock;
// on macOS and Linux it is refused when running as root.
public sealed class DaemonProcessTests
{
    // The windows/ folder of the repository, found from this source file's own location (the build may put the test assembly anywhere, such as an artifacts folder).
    private static string WindowsFolder([System.Runtime.CompilerServices.CallerFilePath] string sourceFile = "")
    {
        for (var folder = new FileInfo(sourceFile).Directory; folder is not null; folder = folder.Parent)
        {
            if (File.Exists(Path.Combine(folder.FullName, "version.props")) && File.Exists(Path.Combine(folder.FullName, "SiteBlock.sln"))) return folder.FullName;
        }
        throw new InvalidOperationException("could not find the windows/ folder above " + sourceFile);
    }

    // One property from an MSBuild props file, or null when it is not there.
    private static string? Property(string file, string name) =>
        File.Exists(file) ? XDocument.Load(file).Descendants(name).FirstOrDefault()?.Value.Trim() : null;

    [Fact]
    public void Version_PrintsTheSeriesTheBuildsSinceTheSeriesStartAndTheBuildNumber()
    {
        string windows = WindowsFolder();
        string series = Property(Path.Combine(windows, "version.props"), "WindowsSeries")!;
        int firstBuild = int.Parse(Property(Path.Combine(windows, "version.props"), "WindowsSeriesFirstBuild")!, System.Globalization.CultureInfo.InvariantCulture);
        // BuildNumber.props is generated; without it the build number is 0.
        int build = int.Parse(Property(Path.Combine(windows, "BuildNumber.props"), "SiteBlockBuildNumber") ?? "0", System.Globalization.CultureInfo.InvariantCulture);

        var result = Programs.Daemon("--version");

        Assert.Equal(0, result.ExitCode);
        Assert.Equal($"siteblockd {series}.{Math.Max(0, build - firstBuild)} (build {build})", result.StandardOutput.TrimEnd('\r', '\n'));
    }

    [Theory]
    [InlineData("--frobnicate")]
    [InlineData("--daemon", "--tick", "1")]
    [InlineData("--daemon", "--policy-fast")]
    [InlineData("--daemon", "--watchdog")]
    [InlineData("--daemon", "--version")]
    [InlineData("--daemon", "--sandbox")]
    [InlineData("--sandbox", "/tmp/sbq-flags")]
    [InlineData("--daemon", "--sandbox", "/tmp/sbq-flags", "--tick", "abc")]
    [InlineData("--daemon", "--sandbox", "/tmp/sbq-flags", "--bogus")]
    public void FlagMistake_ExitsWith64AndPrintsUsageToStandardError(params string[] arguments)
    {
        var result = Programs.Daemon(arguments);

        Assert.Equal(64, result.ExitCode);
        Assert.Contains("usage", result.StandardError, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("", result.StandardOutput);
    }

    [Fact]
    public void NoArguments_ExitsWith64()
    {
        Assert.Equal(64, Programs.Daemon().ExitCode);
    }

    [Fact]
    public void SecondDaemonOnTheSameSandbox_ExitsWithCode1AndTheFirstKeepsAnswering()
    {
        using var first = SandboxDaemon.Start();
        first.SetupAndAdd("reddit.com");

        var second = Programs.Run(Programs.DaemonDll, first.Arguments, timeoutSeconds: 20);

        Assert.Equal(1, second.ExitCode);
        Assert.False(first.Process.HasExited);
        Assert.Contains("reddit.com", first.Status().Blocked.Select(site => site.Domain));
    }

    [Fact]
    public void SecondDaemon_ExitsBeforeItSavesAnything()
    {
        // Corrected observation: the second copy's availability probe is a status request, and the first daemon enforces after every command, so the hosts file cannot tell
        // which process wrote it. state.json can: the first daemon (60-second tick) does not rewrite it on a status request, while a second copy that got past the check would
        // load the hand-set "uninstalling" flag below, clear it and save (06-windows.md § DaemonRuntime: the pipe check comes before any save or enforcement).
        using var first = SandboxDaemon.Start(tickSeconds: 60);
        first.SetupAndAdd("reddit.com");
        foreach (string path in new[] { first.StatePath, first.StateBackupPath })
        {
            var root = (JsonObject)JsonNode.Parse(File.ReadAllText(path))!;
            root["uninstalling"] = true;
            File.WriteAllText(path, root.ToJsonString());
        }
        string stateBefore = File.ReadAllText(first.StatePath);
        string backupBefore = File.ReadAllText(first.StateBackupPath);

        var second = Programs.Run(Programs.DaemonDll, first.Arguments, timeoutSeconds: 20);

        Assert.Equal(1, second.ExitCode);
        Assert.Equal(stateBefore, SandboxDaemon.ReadShared(first.StatePath));
        Assert.Equal(backupBefore, SandboxDaemon.ReadShared(first.StateBackupPath));
        Assert.False(first.Process.HasExited);
    }

    [UnixFact("Windows has no SIGTERM a test can send to a console child; the service stop request is covered by e2e.ps1")]
    public void Terminate_SavesTheStateAndExitsZero()
    {
        // A 60-second tick: no tick can rewrite the state files during the test, so only the stop itself can.
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");
        File.Delete(daemon.StatePath);
        File.Delete(daemon.StateBackupPath);

        daemon.SendTerminate();

        Assert.Equal(0, daemon.WaitForExit(10));
        Assert.True(File.Exists(daemon.StatePath), "the stop did not save state.json");
        var blocked = (JsonArray)daemon.StateJson()["blocked"]!;
        Assert.Equal("reddit.com", (string?)Assert.Single(blocked)!["domain"]);
    }

    [Fact]
    public void Restart_AfterAKill_KeepsTheBlocksAndRestoresAMissingStateFileFromTheBackup()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        daemon.KillHard();
        File.Delete(daemon.StatePath);

        daemon.Launch();
        daemon.WaitUntilReady();

        var status = daemon.Status();
        Assert.True(status.PasswordSet);
        Assert.Equal("reddit.com", Assert.Single(status.Blocked).Domain);
        Assert.True(Wait.Until(() => File.Exists(daemon.StatePath), 3));
    }

    // Folders that stand in for the real protected folders, under a fresh temp folder.
    private static (string Root, string[] Protected) FakeProtectedFolders()
    {
        string root = Path.Combine(Path.GetTempPath(), "sbq-prot-" + Guid.NewGuid().ToString("N")[..8]);
        return (root, [Path.Combine(root, "Windows", "System32", "drivers", "etc"), Path.Combine(root, "Program Files", "SiteBlock"), Path.Combine(root, "ProgramData", "SiteBlock")]);
    }

    [Fact]
    public void ProtectedFolderFor_SameInsideOrContainingAProtectedFolder_NamesIt()
    {
        var (root, folders) = FakeProtectedFolders();
        string hosts = folders[0];

        Assert.Equal(hosts, Program.ProtectedFolderFor(hosts, folders));
        Assert.Equal(hosts, Program.ProtectedFolderFor(hosts + Path.DirectorySeparatorChar, folders));
        Assert.Equal(hosts, Program.ProtectedFolderFor(Path.Combine(hosts, "box"), folders));
        Assert.Equal(hosts, Program.ProtectedFolderFor(Path.Combine(root, "Windows"), folders));
        Assert.Equal(hosts, Program.ProtectedFolderFor(Path.Combine(hosts, "..", "etc"), folders));
        Assert.Equal(folders[1], Program.ProtectedFolderFor(Path.Combine(folders[1], "test"), folders));
        Assert.Equal(folders[2], Program.ProtectedFolderFor(Path.Combine(root, "ProgramData"), folders));
        // A folder that contains all three (the drive root, in effect) names one of them.
        Assert.NotNull(Program.ProtectedFolderFor(root, folders));
    }

    [Fact]
    public void ProtectedFolderFor_SiblingsAndLookAlikeNames_AreAllowed()
    {
        var (root, folders) = FakeProtectedFolders();

        Assert.Null(Program.ProtectedFolderFor(Path.Combine(root, "Windows", "System32", "drivers", "etc2"), folders));
        Assert.Null(Program.ProtectedFolderFor(Path.Combine(root, "Program Files", "SiteBlockTest"), folders));
        Assert.Null(Program.ProtectedFolderFor(Path.Combine(root, "ProgramData", "SiteBlock-sandbox"), folders));
        Assert.Null(Program.ProtectedFolderFor(Path.Combine(root, "Temp", "sbq123"), folders));
    }

    [WindowsFact("Windows compares paths without regard to letter case; the rule applies to Windows folders only")]
    public void ProtectedFolderFor_DifferentLetterCase_StillMatchesOnWindows()
    {
        var (_, folders) = FakeProtectedFolders();

        Assert.Equal(folders[0], Program.ProtectedFolderFor(folders[0].ToUpperInvariant(), folders));
        Assert.Equal(folders[1], Program.ProtectedFolderFor(Path.Combine(folders[1].ToLowerInvariant(), "x"), folders));
    }

    [Fact]
    public void ProtectedFolderFor_TheDriveRoot_ContainsEverythingOnIt()
    {
        var (root, folders) = FakeProtectedFolders();

        Assert.NotNull(Program.ProtectedFolderFor(Path.GetPathRoot(root)!, folders));
    }

    [WindowsFact("the \\\\?\\ long-path prefix exists only on Windows")]
    public void ProtectedFolderFor_LongPathPrefix_IsIgnoredOnWindows()
    {
        var (_, folders) = FakeProtectedFolders();

        Assert.Equal(folders[0], Program.ProtectedFolderFor(@"\\?\" + folders[0], folders));
        Assert.Equal(folders[2], Program.ProtectedFolderFor(@"\\?\" + Path.Combine(folders[2], "box"), folders));
        Assert.Null(Program.ProtectedFolderFor(@"\\?\" + Path.Combine(Path.GetTempPath(), "sbq-long"), folders));
    }

    [WindowsFact("the real protected folders exist only on Windows")]
    public void Parse_ElevatedWithTheRealProtectedFolders_IsRefusedOnWindows()
    {
        string hostsFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "drivers", "etc");
        string programFiles = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "SiteBlock");
        string programData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SiteBlock");

        foreach (string folder in new[] { hostsFolder, Path.Combine(hostsFolder, "box"), programFiles, Path.Combine(programData, "state"), Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.Windows) })
        {
            Assert.Throws<UsageException>(() => Program.Parse(["--daemon", "--sandbox", folder], privileged: true));
            Assert.Throws<UsageException>(() => Program.Parse(["--daemon", "--sandbox", folder], privileged: false));
        }
    }

    [WindowsFact("elevated sandbox runs are allowed only on Windows")]
    public void Parse_ElevatedWithATempFolder_IsAllowedOnWindows()
    {
        string folder = Path.Combine(Path.GetTempPath(), "sbq-elevated");

        var options = Program.Parse(["--daemon", "--sandbox", folder, "--tick", "0.2", "--policy-fast"], privileged: true);

        Assert.Equal(Path.GetFullPath(folder), options.SandboxRoot);
        Assert.True(options.PolicyFast);
        Assert.Equal(0.2, options.TickSeconds);
    }

    [UnixFact("on Windows an elevated sandbox is allowed")]
    public void Parse_SandboxWhileRoot_IsRefusedOnMacAndLinux()
    {
        Assert.Throws<UsageException>(() => Program.Parse(["--daemon", "--sandbox", "/tmp/sbq-root"], privileged: true));
        var allowed = Program.Parse(["--daemon", "--sandbox", "/tmp/sbq-root"], privileged: false);
        Assert.Equal("/tmp/sbq-root", allowed.SandboxRoot);
    }

    [Fact]
    public void Parse_TickOrPolicyFastWithoutSandbox_IsRefusedEvenWhenPrivileged()
    {
        Assert.Throws<UsageException>(() => Program.Parse(["--daemon", "--tick", "1"], privileged: true));
        Assert.Throws<UsageException>(() => Program.Parse(["--daemon", "--policy-fast"], privileged: true));
    }
}

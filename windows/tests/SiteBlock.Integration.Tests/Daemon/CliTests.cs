using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// The real siteblock CLI against a real sandbox siteblockd through SITEBLOCK_PIPE, with passwords piped on standard input.
// Expected values: 03-daemon-cli-app.md § siteblock CLI (commands, exit codes 0/1/2/64, the status lines) and § Adult filter in the app and CLI,
// 06-windows.md § siteblock.exe CLI, 05-testing-and-operations.md § Integration Tests.
public sealed class CliTests
{
    private static string PasswordLines => Defaults.Password + "\n" + Defaults.Password + "\n";

    [Fact]
    public void Add_FirstTime_SetsThePasswordFromStandardInputThenBlocks()
    {
        using var daemon = SandboxDaemon.Start();

        var result = Programs.Cli(daemon.PipePath, ["add", "reddit.com"], PasswordLines);

        Assert.True(result.ExitCode == 0, result.StandardError);
        var status = daemon.Status();
        Assert.True(status.PasswordSet);
        Assert.Equal("reddit.com", Assert.Single(status.Blocked).Domain);
        Assert.Contains("0.0.0.0 reddit.com", daemon.HostsText().Split('\n'));
        // The piped password is the one that was set.
        var check = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 60, StartSeconds: 2));
        Assert.True(check.Ok, check.Error);
    }

    [Fact]
    public void Add_FirstTimeWithMismatchedConfirmation_ExitsOneAndSetsNothing()
    {
        using var daemon = SandboxDaemon.Start();

        var result = Programs.Cli(daemon.PipePath, ["add", "reddit.com"], Defaults.Password + "\nsomething-else\n");

        Assert.Equal(1, result.ExitCode);
        Assert.False(daemon.Status().PasswordSet);
        Assert.Empty(daemon.Status().Blocked);
    }

    [Fact]
    public void Status_PrintsTheVersionDelaySitesHostCountAndAdultFilterLine()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        string version = daemon.Status().Version;

        var result = Programs.Cli(daemon.PipePath, ["status"]);

        Assert.Equal(0, result.ExitCode);
        var lines = result.StandardOutput.Replace("\r\n", "\n").Split('\n');
        Assert.StartsWith($"SiteBlock {version} — unblock delay: 2 seconds", lines[0]);
        string siteLine = Assert.Single(lines, line => line.Contains("reddit.com", StringComparison.Ordinal));
        Assert.Contains(Expected.Expand("reddit.com").Count.ToString(System.Globalization.CultureInfo.InvariantCulture), siteLine);
        Assert.Contains("Adult content filter: always on", lines);
    }

    [Fact]
    public void Unblock_WithPipedPassword_StartsTheCountdownAndWrongPasswordExitsOne()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");

        var wrong = Programs.Cli(daemon.PipePath, ["unblock", "reddit.com"], "WrongPass-77\n");
        var right = Programs.Cli(daemon.PipePath, ["unblock", "reddit.com"], Defaults.Password + "\n");

        Assert.Equal(1, wrong.ExitCode);
        Assert.Contains("Wrong password", wrong.StandardError);
        Assert.True(right.ExitCode == 0, right.StandardError);
        Assert.NotNull(Assert.Single(daemon.Status().Blocked).UnblockSecondsRemaining);
    }

    [Fact]
    public void Unblock_WithEmptyStandardInput_IsAUsageErrorAndCostsNoTry()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");

        var result = Programs.Cli(daemon.PipePath, ["unblock", "reddit.com"], "\n");

        Assert.Equal(64, result.ExitCode);
        Assert.Equal(0L, (long)daemon.StateJson()["failedAttempts"]!);
        Assert.Null(Assert.Single(daemon.Status().Blocked).UnblockSecondsRemaining);
    }

    [Fact]
    public void Add_SeveralSitesWithOneInvalid_BlocksTheValidOnesAndExitsOne()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.Setup();

        var result = Programs.Cli(daemon.PipePath, ["add", "reddit.com", "not a site", "wikipedia.org"]);

        Assert.Equal(1, result.ExitCode);
        Assert.Equal(["reddit.com", "wikipedia.org"], daemon.Status().Blocked.Select(site => site.Domain).Order(StringComparer.Ordinal));
    }

    [Fact]
    public void AddPath_FromTheCli_BlocksOnlyThatPartAndStatusListsIt()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.Setup();

        var add = Programs.Cli(daemon.PipePath, ["add", "youtube.com/shorts"]);
        var status = Programs.Cli(daemon.PipePath, ["status"]);

        Assert.Equal(0, add.ExitCode);
        Assert.Empty(daemon.Status().Blocked);
        Assert.Equal("youtube.com/shorts", Assert.Single(daemon.Status().BlockedPaths!).Rule);
        Assert.Contains("Blocked parts of sites (1):", status.StandardOutput);
    }

    [Fact]
    public void TemporaryUnblock_FromTheCli_ShowsTheWaitingThenOpenLineAndCancelEndsIt()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        var schedule = Programs.Cli(daemon.PipePath, ["unblock", "reddit.com", "--for", "30s", "--in", "2s"], Defaults.Password + "\n");
        var waiting = Programs.Cli(daemon.PipePath, ["status"]);

        Assert.True(schedule.ExitCode == 0, schedule.StandardError);
        Assert.Contains("opens in", waiting.StandardOutput);
        Assert.Contains(", for 30s", waiting.StandardOutput);
        Assert.True(Wait.Until(() => Programs.Cli(daemon.PipePath, ["status"]).StandardOutput.Contains("OPEN — blocks again in", StringComparison.Ordinal), 8));
        Assert.DoesNotContain("0.0.0.0 reddit.com", daemon.HostsText().Split('\n'));

        var cancel = Programs.Cli(daemon.PipePath, ["cancel", "reddit.com"]);

        Assert.Equal(0, cancel.ExitCode);
        Assert.Contains("0.0.0.0 reddit.com", daemon.HostsText().Split('\n'));
        Assert.Null(Assert.Single(daemon.Status().Blocked).TemporaryUnblock);
    }

    [Fact]
    public void TemporaryUnblock_StartWaitShorterThanTheDelay_PrintsTheDaemonSentenceAndExitsOne()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");

        var result = Programs.Cli(daemon.PipePath, ["unblock", "reddit.com", "--for", "30s", "--in", "1s"], Defaults.Password + "\n");

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("It can't open sooner than your unblock delay of 2 seconds.", result.StandardError);
        Assert.Null(Assert.Single(daemon.Status().Blocked).TemporaryUnblock);
    }

    [Theory]
    [InlineData("unblock", "reddit.com", "--for", "soon")]
    [InlineData("unblock", "reddit.com", "--for", "1h30")]
    [InlineData("unblock", "reddit.com", "--in", "2h")]
    [InlineData("unblock", "reddit.com", "--for", "30m", "--for", "1h")]
    [InlineData("unblock", "reddit.com", "--for")]
    [InlineData("unblock")]
    [InlineData("frobnicate")]
    [InlineData("delay", "forever")]
    public void UsageMistakes_ExitWith64AndSendNothing(params string[] arguments)
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");

        // A wrong password is piped: if any of these reached the daemon with it, a wrong try would be counted.
        var result = Programs.Cli(daemon.PipePath, arguments, "WrongPass-77\n");

        Assert.Equal(64, result.ExitCode);
        Assert.Equal(0L, (long)daemon.StateJson()["failedAttempts"]!);
        var site = Assert.Single(daemon.Status().Blocked);
        Assert.Null(site.TemporaryUnblock);
        Assert.Null(site.UnblockSecondsRemaining);
        Assert.Equal(2L, daemon.Status().DelaySeconds);
    }

    [Fact]
    public void AnyCommand_WithNoDaemon_ExitsWith2()
    {
        string root = SandboxDaemon.NewRoot();
        try
        {
            string pipe = Path.Combine(root, "siteblock.pipe");

            var status = Programs.Cli(pipe, ["status"]);
            var add = Programs.Cli(pipe, ["add", "reddit.com"]);

            Assert.Equal(2, status.ExitCode);
            Assert.False(string.IsNullOrWhiteSpace(status.StandardError));
            Assert.Equal(2, add.ExitCode);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Version_WorksWithoutADaemonAndMatchesTheDaemonsVersion()
    {
        string root = SandboxDaemon.NewRoot();
        try
        {
            var version = Programs.Cli(Path.Combine(root, "siteblock.pipe"), ["version"]);
            var daemonVersion = Programs.Daemon("--version");

            Assert.Equal(0, version.ExitCode);
            Assert.Equal(daemonVersion.StandardOutput.Trim().Replace("siteblockd ", "siteblock ", StringComparison.Ordinal), version.StandardOutput.Trim());
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Recover_FromANonAdminTerminal_ExitsOneWithTheWindowsSentence()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();

        var result = Programs.Cli(daemon.PipePath, ["recover"]);

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("Open Terminal or PowerShell with \"Run as administrator\" and run siteblock recover.", result.StandardError);
        Assert.DoesNotContain("sudo", result.StandardError);
    }

    [Fact]
    public void Uninstall_FromTheCli_CountsDownAndTheDaemonExitsZero()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        var result = Programs.Cli(daemon.PipePath, ["uninstall"], Defaults.Password + "\n");

        Assert.True(result.ExitCode == 0, result.StandardError);
        Assert.Equal(0, daemon.WaitForExit(15));
        Assert.Null(Expected.SectionLines(daemon.HostsText()));
        Assert.DoesNotContain("reddit.com", daemon.HostsText());
    }
}

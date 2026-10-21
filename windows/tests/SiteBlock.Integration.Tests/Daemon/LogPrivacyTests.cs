using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// The daemon log never holds a password, a domain or a path rule, and a flood of rejected requests becomes summary lines.
// Expected values: 06-windows.md § What Is the Same on Both Systems item 7, 03-daemon-cli-app.md § Daemon Runtime (Logging and temporary unblock log lines),
// 05-testing-and-operations.md § Integration Tests.
public sealed class LogPrivacyTests
{
    // Text that must never reach the log: the password, every site and rule the session names, and pieces of them.
    private static readonly string[] Secrets = [Defaults.Password, "lantern", "reddit", "redd.it", "youtube", "/shorts", "Shorts", "wikipedia", "badsite", "invalid_host", "WrongPass-77"];

    [Fact]
    public void FullSession_LogsCommandsAndTemporaryUnblockLinesButNoPasswordDomainOrRule()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        // The rule's path is everything from the first "/" up to the "?" (02-core-components.md § PathRuleParser), so this is youtube.com/Shorts.
        Assert.True(daemon.Send(new Request(Command.AddPath, Domain: "https://www.youtube.com/Shorts?xyz=1")).Ok);
        Assert.True(daemon.Send(new Request(Command.Add, Domain: "wikipedia.org")).Ok);
        daemon.Send(new Request(Command.Unblock, Domain: "reddit.com", Password: "WrongPass-77"));
        daemon.Send(new Request(Command.Add, Domain: "invalid_host..badsite"));
        daemon.Send(new Request(Command.AddPath, Domain: "youtube.com/<script>"));
        Assert.True(daemon.Send(new Request(Command.TemporaryUnblock, Domain: "wikipedia.org", Password: Defaults.Password, Seconds: 1, StartSeconds: 2)).Ok);
        Assert.True(daemon.Send(new Request(Command.TemporaryUnblockPath, Domain: "youtube.com/Shorts", Password: Defaults.Password, Seconds: 60, StartSeconds: 600)).Ok);
        Assert.True(daemon.Send(new Request(Command.CancelUnblockPath, Domain: "youtube.com/Shorts")).Ok);
        Assert.True(daemon.Send(new Request(Command.Unblock, Domain: "reddit.com", Password: Defaults.Password)).Ok);
        Assert.True(daemon.Send(new Request(Command.ChangePassword, Password: Defaults.Password, NewPassword: Defaults.Password + "2")).Ok);

        // Positive controls: the log really records this session, including the temporary unblock lines.
        Assert.True(daemon.WaitForLogCount("temporary unblock ended; the site is blocked again", 1, 8), daemon.LogText());
        string log = daemon.LogText();
        Assert.Contains("temporary unblock approved", log);
        Assert.Contains("temporary unblock opened", log);
        Assert.Contains("temporary unblock cancelled", log);
        Assert.Contains("command add", log);
        Assert.Contains("command unblock", log);

        foreach (string secret in Secrets.Append(Defaults.Password + "2"))
        {
            Assert.DoesNotContain(secret, log, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(secret, daemon.StandardError, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void FloodOfRejectedRequests_IsNotLoggedOneLinePerRequest()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.Setup();
        int linesBefore = daemon.LogText().Split('\n', StringSplitOptions.RemoveEmptyEntries).Length;

        // Each request is retried only while the connection is closed without any reply: 80 back-to-back connections from one user can meet a slot the server has not
        // released yet (it frees a slot once it sees the previous client hang up), and on a loaded machine that took longer than SendPatiently's 2 seconds, which made this
        // test fail with "a reply that could not be understood" although nothing was logged wrongly. Every request still gets its refusal, which is now checked too.
        for (int i = 0; i < 60; i++) Assert.Equal(ErrorCode.InvalidDomain, Patiently(() => daemon.Client().Send(new Request(Command.Add, Domain: $"bad name {i}"))).ErrorCode);
        for (int i = 0; i < 20; i++) Assert.Equal("badRequest", (string?)Patiently(() => RawConnection.Exchange(daemon.PipePath, "{nonsense"))["errorCode"]);
        Thread.Sleep(500);

        // A summary line per minute at most: 80 rejections add far fewer than 80 lines (startup chatter and one summary are allowed).
        int added = daemon.LogText().Split('\n', StringSplitOptions.RemoveEmptyEntries).Length - linesBefore;
        Assert.True(added < 10, $"{added} log lines for 80 rejected requests:\n{daemon.LogText()}");
        Assert.DoesNotContain("bad name", daemon.LogText());
        // Control: an accepted command is logged by name.
        Assert.True(Patiently(() => daemon.Client().Send(new Request(Command.Add, Domain: "example.org"))).Ok);
        Assert.True(daemon.WaitForLogCount("command add", 1));
    }

    // Runs one exchange, trying again (for up to 10 seconds) only when the connection was closed without a reply, which is how the server turns away a connection over the
    // per-user limit. Any reply, and any other failure, ends the retries.
    private static T Patiently<T>(Func<T> exchange)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            try { return exchange(); }
            catch (DaemonClientException error) when (error.Error == ClientError.BadResponse && clock.Elapsed < TimeSpan.FromSeconds(10)) { }
            catch (Xunit.Sdk.XunitException error) when (error.Message.StartsWith("no reply to", StringComparison.Ordinal) && clock.Elapsed < TimeSpan.FromSeconds(10)) { }
            Thread.Sleep(50);
        }
    }
}

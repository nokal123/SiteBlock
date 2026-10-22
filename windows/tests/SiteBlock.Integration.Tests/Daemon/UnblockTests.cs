using System.Diagnostics;
using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// Passwords, the unblock countdown, lockout and temporary unblocks through a real sandbox siteblockd under --policy-fast
// (unblock delay 2 s, lockout 2 s, shortest temporary window 1 s, 5 tries).
// Expected values: 01-overview-and-data.md § Commands and § Fixed Policy Values, 02-core-components.md § Engine (password check rule, temporary unblock checks and tick rule),
// 03-daemon-cli-app.md § Daemon Runtime (temporary unblock log lines), 05-testing-and-operations.md § Integration Tests.
public sealed class UnblockTests
{
    private const string WrongPassword = "not-the-password";

    private static Response Unblock(SandboxDaemon daemon, string password) => daemon.Send(new Request(Command.Unblock, Domain: "reddit.com", Password: password));

    private static bool HostsBlockReddit(SandboxDaemon daemon) => daemon.HostsText().Split('\n').Contains("0.0.0.0 reddit.com");

    // The Chrome block list in registry.json, or an empty list when the subkey is gone.
    private static List<string> ChromeList(SandboxDaemon daemon) => Expected.List(daemon.Registry(), Expected.Blocklist(Expected.ChromeKey)) ?? [];

    [Fact]
    public void Unblock_RightPassword_KeepsTheSiteForTheWholeDelayThenRemovesItNeverEarly()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        var clock = Stopwatch.StartNew();

        var response = Unblock(daemon, Defaults.Password);

        Assert.True(response.Ok, response.Error);
        Assert.NotNull(Assert.Single(response.Status!.Blocked).UnblockSecondsRemaining);
        Assert.True(HostsBlockReddit(daemon));
        Assert.True(Wait.Until(() => !HostsBlockReddit(daemon), 10), "the site was never removed");
        // The removal was seen after it happened, and it happened at least 2 s after the request reached the daemon, which was after the clock started.
        Assert.True(clock.Elapsed >= TimeSpan.FromSeconds(1.95), $"removed after only {clock.Elapsed.TotalSeconds:0.000} s");
        Assert.Empty(daemon.Status().Blocked);
        Assert.Null(Expected.Key(daemon.Registry(), Expected.Blocklist(Expected.ChromeKey)));
        // The always-blocked names stay while SiteBlock is installed.
        Assert.Equal(Expected.SectionFor([]), Expected.SectionLines(daemon.HostsText()));
    }

    [Fact]
    public void Unblock_WrongPassword_IsRefusedAndTheSiteStays()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        var response = Unblock(daemon, WrongPassword);

        Assert.Equal(ErrorCode.WrongPassword, response.ErrorCode);
        Assert.Contains("4 tries left", response.Error);
        Thread.Sleep(2600);
        Assert.True(HostsBlockReddit(daemon));
        Assert.Null(Assert.Single(daemon.Status().Blocked).UnblockSecondsRemaining);
    }

    [Fact]
    public void WrongPasswords_CountDownToOneTryThenLockOutAndRefuseEvenTheRightPassword()
    {
        // The test policy's lockout lasts only 2 seconds, so on a busy machine it can end before the right password is even sent, and the service then rightly accepts it.
        // An attempt counts only when the fifth wrong password and the right one were both answered within LockoutWindow; otherwise it is repeated with a fresh service.
        for (int attempt = 1; ; attempt++)
        {
            using var daemon = SandboxDaemon.Start(tickSeconds: 60);
            daemon.SetupAndAdd("reddit.com");

            var messages = Enumerable.Range(0, 4).Select(_ => Unblock(daemon, WrongPassword)).ToList();
            var clock = Stopwatch.StartNew();
            messages.Add(Unblock(daemon, WrongPassword));
            var locked = Unblock(daemon, Defaults.Password);
            if (clock.Elapsed > LockoutWindow && attempt < 3) continue;

            Assert.All(messages, message => Assert.Equal(ErrorCode.WrongPassword, message.ErrorCode));
            Assert.Contains("4 tries left", messages[0].Error);
            Assert.Contains("1 try left", messages[3].Error);
            Assert.True(clock.Elapsed <= LockoutWindow, $"no attempt sent the right password while the 2-second lockout was surely still running (last took {clock.Elapsed.TotalSeconds:0.00} s)");
            Assert.Equal(ErrorCode.LockedOut, locked.ErrorCode);
            Assert.NotNull(daemon.Status().LockoutSecondsRemaining);
            Assert.Null(Assert.Single(daemon.Status().Blocked).UnblockSecondsRemaining);
            return;
        }
    }

    // How long the fifth wrong password and the next request may take together for the 2-second test lockout to be certainly still running when the next request is checked.
    private static readonly TimeSpan LockoutWindow = TimeSpan.FromSeconds(1.5);

    [Fact]
    public void Lockout_EndsAfterItsTimeAndTheRightPasswordWorksAgain()
    {
        // As above, the refusal during the lockout is judged only on an attempt that reached it within LockoutWindow; a slower attempt is repeated with a fresh service.
        for (int attempt = 1; ; attempt++)
        {
            using var daemon = SandboxDaemon.Start();
            daemon.SetupAndAdd("reddit.com");
            for (int i = 0; i < 4; i++) Unblock(daemon, WrongPassword);
            var clock = Stopwatch.StartNew();
            Unblock(daemon, WrongPassword);
            var duringLockout = Unblock(daemon, Defaults.Password);
            if (clock.Elapsed > LockoutWindow && attempt < 3) continue;
            Assert.True(clock.Elapsed <= LockoutWindow, $"no attempt reached the lockout while it was surely still running (last took {clock.Elapsed.TotalSeconds:0.00} s)");
            Assert.Equal(ErrorCode.LockedOut, duringLockout.ErrorCode);

            Thread.Sleep(2500);

            Assert.True(Unblock(daemon, Defaults.Password).Ok);
            return;
        }
    }

    [Fact]
    public void Lockout_SurvivesAKillAndRestart()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        for (int i = 0; i < 5; i++) Unblock(daemon, WrongPassword);

        daemon.KillHard();
        daemon.Launch();
        daemon.WaitUntilReady();

        Assert.Equal(ErrorCode.LockedOut, Unblock(daemon, Defaults.Password).ErrorCode);
    }

    [Fact]
    public void TemporaryUnblock_StartWaitShorterThanTheDelay_IsRefusedWithoutCostingAPasswordTry()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");
        // Four wrong passwords leave exactly one try.
        for (int i = 0; i < 4; i++) Unblock(daemon, WrongPassword);

        var refused = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: WrongPassword, Seconds: 5, StartSeconds: 1));

        Assert.Equal(ErrorCode.InvalidDuration, refused.ErrorCode);
        Assert.Contains("It can't open sooner than your unblock delay of 2 seconds.", refused.Error);
        // Had the refusal counted, this right password would meet a lockout.
        var accepted = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 5, StartSeconds: 2));
        Assert.True(accepted.Ok, accepted.Error);
        Assert.Equal(0L, (long)daemon.StateJson()["failedAttempts"]!);
    }

    [Fact]
    public void TemporaryUnblock_WindowOutOfRangeOrSiteNotBlocked_IsRefusedBeforeThePasswordEvenDuringALockout()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");
        for (int i = 0; i < 5; i++) Unblock(daemon, WrongPassword);

        var tooLong = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: WrongPassword, Seconds: 14_401));
        var tooShort = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: WrongPassword, Seconds: 0));
        var notBlocked = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "example.org", Password: WrongPassword, Seconds: 60));
        var missingWindow = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: WrongPassword));
        var valid = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 60));

        Assert.Equal(ErrorCode.InvalidDuration, tooLong.ErrorCode);
        Assert.Contains("It can't stay open for more than 4 hours.", tooLong.Error);
        Assert.Equal(ErrorCode.InvalidDuration, tooShort.ErrorCode);
        Assert.Contains("It must stay open for at least 1 second.", tooShort.Error);
        Assert.Equal(ErrorCode.NotBlocked, notBlocked.ErrorCode);
        Assert.Equal(ErrorCode.BadRequest, missingWindow.ErrorCode);
        // Only a request that passes every check meets the lockout.
        Assert.Equal(ErrorCode.LockedOut, valid.ErrorCode);
    }

    [Fact]
    public void TemporaryUnblock_StaysBlockedDuringTheStartWaitOpensForTheWindowThenBlocksAgainWithLogLines()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        var clock = Stopwatch.StartNew();

        var response = daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 2, StartSeconds: 2));

        Assert.True(response.Ok, response.Error);
        Assert.Equal("reddit.com opens in 2 seconds, for 2 seconds, then blocks again.", response.Message);
        var temporary = Assert.Single(response.Status!.Blocked).TemporaryUnblock!;
        Assert.False(temporary.IsOpen);
        Assert.Equal(2L, temporary.WindowSeconds);
        // During the start wait the lines and entries stay.
        Assert.True(HostsBlockReddit(daemon));
        Assert.Contains("reddit.com", ChromeList(daemon));

        Assert.True(Wait.Until(() => !HostsBlockReddit(daemon), 6), "the site never opened");
        Assert.True(clock.Elapsed >= TimeSpan.FromSeconds(1.95), $"opened after only {clock.Elapsed.TotalSeconds:0.000} s");
        // The hosts file is written first in a pass and the browser lists after it, so the lists are awaited too.
        Assert.True(Wait.Until(() => !ChromeList(daemon).Contains("reddit.com") && !(Expected.List(daemon.Registry(), Expected.FirefoxBlockKey) ?? []).Contains("*://*.reddit.com/*"), 3), daemon.Registry().ToJsonString());
        // The always-blocked names stay while the site is open.
        Assert.Contains("0.0.0.0 mask.icloud.com", daemon.HostsText().Split('\n'));

        Assert.True(Wait.Until(() => HostsBlockReddit(daemon), 6), "the site was never blocked again");
        Assert.True(clock.Elapsed >= TimeSpan.FromSeconds(3.9), $"blocked again after only {clock.Elapsed.TotalSeconds:0.000} s");
        Assert.Equal(Expected.SectionFor(Expected.Expand("reddit.com")), Expected.SectionLines(daemon.HostsText()));
        Assert.True(Wait.Until(() => ChromeList(daemon).Contains("reddit.com") && (Expected.List(daemon.Registry(), Expected.FirefoxBlockKey) ?? []).Contains("*://*.reddit.com/*"), 3), daemon.Registry().ToJsonString());
        Assert.Null(Assert.Single(daemon.Status().Blocked).TemporaryUnblock);
        Assert.True(daemon.WaitForLogCount("temporary unblock ended; the site is blocked again", 1), daemon.LogText());
        Assert.Equal(1, daemon.LogCount("temporary unblock approved: opens in 2 seconds for 2 seconds"));
        Assert.Equal(1, daemon.LogCount("temporary unblock opened"));
    }

    [Fact]
    public void TemporaryUnblockPath_RuleLeavesAndReturnsToTheBrowserListsOnly()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.Setup();
        Assert.True(daemon.Send(new Request(Command.AddPath, Domain: "youtube.com/shorts")).Ok);

        var response = daemon.Send(new Request(Command.TemporaryUnblockPath, Domain: "youtube.com/shorts", Password: Defaults.Password, Seconds: 2, StartSeconds: 2));

        Assert.True(response.Ok, response.Error);
        Assert.Equal(["youtube.com/shorts"], ChromeList(daemon));
        Assert.True(Wait.Until(() => ChromeList(daemon).Count == 0, 6), "the rule never opened");
        // Firefox is written after Chrome in the same pass.
        Assert.True(Wait.Until(() => Expected.Key(daemon.Registry(), Expected.FirefoxBlockKey) is null, 3), daemon.Registry().ToJsonString());
        Assert.True(Wait.Until(() => ChromeList(daemon).SequenceEqual(["youtube.com/shorts"]), 6), "the rule was never blocked again");
        // One pass writes the four browsers one after another, so Firefox may land a moment after Chrome.
        Assert.True(Wait.Until(() => (Expected.List(daemon.Registry(), Expected.FirefoxBlockKey) ?? []).SequenceEqual(["*://*.youtube.com/shorts*"]), 3), daemon.Registry().ToJsonString());
        Assert.DoesNotContain("youtube", daemon.HostsText());
    }

    [Fact]
    public void CancelUnblock_OnAWaitingTemporaryUnblock_NeedsNoPasswordAndKeepsTheSiteBlocked()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");
        Assert.True(daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 60, StartSeconds: 600)).Ok);

        var response = daemon.Send(new Request(Command.CancelUnblock, Domain: "reddit.com"));

        Assert.True(response.Ok, response.Error);
        Assert.Equal("The temporary unblock is cancelled; reddit.com stays blocked.", response.Message);
        Assert.Null(Assert.Single(response.Status!.Blocked).TemporaryUnblock);
        Assert.True(HostsBlockReddit(daemon));
        Assert.True(daemon.WaitForLogCount("temporary unblock cancelled", 1));
    }

    [Fact]
    public void CancelUnblock_OnAnOpenTemporaryUnblock_PutsTheLinesBackBeforeTheReply()
    {
        // A 1-second tick lets the start wait pass on its own; the cancel then gets no help from a timer before its reply.
        using var daemon = SandboxDaemon.Start(tickSeconds: 1);
        daemon.SetupAndAdd("reddit.com");
        Assert.True(daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 600, StartSeconds: 2)).Ok);
        Assert.True(Wait.Until(() => !HostsBlockReddit(daemon), 8), "the site never opened");

        var response = daemon.Send(new Request(Command.CancelUnblock, Domain: "reddit.com"));

        Assert.True(response.Ok, response.Error);
        Assert.Equal("reddit.com is blocked again.", response.Message);
        Assert.True(HostsBlockReddit(daemon));
        Assert.Contains("reddit.com", ChromeList(daemon));
        Assert.True(daemon.WaitForLogCount("temporary unblock ended early", 1));
    }

    [Fact]
    public void Add_OnASiteWithAnOpenTemporaryUnblock_BlocksItAgainWithoutAPassword()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 1);
        daemon.SetupAndAdd("reddit.com");
        Assert.True(daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 600, StartSeconds: 2)).Ok);
        Assert.True(Wait.Until(() => !HostsBlockReddit(daemon), 8), "the site never opened");

        var response = daemon.Send(new Request(Command.Add, Domain: "reddit.com"));

        Assert.True(response.Ok, response.Error);
        Assert.Equal("reddit.com is blocked again.", response.Message);
        Assert.True(HostsBlockReddit(daemon));
    }

    [Fact]
    public void Unblock_OnASiteWithATemporaryUnblock_IsAlreadyPendingAndCostsNoTry()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");
        Assert.True(daemon.Send(new Request(Command.TemporaryUnblock, Domain: "reddit.com", Password: Defaults.Password, Seconds: 60, StartSeconds: 600)).Ok);

        var response = Unblock(daemon, WrongPassword);

        Assert.Equal(ErrorCode.AlreadyPending, response.ErrorCode);
        Assert.Equal("reddit.com has a temporary unblock. Keep it blocked first if you want to unblock it for good.", response.Error);
        Assert.Equal(0L, (long)daemon.StateJson()["failedAttempts"]!);
    }

    [Fact]
    public void Uninstall_AfterItsWait_RestoresHostsRegistryAndDnsKeepsForeignValuesAndExitsZero()
    {
        using var daemon = SandboxDaemon.Start(prepare: d =>
        {
            File.WriteAllText(d.NetworkServicesPath, """{ "{22222222-2222-2222-2222-222222222222}": { "name": "Wi-Fi", "servers": ["192.168.1.1"] }, "{11111111-1111-1111-1111-111111111111}": { "name": "Ethernet", "servers": [] } }""");
            File.WriteAllText(d.RegistryPath, """
                {
                  "SOFTWARE\\Policies\\Google\\Chrome": { "HomepageLocation": { "type": "string", "value": "https://intranet.example.org" } },
                  "SOFTWARE\\Policies\\Mozilla\\Firefox\\WebsiteFilter\\Exceptions": { "1": { "type": "string", "value": "https://intranet.example.org/*" } }
                }
                """);
        });
        daemon.SetupAndAdd("reddit.com");
        Assert.True(daemon.Send(new Request(Command.AddPath, Domain: "youtube.com/shorts")).Ok);
        Assert.True(Wait.Until(() => daemon.StateJson()["savedDNS"] is JsonObject { Count: 2 }, 5), "the DNS servers were never overridden");

        var response = daemon.Send(new Request(Command.Uninstall, Password: Defaults.Password));

        Assert.True(response.Ok, response.Error);
        // Under --policy-fast both the uninstall minimum and the delay are 2 seconds.
        Assert.Equal(0, daemon.WaitForExit(15));
        Assert.Equal(SandboxDaemon.StartingHosts, daemon.HostsText());
        var registry = daemon.Registry();
        Expected.AssertValue(registry, Expected.ChromeKey, "HomepageLocation", "string", "\"https://intranet.example.org\"");
        Assert.Single(Expected.Key(registry, Expected.ChromeKey)!);
        Assert.Null(Expected.Key(registry, Expected.Blocklist(Expected.ChromeKey)));
        // Keys SiteBlock emptied are deleted; the person's own Firefox exceptions stay.
        Assert.Null(Expected.Key(registry, Expected.EdgeKey));
        Assert.Null(Expected.Key(registry, Expected.Blocklist(Expected.EdgeKey)));
        Assert.Null(Expected.Key(registry, Expected.BraveKey));
        Assert.Null(Expected.Key(registry, Expected.FirefoxDnsKey));
        Assert.Null(Expected.Key(registry, Expected.FirefoxBlockKey));
        Expected.AssertValue(registry, Expected.FirefoxKey + @"\WebsiteFilter\Exceptions", "1", "string", "\"https://intranet.example.org/*\"");
        var services = daemon.NetworkServices();
        Assert.Equal(["192.168.1.1"], ((JsonArray)services["{22222222-2222-2222-2222-222222222222}"]!["servers"]!).Select(server => (string)server!));
        Assert.Empty((JsonArray)services["{11111111-1111-1111-1111-111111111111}"]!["servers"]!);
        Assert.False(File.Exists(daemon.PipePath));
    }
}

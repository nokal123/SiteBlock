using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// A real sandbox siteblockd, checked through the files it writes: the sandbox hosts file, registry.json and network-services.json.
// Expected values: 05-testing-and-operations.md § Integration Tests, 06-windows.md § SiteBlock.Core (browser policy rules), § BrowserPolicyEnforcer, § DNSEnforcer,
// 01-overview-and-data.md § Wire Protocol and § Fixed Policy Values, 02-core-components.md § DomainExpander and § HostsFileEditor.
public sealed class BlockingTests
{
    [Fact]
    public void Add_FirstSiteAfterSetup_WritesEveryExpandedHostAndAlwaysBlockedNameBeforeTheReply()
    {
        // A 60-second tick means no timer runs during the test, so only the command itself can have written the file.
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();

        var response = daemon.Send(new Request(Command.Add, Domain: "reddit.com"));

        Assert.True(response.Ok, response.Error);
        string hosts = daemon.HostsText();
        Assert.Equal(Expected.SectionFor(Expected.Expand("reddit.com")), Expected.SectionLines(hosts));
        Assert.Contains("0.0.0.0 i.redd.it", hosts.Split('\n'));
        Assert.Contains(":: www.redd.it", hosts.Split('\n'));
        // The person's own lines stay, above the section.
        Assert.StartsWith(SandboxDaemon.StartingHosts, hosts);
        var site = Assert.Single(response.Status!.Blocked);
        Assert.Equal("reddit.com", site.Domain);
        Assert.Equal(Expected.Expand("reddit.com"), site.Hosts);
    }

    [Fact]
    public void Add_YoutubeWithTypedUrl_BlocksTheNormalizedSiteAndEveryYoutubeName()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();

        var response = daemon.Send(new Request(Command.Add, Domain: "https://www.YouTube.com/watch?v=abc"));

        Assert.True(response.Ok, response.Error);
        Assert.Equal("youtube.com", Assert.Single(response.Status!.Blocked).Domain);
        var section = Expected.SectionLines(daemon.HostsText())!;
        foreach (string host in new[] { "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be", "m.youtu.be", "i.ytimg.com", "yt3.ggpht.com" })
        {
            Assert.Contains($"0.0.0.0 {host}", section);
            Assert.Contains($":: {host}", section);
        }
        Assert.Equal(Expected.SectionFor(Expected.Expand("youtube.com")), section);
    }

    [Fact]
    public void Add_WithoutAPassword_IsRefusedWithNotSetUpAndWritesNoSiteLines()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        var response = daemon.Send(new Request(Command.Add, Domain: "reddit.com"));

        Assert.False(response.Ok);
        Assert.Equal(ErrorCode.NotSetUp, response.ErrorCode);
        Assert.DoesNotContain("reddit.com", daemon.HostsText());
    }

    [Fact]
    public void Startup_BeforeAnyPassword_WritesTheAdultFilterValuesOfAllFourBrowsersAndNoBlockLists()
    {
        using var daemon = SandboxDaemon.Start();

        var registry = daemon.Registry();

        Expected.AssertAdultFilterValues(registry);
        // An empty list's subkey is left out.
        Assert.Null(Expected.Key(registry, Expected.Blocklist(Expected.ChromeKey)));
        Assert.Null(Expected.Key(registry, Expected.Blocklist(Expected.EdgeKey)));
        Assert.Null(Expected.Key(registry, Expected.Blocklist(Expected.BraveKey)));
        Assert.Null(Expected.Key(registry, Expected.FirefoxBlockKey));
        // Edge gets strict Bing SafeSearch instead of SafeSites; Chrome and Brave get no Bing value.
        Assert.Null(Expected.Value(Expected.Key(registry, Expected.EdgeKey), "SafeSitesFilterBehavior"));
        Assert.Null(Expected.Value(Expected.Key(registry, Expected.ChromeKey), "ForceBingSafeSearch"));
        Assert.Null(Expected.Value(Expected.Key(registry, Expected.BraveKey), "ForceBingSafeSearch"));
    }

    [Fact]
    public void Add_Reddit_WritesTheCoveringListToEveryBrowserBeforeTheReply()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("reddit.com");

        var registry = daemon.Registry();

        // The shortest list that covers every reddit.com host, sorted by code point ('.' sorts before letters, so redd.it comes first).
        string[] chrome = ["redd.it", "reddit.com", "redditmedia.com", "redditstatic.com"];
        Assert.Equal(chrome, Expected.List(registry, Expected.Blocklist(Expected.ChromeKey)));
        Assert.Equal(chrome, Expected.List(registry, Expected.Blocklist(Expected.EdgeKey)));
        Assert.Equal(chrome, Expected.List(registry, Expected.Blocklist(Expected.BraveKey)));
        Assert.Equal(["*://*.redd.it/*", "*://*.reddit.com/*", "*://*.redditmedia.com/*", "*://*.redditstatic.com/*"], Expected.List(registry, Expected.FirefoxBlockKey));
        Expected.AssertAdultFilterValues(registry);
    }

    [Fact]
    public void AddPath_YoutubeShorts_GoesIntoTheBrowserListsOnlyAndLeavesTheHostsFileWithoutYoutube()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();

        // Corrected test input: the design's split keeps everything from the first "/" (so ".../shorts/abc" is the rule /shorts/abc); a query is cut and a trailing "/" removed, which gives /shorts.
        var response = daemon.Send(new Request(Command.AddPath, Domain: "https://www.YouTube.com/shorts/?feature=share"));

        Assert.True(response.Ok, response.Error);
        var rule = Assert.Single(response.Status!.BlockedPaths!);
        Assert.Equal("youtube.com/shorts", rule.Rule);
        Assert.DoesNotContain("youtube", daemon.HostsText());
        var registry = daemon.Registry();
        Assert.Equal(["youtube.com/shorts"], Expected.List(registry, Expected.Blocklist(Expected.ChromeKey)));
        Assert.Equal(["youtube.com/shorts"], Expected.List(registry, Expected.Blocklist(Expected.EdgeKey)));
        Assert.Equal(["*://*.youtube.com/shorts*"], Expected.List(registry, Expected.FirefoxBlockKey));
    }

    [Fact]
    public void Add_HostileDomainTextSentAsRawJson_IsRefusedAndAddsNoLine()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();
        string before = daemon.HostsText();

        foreach (string hostile in new[] { "evil.com\\n0.0.0.0 bank.com", "evil.com #bank.com", "evil com", "evil.com\\u0000bank.com", "evil.com\\tbank.com" })
        {
            var reply = RawConnection.Exchange(daemon.PipePath, $"{{\"command\":\"add\",\"domain\":\"{hostile}\"}}");
            Assert.False((bool)reply["ok"]!, hostile);
            Assert.Equal("invalidDomain", (string?)reply["errorCode"]);
        }

        Assert.Equal(before, daemon.HostsText());
        Assert.DoesNotContain("bank.com", daemon.HostsText());
        Assert.Null(Expected.Key(daemon.Registry(), Expected.Blocklist(Expected.ChromeKey)));
    }

    [Fact]
    public void Add_TwentyFirstSiteUnderTheFastPolicy_IsRefusedWithTooManySites()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();
        for (int i = 1; i <= 20; i++) Assert.True(daemon.Send(new Request(Command.Add, Domain: $"site{i}.example.com")).Ok);

        var response = daemon.Send(new Request(Command.Add, Domain: "site21.example.com"));

        Assert.Equal(ErrorCode.TooManySites, response.ErrorCode);
        Assert.DoesNotContain("site21.example.com", daemon.HostsText());
    }

    [Fact]
    public void RecoveryStart_FromTheSandboxCaller_IsRefusedWithTheWindowsSentence()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.Setup();

        var reply = RawConnection.Exchange(daemon.PipePath, "{\"command\":\"recoveryStart\"}");

        Assert.Equal("notRoot", (string?)reply["errorCode"]);
        Assert.Equal("Password recovery can only be started by an administrator. Open Terminal or PowerShell with \"Run as administrator\" and run siteblock recover.", (string?)reply["error"]);
        Assert.Null(daemon.Status().RecoverySecondsRemaining);
    }

    // Writes network-services.json with a plain adapter that takes the network's servers, one with hand-set servers, and a VPN that must be left alone.
    private static void WriteAdapters(SandboxDaemon daemon) => File.WriteAllText(daemon.NetworkServicesPath, """
        {
          "{11111111-1111-1111-1111-111111111111}": { "name": "Ethernet", "servers": [] },
          "{22222222-2222-2222-2222-222222222222}": { "name": "Wi-Fi", "servers": ["192.168.1.1", "fd00::1"] },
          "{33333333-3333-3333-3333-333333333333}": { "name": "Corp", "description": "WireGuard Tunnel", "servers": ["10.8.0.1"] }
        }
        """);

    // The servers of one adapter in network-services.json.
    private static List<string> ServersOf(JsonObject services, string id) => ((JsonArray)services[id]!["servers"]!).Select(server => (string)server!).ToList();

    [Fact]
    public void Startup_WithAdapters_SetsTheFamilyServersAndSavesEachOriginalButLeavesTheVpnAlone()
    {
        using var daemon = SandboxDaemon.Start(prepare: WriteAdapters);
        // Any command but status runs a DNS pass; the startup pass may already have run.
        daemon.Send(new Request(Command.CancelDelayChange));

        Assert.True(Wait.Until(() => ServersOf(daemon.NetworkServices(), "{22222222-2222-2222-2222-222222222222}").SequenceEqual(Expected.FamilyServers), 5), daemon.NetworkServices().ToJsonString());
        var services = daemon.NetworkServices();
        Assert.Equal(Expected.FamilyServers, ServersOf(services, "{11111111-1111-1111-1111-111111111111}"));
        Assert.Equal(["10.8.0.1"], ServersOf(services, "{33333333-3333-3333-3333-333333333333}"));
        // savedDNS is keyed by adapter GUID and holds the servers each adapter had before; an adapter with none saves an empty list.
        Assert.True(Wait.Until(() => daemon.StateJson()["savedDNS"] is JsonObject, 5));
        var saved = (JsonObject)daemon.StateJson()["savedDNS"]!;
        Assert.Equal(2, saved.Count);
        Assert.Empty((JsonArray)saved["{11111111-1111-1111-1111-111111111111}"]!);
        Assert.Equal(["192.168.1.1", "fd00::1"], ((JsonArray)saved["{22222222-2222-2222-2222-222222222222}"]!).Select(server => (string)server!));
        Assert.False(saved.ContainsKey("{33333333-3333-3333-3333-333333333333}"));
    }

    [Fact]
    public void FamilyDnsUnreachableMarker_LeavesAdaptersAloneThenFallsBackToTheSavedServersAfterTheyWereOverridden()
    {
        // The marker exists from the start: the family servers count as unreachable, so nothing is overridden.
        using var daemon = SandboxDaemon.Start(prepare: d => { WriteAdapters(d); File.WriteAllText(d.UnreachableMarkerPath, ""); });
        Thread.Sleep(1500);
        daemon.Send(new Request(Command.CancelDelayChange));
        Assert.Equal(["192.168.1.1", "fd00::1"], ServersOf(daemon.NetworkServices(), "{22222222-2222-2222-2222-222222222222}"));
        Assert.Empty(ServersOf(daemon.NetworkServices(), "{11111111-1111-1111-1111-111111111111}"));

        // Once the family servers answer, every managed adapter gets them.
        File.Delete(daemon.UnreachableMarkerPath);
        Assert.True(Wait.Until(() => ServersOf(daemon.NetworkServices(), "{22222222-2222-2222-2222-222222222222}").SequenceEqual(Expected.FamilyServers), 5));
        int unreachableLines = daemon.LogCount("family DNS unreachable");

        // Sign-in Wi-Fi again: after the failed checks the saved servers go back, and savedDNS is kept for the uninstaller.
        File.WriteAllText(daemon.UnreachableMarkerPath, "");
        Assert.True(Wait.Until(() => ServersOf(daemon.NetworkServices(), "{22222222-2222-2222-2222-222222222222}").SequenceEqual(["192.168.1.1", "fd00::1"]), 8), daemon.NetworkServices().ToJsonString());
        Assert.Empty(ServersOf(daemon.NetworkServices(), "{11111111-1111-1111-1111-111111111111}"));
        Assert.Equal(["10.8.0.1"], ServersOf(daemon.NetworkServices(), "{33333333-3333-3333-3333-333333333333}"));
        Assert.True(daemon.WaitForLogCount("family DNS unreachable", unreachableLines + 1));
        var saved = daemon.StateJson()["savedDNS"] as JsonObject;
        Assert.NotNull(saved);
        Assert.Equal(["192.168.1.1", "fd00::1"], ((JsonArray)saved!["{22222222-2222-2222-2222-222222222222}"]!).Select(server => (string)server!));
    }
}

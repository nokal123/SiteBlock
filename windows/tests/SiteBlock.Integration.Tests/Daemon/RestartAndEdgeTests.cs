using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// Restarts, hand-edited state and awkward starting files. Expected values: 03-daemon-cli-app.md § Daemon Runtime (startup step 3, save rules) and § DNSEnforcer (first saved value kept,
// "DNS settings repaired"), 02-core-components.md § HostsFileEditor (line breaks), 01-overview-and-data.md § Fixed Policy Values (save interval 2 s under --policy-fast),
// 05-testing-and-operations.md § Integration Tests, 06-windows.md § HostsEnforcer (the written file keeps \n line endings) and § BrowserPolicyEnforcer.
public sealed class RestartAndEdgeTests
{
    // Edits both state files (primary and backup) the same way while the daemon is stopped.
    private static void EditBothStateFiles(SandboxDaemon daemon, Action<JsonObject> edit)
    {
        foreach (string path in new[] { daemon.StatePath, daemon.StateBackupPath })
        {
            var root = (JsonObject)JsonNode.Parse(File.ReadAllText(path))!;
            edit(root);
            File.WriteAllText(path, root.ToJsonString());
        }
    }

    [Fact]
    public void KillDuringAnUnblockCountdown_RestartContinuesFromTheLastSaveNeitherRestartingNorFinishingEarly()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        // A longer delay applies at once.
        Assert.True(daemon.Send(new Request(Command.SetDelay, Password: Defaults.Password, Seconds: 20)).Ok);
        Assert.True(daemon.Send(new Request(Command.Unblock, Domain: "reddit.com", Password: Defaults.Password)).Ok);
        Thread.Sleep(4500);

        daemon.KillHard();
        daemon.Launch();
        daemon.WaitUntilReady();

        long remaining = daemon.Status().Blocked.Single().UnblockSecondsRemaining!.Value;
        // 4.5 s had passed and the state is saved at least every 2 s while a countdown runs, so the saved value is between about 15.5 and 18 s.
        Assert.InRange(remaining, 12, 18);
        Assert.True(daemon.HostsText().Contains("0.0.0.0 reddit.com", StringComparison.Ordinal));
    }

    [Fact]
    public void HandSetUninstallingFlagWithoutAFinishedCountdown_IsIgnoredOnRestart()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        daemon.KillHard();
        EditBothStateFiles(daemon, state => state["uninstalling"] = true);

        daemon.Launch();
        daemon.WaitUntilReady();

        Assert.False(daemon.Process.HasExited);
        Assert.Equal("reddit.com", daemon.Status().Blocked.Single().Domain);
        Assert.Contains("0.0.0.0 reddit.com", daemon.HostsText().Split('\n'));
        Assert.True(daemon.WaitForLogCount("ignored uninstalling flag", 1), daemon.LogText());
        Assert.True(Wait.Until(() => daemon.StateJson()["uninstalling"]?.GetValue<bool>() == false, 3));
    }

    [Fact]
    public void UninstallingFlagWithAFinishedCountdown_FinishesTheUninstallOnRestart()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        daemon.KillHard();
        EditBothStateFiles(daemon, state =>
        {
            state["uninstalling"] = true;
            state["pendingUninstall"] = new JsonObject { ["remainingSeconds"] = 0, ["totalSeconds"] = 2 };
        });

        daemon.Launch();

        Assert.Equal(0, daemon.WaitForExit(15));
        Assert.Equal(SandboxDaemon.StartingHosts, daemon.HostsText());
        Assert.Null(Expected.Key(daemon.Registry(), Expected.ChromeKey));
    }

    [Fact]
    public void HostsFileWithWindowsLineEndings_KeepsTheUserLinesAndIsWrittenWithNewlinesOnly()
    {
        string crlf = SandboxDaemon.StartingHosts.Replace("\n", "\r\n");
        using var daemon = SandboxDaemon.Start(hosts: crlf);

        daemon.SetupAndAdd("reddit.com");

        string hosts = daemon.HostsText();
        Assert.DoesNotContain("\r", hosts);
        Assert.StartsWith(SandboxDaemon.StartingHosts, hosts);
        Assert.Equal(Expected.SectionFor(Expected.Expand("reddit.com")), Expected.SectionLines(hosts));
    }

    [Fact]
    public void MissingHostsFile_IsCreatedWithTheSection()
    {
        using var daemon = SandboxDaemon.Start(hosts: null);

        daemon.SetupAndAdd("reddit.com");

        Assert.Equal(Expected.SectionFor(Expected.Expand("reddit.com")), Expected.SectionLines(daemon.HostsText()));
    }

    [Fact]
    public void DamagedRegistryFile_IsReplacedWithEveryOwnedValueAndList()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        SandboxDaemon.WriteAllText(daemon.RegistryPath, "this is { not json");

        Assert.True(Wait.Until(() => { try { return Expected.Key(daemon.Registry(), Expected.FirefoxBlockKey) is not null; } catch (System.Text.Json.JsonException) { return false; } }, 3));
        Expected.AssertAdultFilterValues(daemon.Registry());
        Assert.Equal(["redd.it", "reddit.com", "redditmedia.com", "redditstatic.com"], Expected.List(daemon.Registry(), Expected.Blocklist(Expected.BraveKey)));
    }

    // The servers of one adapter in network-services.json.
    private static List<string> ServersOf(SandboxDaemon daemon, string id) => ((JsonArray)daemon.NetworkServices()[id]!["servers"]!).Select(server => (string)server!).ToList();

    [Fact]
    public void AdapterChangedBackByHand_IsRepairedAndKeepsItsFirstSavedServers()
    {
        const string wifi = "{22222222-2222-2222-2222-222222222222}";
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""{ "{{wifi}}": { "name": "Wi-Fi", "servers": ["192.168.1.1"] } }"""));
        daemon.Setup();
        Assert.True(Wait.Until(() => ServersOf(daemon, wifi).SequenceEqual(Expected.FamilyServers), 5));
        int repairs = daemon.LogCount("DNS settings repaired");

        // Someone points the adapter at a public resolver; any command but status runs a DNS pass.
        SandboxDaemon.WriteAllText(daemon.NetworkServicesPath, $$"""{ "{{wifi}}": { "name": "Wi-Fi", "servers": ["8.8.8.8"] } }""");
        daemon.Send(new Request(Command.CancelDelayChange));

        Assert.True(Wait.Until(() => ServersOf(daemon, wifi).SequenceEqual(Expected.FamilyServers), 5), daemon.NetworkServices().ToJsonString());
        Assert.True(daemon.WaitForLogCount("DNS settings repaired", repairs + 1), daemon.LogText());
        var saved = (JsonObject)daemon.StateJson()["savedDNS"]!;
        Assert.Equal(["192.168.1.1"], ((JsonArray)saved[wifi]!).Select(server => (string)server!));
    }

    [Fact]
    public void AdapterThatAppearsLater_GetsTheFamilyServersAndItsOriginalsAreSaved()
    {
        const string ethernet = "{11111111-1111-1111-1111-111111111111}";
        const string usb = "{44444444-4444-4444-4444-444444444444}";
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""{ "{{ethernet}}": { "name": "Ethernet", "servers": [] } }"""));
        daemon.Setup();
        Assert.True(Wait.Until(() => ServersOf(daemon, ethernet).SequenceEqual(Expected.FamilyServers), 5));

        var services = daemon.NetworkServices();
        services[usb] = new JsonObject { ["name"] = "USB Ethernet", ["servers"] = new JsonArray("10.0.0.53") };
        SandboxDaemon.WriteAllText(daemon.NetworkServicesPath, services.ToJsonString());
        daemon.Send(new Request(Command.CancelDelayChange));

        Assert.True(Wait.Until(() => ServersOf(daemon, usb).SequenceEqual(Expected.FamilyServers), 5), daemon.NetworkServices().ToJsonString());
        Assert.True(Wait.Until(() => daemon.StateJson()["savedDNS"] is JsonObject saved && saved.ContainsKey(usb), 3));
        Assert.Equal(["10.0.0.53"], ((JsonArray)daemon.StateJson()["savedDNS"]![usb]!).Select(server => (string)server!));
    }

    [Fact]
    public void AdapterWithoutIpv6_GetsOnlyTheTwoIpv4FamilyServers()
    {
        const string v4only = "{55555555-5555-5555-5555-555555555555}";
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""{ "{{v4only}}": { "name": "Old NIC", "ipv6": false, "servers": ["192.168.0.1"] } }"""));
        daemon.Setup();

        Assert.True(Wait.Until(() => ServersOf(daemon, v4only).SequenceEqual(Expected.FamilyIpv4Servers), 5), daemon.NetworkServices().ToJsonString());
        // Held steady: later passes do not keep "repairing" it toward the IPv6 servers.
        daemon.Send(new Request(Command.CancelDelayChange));
        Thread.Sleep(800);
        Assert.Equal(Expected.FamilyIpv4Servers, ServersOf(daemon, v4only));
        Assert.Equal(0, daemon.LogCount("DNS settings repaired"));
    }

    [Fact]
    public void DnsPassWithNothingToChange_DoesNotRewriteTheAdaptersFile()
    {
        const string ethernet = "{11111111-1111-1111-1111-111111111111}";
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""{ "{{ethernet}}": { "name": "Ethernet", "servers": [] } }"""));
        daemon.Setup();
        Assert.True(Wait.Until(() => ServersOf(daemon, ethernet).SequenceEqual(Expected.FamilyServers), 5));
        // The same content in an unusual layout: any rewrite by the daemon would change the text.
        string servers = string.Join(",", Expected.FamilyServers.Select(server => $"\"{server}\""));
        string handWritten = $$"""{"{{ethernet}}":{"name":"Ethernet","servers":[{{servers}}]}   }""";
        SandboxDaemon.WriteAllText(daemon.NetworkServicesPath, handWritten);

        daemon.Send(new Request(Command.CancelDelayChange));
        daemon.Send(new Request(Command.Add, Domain: "example.org"));
        Thread.Sleep(1000);

        Assert.Equal(handWritten, SandboxDaemon.ReadShared(daemon.NetworkServicesPath));
    }

    [Fact]
    public void AddPath_WhenTheWholeSiteIsBlocked_IsAlreadyBlocked()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        daemon.SetupAndAdd("youtube.com");

        var response = daemon.Send(new Request(Command.AddPath, Domain: "youtube.com/shorts"));

        Assert.Equal(ErrorCode.AlreadyBlocked, response.ErrorCode);
        Assert.Empty(daemon.Status().BlockedPaths!);
    }
}

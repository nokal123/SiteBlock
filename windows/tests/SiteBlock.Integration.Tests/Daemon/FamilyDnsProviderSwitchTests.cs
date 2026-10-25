using System.Diagnostics;
using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// What the DNS enforcer does after the family DNS provider is switched by an update, through the real sandbox daemon and its network-services.json.
// Expected values: 06-windows.md § DNSEnforcer ("Known providers": an adapter that holds any known provider's list FOR IT and has a saved original counts as overridden, so it
// gets its originals back while the family servers do not answer; the saved originals of an adapter that has a record are never replaced. "Which servers an adapter wants":
// the IPv4 pair when it has IPv4 settings, then the IPv6 pair when it has IPv6 settings), 03-daemon-cli-app.md § DNSEnforcer (pass step 1, Reachability check, Uninstall),
// 02-core-components.md § FamilyDNSProviders (the three known providers, CleanBrowsing Family active) and 01-overview-and-data.md § Fixed Policy Values.
//
// "A switch" is simulated as it happens on a real PC: a daemon that ran with the previous provider left the adapters on that provider's servers and its record in the state
// file. The test lets the daemon record the real originals, kills it, puts the adapters on another known provider's servers, and starts it again.
// Every address is typed from the design text, never read from the providers file, so a wrong address in the file fails these tests.
public sealed class FamilyDnsProviderSwitchTests
{
    private const string Wifi = "{A1111111-1111-1111-1111-111111111111}";
    private const string Ethernet = "{A2222222-2222-2222-2222-222222222222}";
    private const string OldNic = "{A3333333-3333-3333-3333-333333333333}";
    private const string Own = "{A4444444-4444-4444-4444-444444444444}";
    private const string NewNic = "{A5555555-5555-5555-5555-555555555555}";
    private const string UnreachableLine = "family DNS unreachable; using the network's own DNS until it answers";

    // CleanBrowsing Family Filter, the active provider, and the two other known providers (02 § FamilyDNSProviders).
    private static readonly string[] CleanBrowsing = ["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::"];
    private static readonly string[] CleanBrowsingIpv4 = ["185.228.168.168", "185.228.169.168"];
    private static readonly string[] Cloudflare = ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"];
    private static readonly string[] CloudflareIpv4 = ["1.1.1.3", "1.0.0.3"];
    private static readonly string[] AdGuard = ["94.140.14.15", "94.140.15.16", "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff"];

    private static List<string> ServersOf(SandboxDaemon daemon, string id) => ((JsonArray)daemon.NetworkServices()[id]!["servers"]!).Select(server => (string)server!).ToList();

    // The saved originals in a state file as id → servers text ("a,b"), or null when the file or the key is missing; text form makes records easy to compare and print.
    private static Dictionary<string, string>? SavedDns(SandboxDaemon daemon, string? path = null)
    {
        path ??= daemon.StatePath;
        if (!File.Exists(path)) return null;
        if (JsonNode.Parse(SandboxDaemon.ReadShared(path))?["savedDNS"] is not JsonObject saved) return null;
        return saved.ToDictionary(entry => entry.Key, entry => string.Join(",", ((JsonArray)entry.Value!).Select(server => (string)server!)));
    }

    private static string Text(IEnumerable<KeyValuePair<string, string>>? record) => record is null ? "null" : string.Join("; ", record.OrderBy(entry => entry.Key, StringComparer.Ordinal).Select(entry => $"{entry.Key}=[{entry.Value}]"));

    // Sets the servers of the named adapters in network-services.json, keeping every other key and entry; a new id becomes a new adapter.
    private static void PutServers(SandboxDaemon daemon, params (string Id, string[] Servers)[] changes)
    {
        var services = daemon.NetworkServices();
        foreach (var (id, servers) in changes)
        {
            var entry = services[id] as JsonObject ?? new JsonObject { ["name"] = "Adapter " + id };
            entry["servers"] = new JsonArray([.. servers.Select(server => (JsonNode)JsonValue.Create(server)!)]);
            services[id] = entry;
        }
        SandboxDaemon.WriteAllText(daemon.NetworkServicesPath, services.ToJsonString());
    }

    // Starts the daemon on the given adapters, waits until every one holds what it wants and the record holds its originals, then kills the daemon and returns it stopped.
    private static SandboxDaemon OverriddenThenStopped(string servicesJson, Dictionary<string, string[]> wanted, Dictionary<string, string> originals)
    {
        var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, servicesJson));
        try
        {
            Assert.True(Wait.Until(() => wanted.All(entry => ServersOf(daemon, entry.Key).SequenceEqual(entry.Value)), 5), "the first daemon never set the CleanBrowsing servers: " + daemon.NetworkServices().ToJsonString());
            Assert.True(Wait.Until(() => Text(SavedDns(daemon)) == Text(originals), 5), "the first daemon recorded " + Text(SavedDns(daemon)));
            daemon.KillHard();
            return daemon;
        }
        catch
        {
            daemon.Dispose();
            throw;
        }
    }

    private static readonly string TwoAdapters = $$"""{ "{{Wifi}}": { "name": "Wi-Fi", "servers": ["192.168.1.1"] }, "{{Ethernet}}": { "name": "Ethernet", "servers": [] } }""";
    private static readonly Dictionary<string, string> TwoOriginals = new() { [Wifi] = "192.168.1.1", [Ethernet] = "" };

    private static SandboxDaemon TwoAdaptersOverriddenThenStopped() => OverriddenThenStopped(TwoAdapters, new() { [Wifi] = CleanBrowsing, [Ethernet] = CleanBrowsing }, TwoOriginals);

    public static TheoryData<string, string[]> PreviousProviders => new() { { "Cloudflare for Families", Cloudflare }, { "AdGuard DNS Family Protection", AdGuard } };

    // (a) 03 § DNSEnforcer pass step 1 and 06 "Known providers": an adapter on a previous provider's four servers is moved to CleanBrowsing's, and its record keeps the first
    // saved original; the previous provider's servers are never written into it, neither at the switch nor in the passes after it.
    // A new adapter with no record appears at the same restart, so the switch pass has a new original to save and really writes the record; without it the record would not be
    // saved at all and a pass that put the previous provider's servers into the existing entries could never show up in the state file.
    [Theory]
    [MemberData(nameof(PreviousProviders))]
    public void AdapterOnAPreviousProvidersServers_IsMovedToCleanBrowsing_AndKeepsItsRealOriginal(string previousName, string[] previous)
    {
        using var daemon = TwoAdaptersOverriddenThenStopped();
        PutServers(daemon, (Wifi, previous), (Ethernet, previous), (NewNic, ["10.0.0.1"]));
        daemon.Launch();
        daemon.WaitUntilReady();
        var expected = new Dictionary<string, string>(TwoOriginals) { [NewNic] = "10.0.0.1" };

        Assert.True(Wait.Until(() => new[] { Wifi, Ethernet, NewNic }.All(id => ServersOf(daemon, id).SequenceEqual(CleanBrowsing)), 5), $"not every adapter left {previousName}: {daemon.NetworkServices().ToJsonString()}\n{daemon.LogText()}");
        // The originals are saved before any adapter is written, so once the adapters hold CleanBrowsing the record must already be the final one. Watch it through later passes
        // (the sandbox runs one every tick): it must only ever hold the real originals plus the new adapter's own servers.
        var seen = new HashSet<string>();
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < TimeSpan.FromSeconds(1)) { seen.Add(Text(SavedDns(daemon))); Thread.Sleep(5); }
        Assert.Equal([Text(expected)], seen);
        Assert.Equal(Text(expected), Text(SavedDns(daemon, daemon.StateBackupPath)));
        Assert.Equal(CleanBrowsing, ServersOf(daemon, Wifi));
    }

    // (b) 06 "Known providers" and 03 Reachability check: while the family servers do not answer, an adapter still on the previous provider's servers that has a record gets its
    // saved servers back and the record is kept. An adapter on Cloudflare's servers WITHOUT a record was never overridden, so it is left alone and is not recorded; when the
    // family servers answer again, step 1 records its own servers and sets CleanBrowsing.
    [Fact]
    public void AdapterStillOnThePreviousProvider_GetsItsOriginalBack_WhenTheFamilyServersStopAnswering()
    {
        using var daemon = TwoAdaptersOverriddenThenStopped();
        PutServers(daemon, (Wifi, Cloudflare), (Ethernet, Cloudflare), (Own, Cloudflare));
        File.WriteAllText(daemon.UnreachableMarkerPath, "");
        daemon.Launch();
        daemon.WaitUntilReady();

        // "Unreachable" needs 3 failed checks in a row; the sandbox checks once per 0.2 s tick.
        Assert.True(Wait.Until(() => ServersOf(daemon, Wifi).SequenceEqual(["192.168.1.1"]) && ServersOf(daemon, Ethernet).Count == 0, 6), $"the adapters on Cloudflare's servers did not get their originals back: {daemon.NetworkServices().ToJsonString()}\n{daemon.LogText()}");
        Thread.Sleep(800);
        Assert.Equal(["192.168.1.1"], ServersOf(daemon, Wifi));
        Assert.Empty(ServersOf(daemon, Ethernet));
        Assert.Equal(Cloudflare, ServersOf(daemon, Own));
        Assert.Equal(Text(TwoOriginals), Text(SavedDns(daemon)));
        Assert.Equal(1, daemon.LogCount(UnreachableLine));

        File.Delete(daemon.UnreachableMarkerPath);
        Assert.True(Wait.Until(() => new[] { Wifi, Ethernet, Own }.All(id => ServersOf(daemon, id).SequenceEqual(CleanBrowsing)), 5), "CleanBrowsing was not applied again: " + daemon.NetworkServices().ToJsonString());
        Assert.Equal(Text(new Dictionary<string, string>(TwoOriginals) { [Own] = string.Join(",", Cloudflare) }), Text(SavedDns(daemon)));
    }

    // 06 "Known providers" says "any known provider's list for it": for an adapter without IPv6 settings that is the provider's IPv4 pair. So an IPv4-only adapter still on
    // Cloudflare's two IPv4 servers counts as overridden: it is moved to CleanBrowsing's IPv4 pair while the servers answer, and gets its original back while they do not.
    [Fact]
    public void AdapterWithoutIpv6_OnThePreviousProvidersIpv4Pair_IsMovedWhenReachableAndRestoredWhenUnreachable()
    {
        string services = $$"""{ "{{OldNic}}": { "name": "Old NIC", "ipv6": false, "servers": ["192.168.0.1"] } }""";
        using var daemon = OverriddenThenStopped(services, new() { [OldNic] = CleanBrowsingIpv4 }, new() { [OldNic] = "192.168.0.1" });
        PutServers(daemon, (OldNic, CloudflareIpv4));
        daemon.Launch();
        daemon.WaitUntilReady();

        Assert.True(Wait.Until(() => ServersOf(daemon, OldNic).SequenceEqual(CleanBrowsingIpv4), 5), "the IPv4-only adapter did not leave Cloudflare's pair: " + daemon.NetworkServices().ToJsonString());
        Assert.Equal("192.168.0.1", SavedDns(daemon)![OldNic]);

        // Back on the previous provider's pair (as after a switch), then the family servers stop answering.
        daemon.KillHard();
        PutServers(daemon, (OldNic, CloudflareIpv4));
        File.WriteAllText(daemon.UnreachableMarkerPath, "");
        daemon.Launch();
        daemon.WaitUntilReady();
        Assert.True(Wait.Until(() => ServersOf(daemon, OldNic).SequenceEqual(["192.168.0.1"]), 6), $"the IPv4-only adapter on Cloudflare's pair was not restored: {daemon.NetworkServices().ToJsonString()}\n{daemon.LogText()}");
        Assert.Equal("192.168.0.1", SavedDns(daemon)![OldNic]);
    }

    // 03 § DNSEnforcer Uninstall, end to end after a switch: the uninstaller restores the servers saved before SiteBlock changed anything, not the previous provider's.
    // As in (a), a new adapter with no record appears at the restart, so the switch pass saves the record to the state file the uninstall later reads.
    [Fact]
    public void UninstallAfterASwitch_RestoresTheRealOriginals_NotThePreviousProvider()
    {
        using var daemon = TwoAdaptersOverriddenThenStopped();
        PutServers(daemon, (Wifi, Cloudflare), (Ethernet, Cloudflare), (NewNic, ["10.0.0.1"]));
        daemon.Launch();
        daemon.WaitUntilReady();
        daemon.Setup();
        Assert.True(Wait.Until(() => new[] { Wifi, Ethernet, NewNic }.All(id => ServersOf(daemon, id).SequenceEqual(CleanBrowsing)), 5), daemon.NetworkServices().ToJsonString());
        Assert.Equal(Text(new Dictionary<string, string>(TwoOriginals) { [NewNic] = "10.0.0.1" }), Text(SavedDns(daemon)));

        Assert.True(daemon.Send(new Request(Command.Uninstall, Password: Defaults.Password)).Ok);
        Assert.Equal(0, daemon.WaitForExit(15));
        Assert.Equal(["192.168.1.1"], ServersOf(daemon, Wifi));
        Assert.Empty(ServersOf(daemon, Ethernet));
        Assert.Equal(["10.0.0.1"], ServersOf(daemon, NewNic));
    }

    // 06 "Known providers" says "any known provider's list FOR IT", and "Which servers an adapter wants" says an adapter with both IPv4 and IPv6 settings wants the IPv4 pair
    // then the IPv6 pair. So Cloudflare's IPv4 pair alone on such an adapter is not Cloudflare's list for it: the adapter is not counted as overridden, and while the family
    // servers do not answer its original is not put back, even though it has a record. Control: in the same pass an adapter holding Cloudflare's full four-server list with a
    // record does get its original back, which shows the unreachable restore really ran.
    [Fact]
    public void AdapterWithBothFamilies_OnlyOnThePreviousProvidersIpv4Pair_IsNotRestoredWhenUnreachable()
    {
        using var daemon = TwoAdaptersOverriddenThenStopped();
        PutServers(daemon, (Wifi, Cloudflare), (Ethernet, CloudflareIpv4));
        File.WriteAllText(daemon.UnreachableMarkerPath, "");
        daemon.Launch();
        daemon.WaitUntilReady();

        // "Unreachable" needs 3 failed checks in a row; the sandbox checks once per 0.2 s tick.
        Assert.True(Wait.Until(() => ServersOf(daemon, Wifi).SequenceEqual(["192.168.1.1"]), 6), $"the control adapter on Cloudflare's four servers did not get its original back: {daemon.NetworkServices().ToJsonString()}\n{daemon.LogText()}");
        // Ethernet's original is the empty list, so a wrong restore would show as an adapter with no servers. Wait through more passes before judging it.
        Thread.Sleep(800);
        Assert.Equal(CloudflareIpv4, ServersOf(daemon, Ethernet));
        Assert.Equal(["192.168.1.1"], ServersOf(daemon, Wifi));
        Assert.Equal(Text(TwoOriginals), Text(SavedDns(daemon)));
        Assert.Equal(1, daemon.LogCount(UnreachableLine));
    }
}

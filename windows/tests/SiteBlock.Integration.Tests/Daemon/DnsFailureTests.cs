using System.Diagnostics;
using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// What the DNS enforcer does when things go wrong, through the real sandbox daemon and its network-services.json.
// Expected values come from 06-windows.md § DNSEnforcer (one adapter at a time, the 10-minute pause, the read-back) and § DaemonRuntime (a failed save of a newly recorded original
// puts the in-memory record back to what is on disk), and 03-daemon-cli-app.md § DNSEnforcer (Pass step 1: record before replacing; Reachability check: until the first result
// arrives, passes leave the settings as they are, and family-dns-probe-delay slows each check; Read-back: the log sentence and no retry for 10 minutes; Uninstall).
public sealed class DnsFailureTests
{
    private const string Wifi = "{22222222-2222-2222-2222-222222222222}";
    private const string Stubborn = "{55555555-5555-5555-5555-555555555555}";
    private const string Usb = "{66666666-6666-6666-6666-666666666666}";
    private const string Lab = "{77777777-7777-7777-7777-777777777777}";
    private const string SetByHand = "{88888888-8888-8888-8888-888888888888}";

    private static List<string> ServersOf(SandboxDaemon daemon, string id) => ((JsonArray)daemon.NetworkServices()[id]!["servers"]!).Select(server => (string)server!).ToList();

    private static JsonObject? SavedDns(SandboxDaemon daemon) => File.Exists(daemon.StatePath) ? daemon.StateJson()["savedDNS"] as JsonObject : null;

    // Adds or replaces one adapter entry in network-services.json, keeping every other entry as the daemon last wrote it.
    private static void PutAdapter(SandboxDaemon daemon, string id, string json)
    {
        var services = daemon.NetworkServices();
        services[id] = JsonNode.Parse(json);
        SandboxDaemon.WriteAllText(daemon.NetworkServicesPath, services.ToJsonString());
    }

    // Fails the test the first time the adapter's servers differ from the expected list during the whole period.
    private static void AssertStaysFor(SandboxDaemon daemon, string id, string[] expected, TimeSpan period, string why)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < period)
        {
            Assert.True(ServersOf(daemon, id).SequenceEqual(expected), $"{why} (after {clock.Elapsed.TotalSeconds:0.0} s): {daemon.NetworkServices().ToJsonString()}\n{daemon.LogText()}");
            Thread.Sleep(50);
        }
    }

    [Fact]
    public void AdapterThatIgnoresTheChange_KeepsItsServersIsLoggedOnceAndIsNotRetriedWhileOthersAreProtected()
    {
        const string message = "DNS change did not take effect for Stubborn NIC; left the network's DNS in place";
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""
            { "{{Stubborn}}": { "name": "Stubborn NIC", "servers": ["192.168.5.5"], "ignoreWrites": true }, "{{Wifi}}": { "name": "Wi-Fi", "servers": ["192.168.1.1"] } }
            """));

        // One adapter refusing never stops the others from being protected.
        Assert.True(Wait.Until(() => ServersOf(daemon, Wifi).SequenceEqual(Expected.FamilyServers), 5), daemon.NetworkServices().ToJsonString());
        Assert.True(daemon.WaitForLogCount(message, 1), daemon.LogText());
        Assert.Equal(["192.168.5.5"], ServersOf(daemon, Stubborn));

        // Passes keep running (the sandbox runs one every tick, and every command but status runs one), yet the refusing adapter is left alone: no second attempt, no second line.
        // Control that passes really ran: a hand edit of the other adapter in the same period is repaired.
        daemon.Setup();
        PutAdapter(daemon, Wifi, """{ "name": "Wi-Fi", "servers": ["8.8.8.8"] }""");
        Assert.True(Wait.Until(() => ServersOf(daemon, Wifi).SequenceEqual(Expected.FamilyServers), 5), "the hand edit of Wi-Fi was never repaired, so no pass ran");
        Thread.Sleep(2500);
        Assert.Equal(1, daemon.LogCount(message));
        Assert.Equal(["192.168.5.5"], ServersOf(daemon, Stubborn));
    }

    [Fact]
    public void SlowFirstReachabilityCheck_LeavesEveryAdapterExactlyAsItWasUntilTheFirstAnswer()
    {
        using var daemon = SandboxDaemon.Create(prepare: d =>
        {
            File.WriteAllText(d.NetworkServicesPath, $$"""{ "{{Wifi}}": { "name": "Wi-Fi", "servers": ["192.168.1.1", "fd00::1"] }, "{{Lab}}": { "name": "Lab LAN", "servers": [] } }""");
            File.WriteAllText(Path.Combine(d.Root, "family-dns-probe-delay"), "4");
        });
        var sinceLaunch = Stopwatch.StartNew();
        daemon.Launch();
        daemon.WaitUntilReady();

        // A command runs a DNS pass too; with no answer yet it must change nothing and record nothing.
        daemon.Setup();
        TimeSpan left = TimeSpan.FromSeconds(3) - sinceLaunch.Elapsed;
        Assert.True(left > TimeSpan.FromSeconds(0.5), $"the daemon took {sinceLaunch.Elapsed.TotalSeconds:0.0} s to start, too long to watch the first check's 4-second wait");
        AssertStaysFor(daemon, Wifi, ["192.168.1.1", "fd00::1"], left, "an adapter changed before the first reachability answer");
        Assert.Empty(ServersOf(daemon, Lab));
        Assert.True(SavedDns(daemon) is null or { Count: 0 }, "originals were recorded before the first reachability answer");

        // Once the slow check answers, the adapters are set.
        Assert.True(Wait.Until(() => ServersOf(daemon, Wifi).SequenceEqual(Expected.FamilyServers) && ServersOf(daemon, Lab).SequenceEqual(Expected.FamilyServers), 10), daemon.NetworkServices().ToJsonString());
    }

    [System.Runtime.Versioning.UnsupportedOSPlatform("windows")]
    [UnixFact("making a folder unwritable with a Unix permission mode is how this test stops the save; Windows needs an access-list change instead")]
    public void StateThatCannotBeSaved_ChangesNoAdapterAndOnceSavingWorksTheServersThenInPlaceAreRecordedBeforeBeingReplaced()
    {
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""{ "{{Wifi}}": { "name": "Wi-Fi", "servers": ["192.168.1.1"] } }"""));
        daemon.Setup();
        Assert.True(Wait.Until(() => SavedDns(daemon)?.ContainsKey(Wifi) == true && ServersOf(daemon, Wifi).SequenceEqual(Expected.FamilyServers), 5), daemon.LogText());
        string stateFolder = Path.GetDirectoryName(daemon.StatePath)!;
        string stateBefore = SandboxDaemon.ReadShared(daemon.StatePath);

        File.SetUnixFileMode(stateFolder, UnixFileMode.UserRead | UnixFileMode.UserExecute);
        try
        {
            // Precondition: the folder really refuses new files (it would not for root), otherwise this test proves nothing.
            Assert.Throws<UnauthorizedAccessException>(() => File.WriteAllText(Path.Combine(stateFolder, "probe.tmp"), "x"));

            // A new adapter appears while the state cannot be saved: its original cannot be written down first, so it is not changed.
            PutAdapter(daemon, Usb, """{ "name": "USB Ethernet", "servers": ["10.0.0.53"] }""");
            AssertStaysFor(daemon, Usb, ["10.0.0.53"], TimeSpan.FromSeconds(2), "an adapter was changed although its original could not be saved");
            // The person changes it by hand while saving still fails; that is what the adapter holds when SiteBlock finally replaces it.
            PutAdapter(daemon, Usb, """{ "name": "USB Ethernet", "servers": ["10.0.0.99"] }""");
            AssertStaysFor(daemon, Usb, ["10.0.0.99"], TimeSpan.FromSeconds(1.5), "an adapter was changed although its original could not be saved");
            Assert.Equal(stateBefore, SandboxDaemon.ReadShared(daemon.StatePath));
        }
        finally
        {
            File.SetUnixFileMode(stateFolder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }

        // As soon as the adapter holds the family servers, the file on disk must already hold its original, because the original is saved before it is replaced.
        Assert.True(Wait.Until(() => ServersOf(daemon, Usb).SequenceEqual(Expected.FamilyServers), 5), daemon.NetworkServices().ToJsonString() + "\n" + daemon.LogText());
        var saved = SavedDns(daemon);
        Assert.NotNull(saved);
        Assert.Equal(["10.0.0.99"], ((JsonArray)saved![Usb]!).Select(server => (string)server!));
        Assert.Equal(["192.168.1.1"], ((JsonArray)saved[Wifi]!).Select(server => (string)server!));
    }

    [Fact]
    public void Uninstall_LeavesAdaptersSiteBlockNeverOverrodeExactlyAsTheyAre()
    {
        string family = string.Join(", ", Expected.FamilyServers.Select(server => $"\"{server}\""));
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.NetworkServicesPath, $$"""
            { "{{Wifi}}": { "name": "Wi-Fi", "servers": ["192.168.1.1"] }, "{{SetByHand}}": { "name": "Already family", "servers": [{{family}}] } }
            """));
        daemon.Setup();
        Assert.True(Wait.Until(() => SavedDns(daemon)?.ContainsKey(Wifi) == true && ServersOf(daemon, Wifi).SequenceEqual(Expected.FamilyServers), 5), daemon.LogText());

        // On sign-in Wi-Fi SiteBlock overrides nothing, so an adapter that appears now keeps its own servers and gets no savedDNS entry.
        File.WriteAllText(daemon.UnreachableMarkerPath, "");
        Assert.True(Wait.Until(() => ServersOf(daemon, Wifi).SequenceEqual(["192.168.1.1"]), 8), daemon.NetworkServices().ToJsonString());
        PutAdapter(daemon, Lab, """{ "name": "Lab LAN", "servers": ["10.20.30.40", "fd00::53"] }""");
        AssertStaysFor(daemon, Lab, ["10.20.30.40", "fd00::53"], TimeSpan.FromSeconds(1), "SiteBlock changed an adapter while the family servers were unreachable");
        var saved = SavedDns(daemon)!;
        Assert.False(saved.ContainsKey(Lab));
        Assert.False(saved.ContainsKey(SetByHand), "an adapter that already held the family servers was never overridden, so it has no original to keep");

        Assert.True(daemon.Send(new Request(Command.Uninstall, Password: Defaults.Password)).Ok);
        Assert.Equal(0, daemon.WaitForExit(15));

        Assert.Equal(["10.20.30.40", "fd00::53"], ServersOf(daemon, Lab));
        Assert.Equal(Expected.FamilyServers, ServersOf(daemon, SetByHand));
        // Control: the adapter SiteBlock did override has its original.
        Assert.Equal(["192.168.1.1"], ServersOf(daemon, Wifi));
    }
}

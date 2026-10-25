using SiteBlock.Core;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.Daemon;

// Which servers the real DnsEnforcer sets and holds on an adapter, by the address families the adapter has settings for.
// Expected values: 06-windows.md § DNSEnforcer "Which servers an adapter wants" (the active provider's IPv4 pair when the adapter has IPv4 settings, then the IPv6 pair
// when it has IPv6 settings; an adapter with IPv6 settings only gets and holds the two IPv6 servers, so it is not set again on every pass; an adapter without IPv6 settings
// gets and holds only the two IPv4 servers) and "Known providers", 03-daemon-cli-app.md § DNSEnforcer (pass step 1 records the originals first; "DNS settings repaired" is
// logged only for overriding a service SiteBlock had already overridden), 02-core-components.md § FamilyDNSProviders (the addresses).
//
// Why these tests do not use the sandbox daemon: the sandbox's network-services.json can mark an adapter as having no IPv6 settings ("ipv6": false, 06 § DNSEnforcer
// FileDnsBackend) but has no way to say "no IPv4 settings"; FileDnsBackend always reports HasIpv4 = true. So the IPv6-only case is driven through the real DnsEnforcer
// with a stand-in backend (an in-memory list of adapters that stores what is written, as the registry would) and a probe whose check result the test chooses.
// What these tests cannot show: that WindowsDnsBackend reports HasIpv4 = false for a real adapter without a Tcpip interfaces key; that needs a Windows machine.
public sealed class DnsEnforcerAddressFamilyTests : IDisposable
{
    private static readonly string[] Ipv4Pair = ["185.228.168.168", "185.228.169.168"];
    private static readonly string[] Ipv6Pair = ["2a0d:2a00:1::", "2a0d:2a00:2::"];
    private static readonly string[] CloudflareIpv6Pair = ["2606:4700:4700::1113", "2606:4700:4700::1003"];
    private const string Adapter = "{B1111111-1111-1111-1111-111111111111}";

    private readonly string _folder = Path.Combine(Path.GetTempPath(), "sbdns" + Guid.NewGuid().ToString("N")[..10]);
    private string LogPath => Path.Combine(_folder, "siteblockd.log");

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); } catch (DirectoryNotFoundException) { }
    }

    // A stand-in for the adapters: holds each adapter and stores what Apply writes as its servers, and counts the writes.
    private sealed class MemoryBackend(params DnsAdapter[] adapters) : IDnsSettingsBackend
    {
        private readonly Dictionary<string, DnsAdapter> _adapters = adapters.ToDictionary(adapter => adapter.Id, StringComparer.OrdinalIgnoreCase);
        public List<(string Id, string[] Servers)> Writes { get; } = [];

        public IReadOnlyList<DnsAdapter> ReadAdapters() => [.. _adapters.Values];

        public void Apply(IReadOnlyDictionary<string, IReadOnlyList<string>> servers)
        {
            foreach (var (id, list) in servers)
            {
                Writes.Add((id, [.. list]));
                if (_adapters.TryGetValue(id, out var adapter)) _adapters[id] = adapter with { Servers = [.. list] };
            }
        }

        public string[] ServersOf(string id) => [.. _adapters[id].Servers];
    }

    // An enforcer over the backend whose probe has already published the given answer (one check is enough for either answer here).
    private async Task<DnsEnforcer> EnforcerAsync(MemoryBackend backend, bool reachable)
    {
        var probe = new FamilyDNSProbe(_ => Task.FromResult(reachable), failuresBeforeUnreachable: 1);
        var step = await probe.RunOnceAsync();
        Assert.Equal(reachable, step.Published);
        return new DnsEnforcer(backend, probe, new Log(LogPath), sandbox: true, TimeSpan.FromSeconds(30));
    }

    private string LogText() => File.Exists(LogPath) ? File.ReadAllText(LogPath) : "";

    // Runs passes the way the daemon does: each pass gets the record the one before returned, and a record handed to persist is what the daemon would save.
    private static Dictionary<string, List<string>>? Passes(DnsEnforcer enforcer, Dictionary<string, List<string>>? saved, int count)
    {
        for (int pass = 0; pass < count; pass++) saved = enforcer.Enforce(true, saved, _ => true);
        return saved;
    }

    public static TheoryData<string, bool, bool, string[]> AdapterKinds => new()
    {
        { "IPv6 settings only", false, true, Ipv6Pair },
        { "IPv4 settings only", true, false, Ipv4Pair },
        { "both families", true, true, [.. Ipv4Pair, .. Ipv6Pair] },
    };

    // (c) The first pass writes exactly the servers the adapter wants, once, after recording its originals; the following passes write nothing and log no repair.
    [Theory]
    [MemberData(nameof(AdapterKinds))]
    public async Task Adapter_GetsOnlyTheServersOfItsFamilies_AndHoldsThemOverLaterPasses(string kind, bool hasIpv4, bool hasIpv6, string[] wanted)
    {
        string[] original = hasIpv4 ? ["192.168.1.1"] : ["2001:db8::53"];
        var backend = new MemoryBackend(new DnsAdapter(Adapter, "Wi-Fi", "Wireless80211", "Intel Wi-Fi", true, original, HasIpv6: hasIpv6, HasIpv4: hasIpv4));
        var enforcer = await EnforcerAsync(backend, reachable: true);

        var record = enforcer.Enforce(true, null, _ => true);
        Assert.True(backend.ServersOf(Adapter).SequenceEqual(wanted), $"{kind}: the adapter holds {string.Join(", ", backend.ServersOf(Adapter))}");
        Assert.Equal([(Adapter, wanted)], backend.Writes.Select(write => (write.Id, write.Servers)).ToList(), new WriteComparer());
        Assert.Equal(original, record![Adapter]);

        record = Passes(enforcer, record, 4);
        Assert.Single(backend.Writes);
        Assert.Equal(wanted, backend.ServersOf(Adapter));
        Assert.Equal(original, record![Adapter]);
        Assert.DoesNotContain("DNS settings repaired", LogText());
        Assert.Contains("DNS settings set to the family servers for 1 network service", LogText());
    }

    // Positive control for the "no repair" check above: changing the IPv6-only adapter by hand after the first override IS repaired back to the IPv6 pair and logged as a repair.
    [Fact]
    public async Task Ipv6OnlyAdapter_EditedByHand_IsRepairedBackToTheIpv6PairOnly()
    {
        var backend = new MemoryBackend(new DnsAdapter(Adapter, "Wi-Fi", "Wireless80211", "Intel Wi-Fi", true, ["2001:db8::53"], HasIpv6: true, HasIpv4: false));
        var enforcer = await EnforcerAsync(backend, reachable: true);
        var record = enforcer.Enforce(true, null, _ => true);

        backend.Apply(new Dictionary<string, IReadOnlyList<string>> { [Adapter] = ["2001:4860:4860::8888"] });
        record = enforcer.Enforce(true, record, _ => true);

        Assert.Equal(Ipv6Pair, backend.ServersOf(Adapter));
        Assert.Equal(["2001:db8::53"], record![Adapter]);
        Assert.Contains("DNS settings repaired", LogText());
    }

    // 06 "Known providers" with "for it": an IPv6-only adapter on the previous provider's IPv6 pair with a record counts as overridden, so while the family servers do not
    // answer it gets its saved servers back and the record is kept.
    [Fact]
    public async Task Ipv6OnlyAdapter_OnThePreviousProvidersIpv6Pair_GetsItsOriginalBackWhenUnreachable()
    {
        var backend = new MemoryBackend(new DnsAdapter(Adapter, "Wi-Fi", "Wireless80211", "Intel Wi-Fi", true, CloudflareIpv6Pair, HasIpv6: true, HasIpv4: false));
        var enforcer = await EnforcerAsync(backend, reachable: false);
        var saved = new Dictionary<string, List<string>> { [Adapter] = ["2001:db8::53"] };

        var record = enforcer.Enforce(true, saved, _ => true);

        Assert.Equal(["2001:db8::53"], backend.ServersOf(Adapter));
        Assert.Equal(["2001:db8::53"], record![Adapter]);
        Assert.Contains("family DNS unreachable; using the network's own DNS until it answers", LogText());
    }

    // Compares (id, servers) writes by value, since arrays compare by reference.
    private sealed class WriteComparer : IEqualityComparer<(string Id, string[] Servers)>
    {
        public bool Equals((string Id, string[] Servers) x, (string Id, string[] Servers) y) => x.Id == y.Id && x.Servers.SequenceEqual(y.Servers);
        public int GetHashCode((string Id, string[] Servers) obj) => obj.Id.GetHashCode();
    }
}

using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace SiteBlock.Service;

/// <summary>One network adapter as the DNS code sees it.</summary>
/// <param name="Id">The adapter's GUID, such as <c>{4D36E972-E325-11CE-BFC1-08002BE10318}</c>, which stays the same when the adapter is renamed. <c>savedDNS</c> is keyed by it.</param>
/// <param name="Name">The name shown in Windows' network settings, for the log.</param>
/// <param name="InterfaceType">The kind of adapter, such as "Ethernet" or "Wireless80211".</param>
/// <param name="Description">The driver's description, used to recognize VPN adapters.</param>
/// <param name="IsEnabled">False when the adapter is switched off (sandbox only; Windows lists only adapters it can use).</param>
/// <param name="Servers">The DNS servers set by hand, IPv4 first, then IPv6; empty when the adapter takes its servers from the network.</param>
/// <param name="HasIpv6">False when the adapter has no IPv6 settings, so only the IPv4 family servers are written to it and expected on it.</param>
public sealed record DnsAdapter(string Id, string Name, string InterfaceType, string Description, bool IsEnabled, IReadOnlyList<string> Servers, bool HasIpv6 = true)
{
    /// <summary>Text in an adapter's description that marks it as a VPN, compared without regard to case. A VPN supplies its own DNS servers, so SiteBlock leaves it alone.</summary>
    public static readonly IReadOnlyList<string> VpnMarkers = ["VPN", "TAP-Windows", "WireGuard", "Wintun", "OpenVPN", "Tailscale", "ZeroTier", "AnyConnect", "Fortinet", "GlobalProtect", "Cloudflare WARP"];

    /// <summary>The interface types that are tunnels or dial-up links, which SiteBlock leaves alone like VPNs.</summary>
    public static readonly IReadOnlySet<string> TunnelTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Tunnel", "Ppp", "PPP", "VPN", "IPSec", "L2TP" };

    /// <summary>The reason SiteBlock leaves this adapter alone, or null when it manages it.</summary>
    public string? SkipReason
    {
        get
        {
            if (!IsEnabled) return "the adapter is disabled";
            if (TunnelTypes.Contains(InterfaceType)) return "tunnel or dial-up adapter (a VPN supplies its own DNS servers)";
            if (VpnMarkers.Any(marker => Description.Contains(marker, StringComparison.OrdinalIgnoreCase)))
            {
                return "VPN adapter (a VPN supplies its own DNS servers)";
            }
            return null;
        }
    }

    /// <summary>True when SiteBlock may replace this adapter's servers.</summary>
    public bool IsManaged => SkipReason is null;
}

/// <summary>How the DNS enforcer reads and changes the adapters' DNS servers. Windows uses the registry and SetInterfaceDnsSettings; a sandbox uses a JSON file.</summary>
public interface IDnsSettingsBackend
{
    /// <summary>Lists every adapter with the DNS servers set on it, read fresh each time. Throws <see cref="IOException"/> when the settings cannot be read.</summary>
    IReadOnlyList<DnsAdapter> ReadAdapters();

    /// <summary>Sets the servers of the given adapters (GUID → servers). An empty list puts the adapter back on the network's own servers. An adapter that no longer exists is skipped. Throws <see cref="IOException"/> when a change fails.</summary>
    void Apply(IReadOnlyDictionary<string, IReadOnlyList<string>> servers);
}

/// <summary>
/// The sandbox stand-in for the adapters: <c>network-services.json</c>, a JSON object from adapter GUID to <c>{"name": …, "servers": […]}</c>, the same shape as the Mac's sandbox file.
/// Optional keys let tests set up awkward adapters: <c>"enabled": false</c>, <c>"interfaceType": "Tunnel"</c> (default "Ethernet"), <c>"description": "…"</c>, <c>"ipv6": false</c>
/// (an adapter without IPv6), and <c>"ignoreWrites": true</c> (an adapter that accepts a change without applying it). A missing file means no adapters.
/// </summary>
public sealed class FileDnsBackend : IDnsSettingsBackend
{
    private readonly string _path;

    /// <summary>Creates a backend over the JSON file at the path.</summary>
    public FileDnsBackend(string path) => _path = path;

    /// <summary>Reads the file into its adapter entries; a missing file is empty and anything that is not a JSON object of objects throws.</summary>
    private JsonObject ReadEntries()
    {
        if (!File.Exists(_path)) return [];
        try
        {
            return JsonNode.Parse(SharedFile.ReadAllText(_path)) as JsonObject ?? throw new IOException($"{_path} is not a JSON object of adapter entries");
        }
        catch (JsonException error)
        {
            throw new IOException($"{_path} is not a JSON object of adapter entries", error);
        }
    }

    /// <inheritdoc />
    public IReadOnlyList<DnsAdapter> ReadAdapters()
    {
        var adapters = new List<DnsAdapter>();
        foreach (var (id, node) in ReadEntries().OrderBy(entry => entry.Key, StringComparer.Ordinal))
        {
            if (node is not JsonObject entry) throw new IOException($"{_path} is not a JSON object of adapter entries");
            adapters.Add(new DnsAdapter(id, Text(entry, "name") ?? id, Text(entry, "interfaceType") ?? "Ethernet", Text(entry, "description") ?? "", Flag(entry, "enabled") ?? true, Servers(entry), Flag(entry, "ipv6") ?? true));
        }
        return adapters;
    }

    /// <inheritdoc />
    public void Apply(IReadOnlyDictionary<string, IReadOnlyList<string>> servers)
    {
        // Nothing to change means no write, so a test editing the file at the same moment is never overwritten with stale content.
        if (servers.Count == 0) return;
        var entries = ReadEntries();
        foreach (var (id, list) in servers)
        {
            if (entries[id] is not JsonObject entry || Flag(entry, "ignoreWrites") == true) continue;
            entry["servers"] = new JsonArray([.. list.Select(server => (JsonNode)JsonValue.Create(server)!)]);
        }
        try
        {
            string temp = _path + $".{Guid.NewGuid():N}.tmp";
            File.WriteAllText(temp, entries.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception error) when (error is UnauthorizedAccessException)
        {
            throw new IOException($"cannot write {_path}: {error.Message}", error);
        }
    }

    /// <summary>The text of a key, or null when it is missing or not text.</summary>
    private static string? Text(JsonObject entry, string key) => entry[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    /// <summary>The true/false value of a key, or null when it is missing or not a boolean.</summary>
    private static bool? Flag(JsonObject entry, string key) => entry[key] is JsonValue value && value.TryGetValue(out bool flag) ? flag : null;

    /// <summary>The adapter's server list; an entry without a usable list has no servers set.</summary>
    private static List<string> Servers(JsonObject entry) =>
        entry["servers"] is JsonArray array ? [.. array.Select(item => item is JsonValue value && value.TryGetValue(out string? text) ? text : null).OfType<string>()] : [];
}

/// <summary>
/// The real adapters. It lists the Ethernet and Wi-Fi adapters that are not loopback, reads each one's static servers from the <c>NameServer</c> values under
/// <c>HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\&lt;GUID&gt;</c> and the matching <c>Tcpip6</c> key, and writes with <c>SetInterfaceDnsSettings</c>,
/// once for IPv4 and once for IPv6.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsDnsBackend : IDnsSettingsBackend
{
    /// <summary>The registry key that holds each adapter's IPv4 settings, by GUID.</summary>
    public const string Ipv4InterfacesKey = @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces";
    /// <summary>The registry key that holds each adapter's IPv6 settings, by GUID.</summary>
    public const string Ipv6InterfacesKey = @"SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces";

    // DNS_INTERFACE_SETTINGS flags and version from netioapi.h.
    private const ulong DnsSettingIpv6 = 0x0001;
    private const ulong DnsSettingNameServer = 0x0002;
    private const uint DnsInterfaceSettingsVersion1 = 1;

    /// <inheritdoc />
    public IReadOnlyList<DnsAdapter> ReadAdapters()
    {
        NetworkInterface[] interfaces;
        try { interfaces = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException error) { throw new IOException($"cannot list the network adapters: {error.Message}", error); }
        var adapters = new List<DnsAdapter>();
        foreach (var adapter in interfaces)
        {
            // Only Ethernet and Wi-Fi adapters carry the PC's own lookups; loopback, tunnel and dial-up adapters are left out here and skipped by the type rule below if they show up.
            if (adapter.NetworkInterfaceType is NetworkInterfaceType.Loopback) continue;
            string type = adapter.NetworkInterfaceType switch
            {
                NetworkInterfaceType.Wireless80211 => "Wireless80211",
                NetworkInterfaceType.Tunnel => "Tunnel",
                NetworkInterfaceType.Ppp => "Ppp",
                NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.Ethernet3Megabit => "Ethernet",
                _ => adapter.NetworkInterfaceType.ToString(),
            };
            if (type is not ("Ethernet" or "Wireless80211" or "Tunnel" or "Ppp")) continue;
            string id = adapter.Id;
            // Only an adapter with TCP/IP settings of its own (a key under the IPv4 or the IPv6 interfaces key) can hold DNS servers. Windows also reports network filters,
            // such as "Ethernet 3-WFP Native MAC Layer LightWeight Filter-0000", and virtual switch ports as Ethernet adapters; they have no such key and are left out. An
            // adapter with IPv6 settings only is kept, or its IPv6 servers would be a way around the family filter.
            bool hasIpv6 = HasIpv6(id);
            if (!HasIpv4Settings(id) && !hasIpv6) continue;
            adapters.Add(new DnsAdapter(id, adapter.Name, type, adapter.Description, true, [.. ReadServers(Ipv4InterfacesKey, id), .. (hasIpv6 ? ReadServers(Ipv6InterfacesKey, id) : [])], hasIpv6));
        }
        return adapters;
    }

    /// <summary>True when the adapter has IPv4 settings (its key under the Tcpip interfaces key exists).</summary>
    private static bool HasIpv4Settings(string id)
    {
        using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = root.OpenSubKey(Ipv4InterfacesKey + "\\" + id);
        return key is not null;
    }

    /// <summary>True when the adapter has IPv6 settings (its key under the Tcpip6 interfaces key exists).</summary>
    private static bool HasIpv6(string id)
    {
        using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = root.OpenSubKey(Ipv6InterfacesKey + "\\" + id);
        return key is not null;
    }

    /// <summary>The adapter's static servers from one of the two registry keys; an empty or missing value means the adapter takes its servers from the network.</summary>
    private static List<string> ReadServers(string interfacesKey, string id)
    {
        using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = root.OpenSubKey(interfacesKey + "\\" + id);
        if (key?.GetValue("NameServer") is not string text) return [];
        return [.. text.Split([',', ' ', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];
    }

    /// <inheritdoc />
    public void Apply(IReadOnlyDictionary<string, IReadOnlyList<string>> servers)
    {
        foreach (var (id, list) in servers.OrderBy(entry => entry.Key, StringComparer.Ordinal))
        {
            if (!Guid.TryParse(id, out Guid guid)) continue;
            // IPv6 addresses contain colons, IPv4 addresses never do.
            string ipv4 = string.Join(',', list.Where(server => !server.Contains(':')));
            string ipv6 = string.Join(',', list.Where(server => server.Contains(':')));
            // Each address family is written only when the adapter has settings for it; a write for a family it lacks would fail and undo the other family's change on every pass.
            if (HasIpv4Settings(id)) SetServers(guid, ipv4, ipv6: false);
            if (HasIpv6(id)) SetServers(guid, ipv6, ipv6: true);
        }
    }

    /// <summary>Writes one address family's server list for one adapter. An empty list puts the adapter back on the network's servers for that family.</summary>
    private static void SetServers(Guid adapter, string servers, bool ipv6)
    {
        IntPtr text = Marshal.StringToHGlobalUni(servers);
        try
        {
            var settings = new DnsInterfaceSettings
            {
                Version = DnsInterfaceSettingsVersion1,
                Flags = DnsSettingNameServer | (ipv6 ? DnsSettingIpv6 : 0),
                NameServer = text,
            };
            uint result;
            try
            {
                result = SetInterfaceDnsSettings(adapter, ref settings);
            }
            catch (EntryPointNotFoundException error)
            {
                // Windows before version 2004 (build 19041) has no SetInterfaceDnsSettings; that is reported like any other failed write, never as a crash.
                throw new IOException("this version of Windows cannot change DNS servers (it needs Windows 10 version 2004 or newer)", error);
            }
            // ERROR_NOT_FOUND (1168) and ERROR_FILE_NOT_FOUND (2): the adapter disappeared since it was listed, which is skipped like the Mac skips a deleted service.
            if (result is 0 or 2 or 1168) return;
            throw new IOException($"SetInterfaceDnsSettings failed with error {result}");
        }
        finally
        {
            Marshal.FreeHGlobal(text);
        }
    }

    /// <summary>DNS_INTERFACE_SETTINGS from netioapi.h.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct DnsInterfaceSettings
    {
        public uint Version;
        public ulong Flags;
        public IntPtr Domain;
        public IntPtr NameServer;
        public IntPtr SearchList;
        public uint RegistrationEnabled;
        public uint RegisterAdapterName;
        public uint EnableLLMNR;
        public uint QueryAdapterName;
        public IntPtr ProfileNameServer;
    }

    [DllImport("iphlpapi.dll")]
    private static extern uint SetInterfaceDnsSettings(Guid interfaceGuid, ref DnsInterfaceSettings settings);
}

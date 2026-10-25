using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text.Json;

namespace SiteBlock.Core;

/// <summary>One family DNS service: a DNS service that refuses to look up adult sites, with the two IPv4 and two IPv6 addresses SiteBlock sets on every managed adapter.</summary>
/// <param name="Id">A short fixed name, such as "cleanbrowsing-family", that the file's <c>active</c> line refers to.</param>
/// <param name="Name">The name people know the service by, such as "CleanBrowsing Family Filter".</param>
/// <param name="Ipv4">The two IPv4 addresses, in their standard form.</param>
/// <param name="Ipv6">The two IPv6 addresses, in their standard short form.</param>
public sealed record FamilyDNSProvider(string Id, string Name, IReadOnlyList<string> Ipv4, IReadOnlyList<string> Ipv6)
{
    /// <summary>The four servers in the order SiteBlock writes them: the IPv4 addresses, then the IPv6 ones.</summary>
    public IReadOnlyList<string> Servers => [.. Ipv4, .. Ipv6];
}

/// <summary>Why the providers file could not be used, as one sentence naming the problem.</summary>
public sealed class FamilyDNSProvidersException(string message) : Exception(message);

/// <summary>
/// The family DNS services SiteBlock knows, and the one it uses, read from <c>FamilyDNSProviders.json</c>. The file lives in the Mac source
/// (<c>Sources/SiteBlockCore/FamilyDNSProviders.json</c>) and is built into this library as an embedded resource, so both versions always use the same list. Switching to
/// another service means changing its <c>active</c> line and releasing an update; nothing on the installed PC can change it, which keeps the promise that no setting
/// turns the adult content filter off.
/// </summary>
public sealed class FamilyDNSProviders
{
    /// <summary>The name the file is embedded under in this library.</summary>
    public const string ResourceName = "FamilyDNSProviders.json";

    /// <summary>The <c>id</c> of the provider in use.</summary>
    public string Active { get; }

    /// <summary>Every known provider. The DNS enforcer treats any of their server lists as family servers, so an adapter still on the previous provider after a switch is recognised.</summary>
    public IReadOnlyList<FamilyDNSProvider> Providers { get; }

    private FamilyDNSProviders(string active, IReadOnlyList<FamilyDNSProvider> providers)
    {
        Active = active;
        Providers = providers;
    }

    /// <summary>The list built into this copy of SiteBlock, or null when the embedded file cannot be read or breaks a rule of <see cref="Parse"/> (the tests make sure it never ships that way).</summary>
    public static FamilyDNSProviders? BuiltIn { get; } = LoadBuiltIn();

    /// <summary>The provider in use. <see cref="Parse"/> has checked that <see cref="Active"/> names one of the providers, so this always finds it.</summary>
    public FamilyDNSProvider ActiveProvider => Providers.First(provider => provider.Id == Active);

    /// <summary>True when the servers are exactly one provider's four servers in SiteBlock's order, which means SiteBlock set them.</summary>
    public bool IsFamilyList(IReadOnlyList<string> servers) => Providers.Any(provider => provider.Servers.SequenceEqual(servers, StringComparer.Ordinal));

    /// <summary>
    /// Reads the providers file and checks the same rules as the Mac version: ids are not empty and not repeated, <c>active</c> names a provider, and every provider has
    /// exactly two IPv4 and two IPv6 addresses, each valid and written in its standard short form (the form Windows reads back, so a write can be compared with what is read).
    /// Throws <see cref="FamilyDNSProvidersException"/> naming the first rule that is broken, or <see cref="JsonException"/> when the text is not the expected JSON.
    /// </summary>
    public static FamilyDNSProviders Parse(ReadOnlySpan<byte> utf8)
    {
        using JsonDocument document = JsonDocument.Parse(utf8.ToArray());
        JsonElement root = document.RootElement;
        // TryGetProperty throws InvalidOperationException on an array or a number, which LoadBuiltIn would not catch, so a file that is not an object fails here as bad JSON.
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("the file is not a JSON object");
        string active = RequiredString(root, "active");
        if (!root.TryGetProperty("providers", out JsonElement list) || list.ValueKind != JsonValueKind.Array) throw new JsonException("the file has no providers list");
        var providers = new List<FamilyDNSProvider>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonElement item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) throw new JsonException("a provider is not an object");
            var provider = new FamilyDNSProvider(RequiredString(item, "id"), RequiredString(item, "name"), Addresses(item, "ipv4"), Addresses(item, "ipv6"));
            if (provider.Id.Length == 0) throw new FamilyDNSProvidersException("a provider has no id");
            if (!seen.Add(provider.Id)) throw new FamilyDNSProvidersException($"the provider id {provider.Id} appears twice");
            if (provider.Ipv4.Count != 2 || provider.Ipv6.Count != 2) throw new FamilyDNSProvidersException($"{provider.Id} must have two IPv4 and two IPv6 addresses");
            foreach (string address in provider.Ipv4)
            {
                if (StandardForm(address, AddressFamily.InterNetwork) != address) throw new FamilyDNSProvidersException($"{provider.Id} has an IPv4 address that is not valid or not in standard form: {address}");
            }
            foreach (string address in provider.Ipv6)
            {
                if (StandardForm(address, AddressFamily.InterNetworkV6) != address) throw new FamilyDNSProvidersException($"{provider.Id} has an IPv6 address that is not valid or not in standard short form: {address}");
            }
            providers.Add(provider);
        }
        if (!seen.Contains(active)) throw new FamilyDNSProvidersException($"the active provider {active} is not in the list");
        return new FamilyDNSProviders(active, providers);
    }

    /// <summary>Reads the embedded file, or returns null when it is missing or cannot be used.</summary>
    private static FamilyDNSProviders? LoadBuiltIn()
    {
        try
        {
            using Stream? stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName);
            if (stream is null) return null;
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            return Parse(buffer.ToArray());
        }
        catch (Exception error) when (error is JsonException or FamilyDNSProvidersException or IOException)
        {
            return null;
        }
    }

    /// <summary>The string value of a property, or a <see cref="JsonException"/> when it is missing or not a string.</summary>
    private static string RequiredString(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : throw new JsonException($"the property {name} is missing or is not text");

    /// <summary>The addresses of one family (a list of strings), or a <see cref="JsonException"/> when the list is missing or holds anything but text.</summary>
    private static IReadOnlyList<string> Addresses(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.Array) throw new JsonException($"the property {name} is missing or is not a list");
        return [.. value.EnumerateArray().Select(entry => entry.ValueKind == JsonValueKind.String ? entry.GetString()! : throw new JsonException($"{name} holds something other than text"))];
    }

    /// <summary>
    /// The address rewritten in its standard form (for IPv6, lowercase with the longest run of zeros shortened to "::"), or null when it is not a valid address of that
    /// family. An address with a zone index such as "%5" counts as not valid: IPAddress.TryParse accepts one and prints it back, but the Mac parser rejects it and a DNS
    /// server address read back from Windows never carries one.
    /// </summary>
    private static string? StandardForm(string address, AddressFamily family) =>
        !address.Contains('%') && IPAddress.TryParse(address, out IPAddress? parsed) && parsed.AddressFamily == family ? parsed.ToString() : null;
}

using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// The family DNS providers file, its reader and the reachability check's targets, in the C# port.
// Expected values come from 02-core-components.md § 15 FamilyDNSProviders (the file's parts, the three known providers and their addresses, the active provider,
// Servers = IPv4 then IPv6, the Parse rules, IsFamilyList) and § 16 FamilyDNSProbe, 06-windows.md § SiteBlock.Core (Family DNS providers: the C# names, the file is
// Sources/SiteBlockCore/FamilyDNSProviders.json embedded as the resource "FamilyDNSProviders.json", UdpFamilyDNSProbe.FamilyTargets is the active provider's two IPv4
// servers on port 53) and 01-overview-and-data.md § Fixed Policy Values. Every address is typed from the design text, never read from the file under test.
public sealed class FamilyDNSProvidersBuiltInTests
{
    // The three known providers as the design lists them.
    public static TheoryData<string, string, string[], string[]> DesignProviders => new()
    {
        { "cleanbrowsing-family", "CleanBrowsing Family Filter", ["185.228.168.168", "185.228.169.168"], ["2a0d:2a00:1::", "2a0d:2a00:2::"] },
        { "cloudflare-families", "Cloudflare for Families", ["1.1.1.3", "1.0.0.3"], ["2606:4700:4700::1113", "2606:4700:4700::1003"] },
        { "adguard-family", "AdGuard DNS Family Protection", ["94.140.14.15", "94.140.15.16"], ["2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff"] },
    };

    // The providers file in the repository: this file is windows/tests/SiteBlock.Core.Tests/<name>.cs, so the repository root is three folders up.
    internal static string RepositoryProvidersFile([CallerFilePath] string thisFile = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(thisFile)!, "..", "..", "..", "Sources", "SiteBlockCore", "FamilyDNSProviders.json"));

    [Fact]
    public void BuiltIn_Parses_AndTheActiveProviderIsCleanBrowsingFamilyWithItsFourServersInOrder()
    {
        FamilyDNSProviders list = Assert.IsType<FamilyDNSProviders>(FamilyDNSProviders.BuiltIn);

        Assert.Equal("cleanbrowsing-family", list.Active);
        Assert.Equal("cleanbrowsing-family", list.ActiveProvider.Id);
        Assert.Equal("CleanBrowsing Family Filter", list.ActiveProvider.Name);
        Assert.Equal(["185.228.168.168", "185.228.169.168"], list.ActiveProvider.Ipv4);
        Assert.Equal(["2a0d:2a00:1::", "2a0d:2a00:2::"], list.ActiveProvider.Ipv6);
        Assert.Equal(["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::"], list.ActiveProvider.Servers);
    }

    [Fact]
    public void BuiltIn_HoldsExactlyTheThreeKnownProviders()
    {
        FamilyDNSProviders list = FamilyDNSProviders.BuiltIn!;
        Assert.Equal(["adguard-family", "cleanbrowsing-family", "cloudflare-families"], list.Providers.Select(provider => provider.Id).Order(StringComparer.Ordinal));
    }

    [Theory]
    [MemberData(nameof(DesignProviders))]
    public void BuiltIn_EachKnownProvider_HasTheDesignNameAndAddresses(string id, string name, string[] ipv4, string[] ipv6)
    {
        FamilyDNSProvider provider = Assert.Single(FamilyDNSProviders.BuiltIn!.Providers, entry => entry.Id == id);

        Assert.Equal(name, provider.Name);
        Assert.Equal(ipv4, provider.Ipv4);
        Assert.Equal(ipv6, provider.Ipv6);
        Assert.Equal([.. ipv4, .. ipv6], provider.Servers);
    }

    // 06 § SiteBlock.Core: the Windows build embeds the Mac source's file itself, so the two builds can never use different lists. The resource must be that file byte for byte.
    [Fact]
    public void EmbeddedResource_IsTheSameBytesAsTheRepositoryProvidersFile()
    {
        using Stream stream = typeof(FamilyDNSProviders).Assembly.GetManifestResourceStream("FamilyDNSProviders.json") ?? throw new InvalidOperationException("no embedded resource named FamilyDNSProviders.json");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        byte[] onDisk = File.ReadAllBytes(RepositoryProvidersFile());

        Assert.True(onDisk.Length > 0, "the repository file is empty");
        Assert.Equal(onDisk, buffer.ToArray());
        Assert.Equal("FamilyDNSProviders.json", FamilyDNSProviders.ResourceName);
    }

    // 06 § SiteBlock.Core and 02 § 16: the reachability check asks the active provider's two IPv4 servers on port 53.
    [Fact]
    public void FamilyTargets_AreCleanBrowsingsTwoIpv4ServersOnPort53()
    {
        Assert.Equal([new UdpFamilyDNSProbe.Target("185.228.168.168", 53), new UdpFamilyDNSProbe.Target("185.228.169.168", 53)], UdpFamilyDNSProbe.FamilyTargets);
    }
}

public sealed class FamilyDNSProvidersParseTests
{
    // One provider entry as a JSON object.
    private static JsonObject Provider(string id, string[]? ipv4 = null, string[]? ipv6 = null) => new()
    {
        ["id"] = id,
        ["name"] = "Provider " + id,
        ["ipv4"] = new JsonArray([.. (ipv4 ?? ["9.9.9.9", "149.112.112.112"]).Select(address => (JsonNode)JsonValue.Create(address)!)]),
        ["ipv6"] = new JsonArray([.. (ipv6 ?? ["2620:fe::fe", "2620:fe::9"]).Select(address => (JsonNode)JsonValue.Create(address)!)]),
    };

    // A whole file: a readme, the active id and the providers; the first id gets the case's addresses and any further provider gets valid distinct ones.
    private static byte[] File(string active, string[] ids, string[]? ipv4 = null, string[]? ipv6 = null)
    {
        var providers = new JsonArray([.. ids.Select((id, index) => (JsonNode)(index == 0 ? Provider(id, ipv4, ipv6) : Provider(id, ["1.1.1.3", "1.0.0.3"], ["2606:4700:4700::1113", "2606:4700:4700::1003"])))]);
        var root = new JsonObject { ["readme"] = "test file", ["active"] = active, ["providers"] = providers };
        return Encoding.UTF8.GetBytes(root.ToJsonString());
    }

    // Positive control for the rejections below: the same builder with nothing broken parses.
    [Fact]
    public void Parse_FileThatKeepsEveryRule_ReturnsItsValues()
    {
        FamilyDNSProviders list = FamilyDNSProviders.Parse(File("a", ["a", "b"]));

        Assert.Equal("a", list.Active);
        Assert.Equal(["a", "b"], list.Providers.Select(provider => provider.Id));
        Assert.Equal(["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"], list.ActiveProvider.Servers);
        Assert.Equal("Provider a", list.ActiveProvider.Name);
    }

    // 02 § 15 Parse: each case breaks exactly one rule (ids not empty and not repeated, active names a provider, exactly 2 IPv4 and 2 IPv6 addresses, each valid and in its
    // standard short form) and must throw FamilyDNSProvidersException.
    public static TheoryData<string, string, string[], string[]?, string[]?> BrokenFiles => new()
    {
        { "empty id", "", [""], null, null },
        { "empty id next to a valid active one", "b", ["", "b"], null, null },
        { "repeated id", "a", ["a", "a"], null, null },
        { "active names no provider", "missing", ["a"], null, null },
        { "active differs only in letter case", "A", ["a"], null, null },
        { "no providers at all", "a", [], null, null },
        { "one IPv4 address", "a", ["a"], ["9.9.9.9"], null },
        { "three IPv4 addresses", "a", ["a"], ["9.9.9.9", "149.112.112.112", "9.9.9.10"], null },
        { "no IPv4 addresses", "a", ["a"], [], null },
        { "one IPv6 address", "a", ["a"], null, ["2620:fe::fe"] },
        { "three IPv6 addresses", "a", ["a"], null, ["2620:fe::fe", "2620:fe::9", "2620:fe::10"] },
        { "IPv4 octet over 255", "a", ["a"], ["9.9.9.256", "149.112.112.112"], null },
        { "IPv4 that is not an address", "a", ["a"], ["not-an-address", "149.112.112.112"], null },
        { "empty IPv4 text", "a", ["a"], ["", "149.112.112.112"], null },
        { "IPv6 that is not an address", "a", ["a"], null, ["2620:fe::zz", "2620:fe::9"] },
        { "IPv4 address in the IPv6 list", "a", ["a"], null, ["9.9.9.9", "2620:fe::9"] },
        { "IPv6 address in the IPv4 list", "a", ["a"], ["2620:fe::fe", "149.112.112.112"], null },
        { "IPv4 with a leading zero", "a", ["a"], ["001.2.3.4", "149.112.112.112"], null },
        { "IPv4 with a zero-padded last part", "a", ["a"], ["9.9.9.09", "149.112.112.112"], null },
        { "IPv4 with a space before it", "a", ["a"], [" 9.9.9.9", "149.112.112.112"], null },
        { "IPv4 written as one number", "a", ["a"], ["151587081", "149.112.112.112"], null },
        { "IPv4 with only three parts", "a", ["a"], ["9.9.2313", "149.112.112.112"], null },
        { "uppercase IPv6", "a", ["a"], null, ["2A0D:2A00:1::", "2620:fe::9"] },
        { "IPv6 with a zero-padded group", "a", ["a"], null, ["2a0d:2a00:0001::", "2620:fe::9"] },
        { "IPv6 written out without ::", "a", ["a"], null, ["2a0d:2a00:1:0:0:0:0:0", "2620:fe::9"] },
        { "IPv6 with :: shortening a single zero group", "a", ["a"], null, ["2a0d::1:2:3:4:5:6", "2620:fe::9"] },
        { "IPv6 with :: on the shorter of two zero runs", "a", ["a"], null, ["2a0d::1:0:0:0:1", "2620:fe::9"] },
        { "IPv6 in square brackets", "a", ["a"], null, ["[2620:fe::fe]", "2620:fe::9"] },
        // A zone index ("%5") is never part of what Windows reads back from a NameServer value, so it is not the standard form; the Mac build rejects it too, and 06 § SiteBlock.Core
        // requires the same behavior on every input.
        { "IPv6 with a zone index", "a", ["a"], null, ["2620:fe::fe%5", "2620:fe::9"] },
    };

    [Theory]
    [MemberData(nameof(BrokenFiles))]
    public void Parse_FileThatBreaksOneRule_ThrowsTheProvidersException(string label, string active, string[] ids, string[]? ipv4, string[]? ipv6)
    {
        byte[] data = File(active, ids, ipv4, ipv6);
        var error = Assert.Throws<FamilyDNSProvidersException>(() => FamilyDNSProviders.Parse(data));
        Assert.False(string.IsNullOrWhiteSpace(error.Message), $"{label}: the exception must carry a sentence naming the rule");
    }

    // 02 § 15: readme is part of the file and other keys are ignored, at the top level and inside a provider; a file without a readme is still the expected JSON.
    [Fact]
    public void Parse_ReadmeAndOtherUnknownKeys_AreAccepted()
    {
        JsonObject provider = Provider("a");
        provider["homepage"] = "https://example.org";
        provider["notes"] = new JsonArray("blocks adult sites");
        var root = new JsonObject { ["readme"] = "people read this", ["version"] = 2, ["comment"] = new JsonObject { ["x"] = 1 }, ["active"] = "a", ["providers"] = new JsonArray(provider) };

        FamilyDNSProviders list = FamilyDNSProviders.Parse(Encoding.UTF8.GetBytes(root.ToJsonString()));
        Assert.Equal(["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"], list.ActiveProvider.Servers);

        var bare = new JsonObject { ["active"] = "a", ["providers"] = new JsonArray(Provider("a")) };
        Assert.Equal("a", FamilyDNSProviders.Parse(Encoding.UTF8.GetBytes(bare.ToJsonString())).Active);
    }

    // 02 § 15: text that is not the expected JSON throws the JSON error, not the providers exception.
    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("""{"active": "a", "providers": [ {"id": "a" """)]
    [InlineData("""{"active": "a"}""")]
    [InlineData("""{"providers": []}""")]
    [InlineData("""{"active": "a", "providers": [{"id": "a", "name": "A", "ipv4": "9.9.9.9", "ipv6": ["2620:fe::fe", "2620:fe::9"]}]}""")]
    [InlineData("""{"active": "a", "providers": [{"id": "a", "name": "A", "ipv4": [9, 9], "ipv6": ["2620:fe::fe", "2620:fe::9"]}]}""")]
    [InlineData("""{"active": "a", "providers": [{"id": "a", "ipv4": ["9.9.9.9", "149.112.112.112"], "ipv6": ["2620:fe::fe", "2620:fe::9"]}]}""")]
    [InlineData("""["active", "a"]""")]
    [InlineData("42")]
    public void Parse_TextThatIsNotTheExpectedJson_ThrowsJsonException(string text)
    {
        Assert.ThrowsAny<JsonException>(() => FamilyDNSProviders.Parse(Encoding.UTF8.GetBytes(text)));
    }

    // The rule reads the providers of the list it is called on, so a parsed file's own provider counts and the built-in ones do not.
    [Fact]
    public void IsFamilyList_OnAParsedFile_RecognisesOnlyItsOwnProviders()
    {
        FamilyDNSProviders list = FamilyDNSProviders.Parse(File("a", ["a"]));
        Assert.True(list.IsFamilyList(["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]));
        Assert.False(list.IsFamilyList(["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::"]));
    }
}

public sealed class FamilyDNSProvidersIsFamilyListTests
{
    // 02 § 15: true when the servers equal one known provider's Servers exactly, in order; any provider counts, not only the active one.
    [Theory]
    [InlineData("185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::")]
    [InlineData("1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003")]
    [InlineData("94.140.14.15", "94.140.15.16", "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff")]
    public void IsFamilyList_AnyKnownProvidersFourServersInOrder_IsTrue(params string[] servers)
    {
        Assert.True(FamilyDNSProviders.BuiltIn!.IsFamilyList(servers));
    }

    // Anything that is not exactly one provider's four servers in order is not a family list.
    public static TheoryData<string[]> NotFamilyLists => new()
    {
        { new[] { "185.228.169.168", "185.228.168.168", "2a0d:2a00:1::", "2a0d:2a00:2::" } },
        { new[] { "2a0d:2a00:1::", "2a0d:2a00:2::", "185.228.168.168", "185.228.169.168" } },
        { new[] { "185.228.168.168", "185.228.169.168" } },
        { new[] { "2a0d:2a00:1::", "2a0d:2a00:2::" } },
        { new[] { "185.228.168.168", "185.228.169.168", "2a0d:2a00:1::" } },
        { new[] { "185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::", "8.8.8.8" } },
        { new[] { "185.228.168.168", "185.228.169.168", "2606:4700:4700::1113", "2606:4700:4700::1003" } },
        { new[] { "185.228.168.168", "185.228.169.168", "2A0D:2A00:1::", "2A0D:2A00:2::" } },
        { new[] { "1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001" } },
        { new[] { "192.168.1.1" } },
        { Array.Empty<string>() },
    };

    [Theory]
    [MemberData(nameof(NotFamilyLists))]
    public void IsFamilyList_DifferentOrderSubsetMixOrUnknownList_IsFalse(string[] servers)
    {
        Assert.False(FamilyDNSProviders.BuiltIn!.IsFamilyList(servers), string.Join(", ", servers));
    }
}

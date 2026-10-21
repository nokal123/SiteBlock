using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// Hand edits to the files a running sandbox siteblockd keeps correct are undone within a tick or so.
// Expected values: 05-testing-and-operations.md § Integration Tests (restored within 1 second), 03-daemon-cli-app.md § DaemonRuntime (tick step 5) and § HostsEnforcer (log wording),
// 06-windows.md § BrowserPolicyEnforcer (compare by name, type and content; a list subkey replaced as a whole; values SiteBlock does not own are never changed).
public sealed class TamperRepairTests
{
    // The design promises a repair within one tick (0.2 s here); the limit leaves room for a loaded test machine.
    private const double RepairSeconds = 3;

    // Rewrites registry.json after applying an edit to its JSON.
    private static void EditRegistry(SandboxDaemon daemon, Action<JsonObject> edit)
    {
        var registry = daemon.Registry();
        edit(registry);
        SandboxDaemon.WriteAllText(daemon.RegistryPath, registry.ToJsonString());
    }

    // The actual name of a key in registry.json (the file may spell it in another letter case).
    private static string KeyName(JsonObject registry, string keyPath) => registry.Select(entry => entry.Key).First(name => string.Equals(name, keyPath, StringComparison.OrdinalIgnoreCase));

    [Fact]
    public void HostsSectionDeletedByHand_IsWrittenBackAndLoggedAsARepair()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        int repairs = daemon.LogCount("hosts file repaired");

        SandboxDaemon.WriteAllText(daemon.HostsPath, SandboxDaemon.StartingHosts);

        Assert.True(Wait.Until(() => Expected.SectionLines(daemon.HostsText()) is { } lines && lines.SequenceEqual(Expected.SectionFor(Expected.Expand("reddit.com"))), RepairSeconds), daemon.HostsText());
        Assert.StartsWith(SandboxDaemon.StartingHosts, daemon.HostsText());
        Assert.True(daemon.WaitForLogCount("hosts file repaired", repairs + 1), daemon.LogText());
    }

    [Fact]
    public void BypassLineForABlockedName_IsRemovedWhileOtherNamesOnTheLineStay()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        SandboxDaemon.WriteAllText(daemon.HostsPath, "151.101.1.140 reddit.com\n151.101.1.140 www.reddit.com other.example.org\n" + daemon.HostsText());

        Assert.True(Wait.Until(() => !daemon.HostsText().Contains("151.101.1.140 reddit.com", StringComparison.Ordinal), RepairSeconds), daemon.HostsText());
        var lines = daemon.HostsText().Split('\n');
        Assert.Contains("151.101.1.140 other.example.org", lines);
        Assert.DoesNotContain(lines, line => line.StartsWith("151.101.1.140", StringComparison.Ordinal) && line.Contains("reddit", StringComparison.Ordinal));
        Assert.Contains("0.0.0.0 reddit.com", lines);
    }

    [Fact]
    public void RegistryValueOfTheWrongType_IsRewrittenAsADwordAndLogged()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        int repairs = daemon.LogCount("browser policy repaired (Chrome)");

        // A string "1" where a DWORD 1 is wanted: a browser ignores a policy of the wrong type.
        EditRegistry(daemon, registry => Expected.Key(registry, Expected.ChromeKey)!["SafeSitesFilterBehavior"] = new JsonObject { ["type"] = "string", ["value"] = "1" });

        Assert.True(Wait.Until(() => (string?)Expected.Value(Expected.Key(daemon.Registry(), Expected.ChromeKey), "SafeSitesFilterBehavior")?["type"] == "dword", RepairSeconds));
        Expected.AssertValue(daemon.Registry(), Expected.ChromeKey, "SafeSitesFilterBehavior", "dword", "1");
        Assert.True(daemon.WaitForLogCount("browser policy repaired (Chrome)", repairs + 1), daemon.LogText());
    }

    [Fact]
    public void RegistryValueWithTheRightTypeButWrongContent_IsRewritten()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.Setup();

        EditRegistry(daemon, registry =>
        {
            Expected.Key(registry, Expected.FirefoxDnsKey)!["Locked"] = new JsonObject { ["type"] = "dword", ["value"] = 0 };
            Expected.Key(registry, Expected.EdgeKey)!["DnsOverHttpsMode"] = new JsonObject { ["type"] = "string", ["value"] = "automatic" };
        });

        Assert.True(Wait.Until(() => Expected.Value(Expected.Key(daemon.Registry(), Expected.FirefoxDnsKey), "Locked")?["value"]?.ToJsonString() == "1", RepairSeconds));
        Assert.True(Wait.Until(() => (string?)Expected.Value(Expected.Key(daemon.Registry(), Expected.EdgeKey), "DnsOverHttpsMode")?["value"] == "off", RepairSeconds));
        Expected.AssertAdultFilterValues(daemon.Registry());
    }

    [Fact]
    public void StrayListValueAddedByHand_IsRemovedAndTheListIsWholeAgain()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        string[] chrome = ["redd.it", "reddit.com", "redditmedia.com", "redditstatic.com"];

        // An extra entry named 1001 (an allow-all looking entry) and a changed entry 2.
        EditRegistry(daemon, registry =>
        {
            var list = Expected.Key(registry, Expected.Blocklist(Expected.ChromeKey))!;
            list["1001"] = new JsonObject { ["type"] = "string", ["value"] = "example.org" };
            list["2"] = new JsonObject { ["type"] = "string", ["value"] = "not-reddit.example" };
        });

        Assert.True(Wait.Until(() => Expected.Key(daemon.Registry(), Expected.Blocklist(Expected.ChromeKey)) is { } key && key.Count == 4 && Expected.Value(key, "1001") is null, RepairSeconds), daemon.Registry().ToJsonString());
        Assert.Equal(chrome, Expected.List(daemon.Registry(), Expected.Blocklist(Expected.ChromeKey)));
    }

    [Fact]
    public void DeletedPolicyKeys_AreWrittenBack()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        // The whole Edge key with its list, and Firefox's block list, are deleted by hand.
        EditRegistry(daemon, registry =>
        {
            registry.Remove(KeyName(registry, Expected.Blocklist(Expected.EdgeKey)));
            registry.Remove(KeyName(registry, Expected.EdgeKey));
            registry.Remove(KeyName(registry, Expected.FirefoxBlockKey));
        });

        Assert.True(Wait.Until(() => Expected.Key(daemon.Registry(), Expected.Blocklist(Expected.EdgeKey)) is not null && Expected.Key(daemon.Registry(), Expected.FirefoxBlockKey) is not null, RepairSeconds));
        var registry = daemon.Registry();
        Expected.AssertAdultFilterValues(registry);
        Assert.Equal(["redd.it", "reddit.com", "redditmedia.com", "redditstatic.com"], Expected.List(registry, Expected.Blocklist(Expected.EdgeKey)));
        Assert.Equal(4, Expected.List(registry, Expected.FirefoxBlockKey)!.Count);
    }

    [Fact]
    public void RegistryFileDeleted_IsWrittenBack()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        File.Delete(daemon.RegistryPath);

        Assert.True(Wait.Until(() => File.Exists(daemon.RegistryPath) && Expected.Key(daemon.Registry(), Expected.FirefoxBlockKey) is not null, RepairSeconds));
        Expected.AssertAdultFilterValues(daemon.Registry());
    }

    [Fact]
    public void ValuesAndSubkeysSiteBlockDoesNotOwn_SurviveRepairPasses()
    {
        // A company policy already in the keys before SiteBlock starts.
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.RegistryPath, """
            {
              "SOFTWARE\\Policies\\Google\\Chrome": { "HomepageLocation": { "type": "string", "value": "https://intranet.example.org" }, "SafeSitesFilterBehavior": { "type": "dword", "value": 0 } },
              "SOFTWARE\\Policies\\Mozilla\\Firefox\\WebsiteFilter\\Exceptions": { "1": { "type": "string", "value": "https://intranet.example.org/*" } }
            }
            """));
        daemon.SetupAndAdd("reddit.com");

        // A tamper elsewhere makes the next pass rewrite Chrome's key.
        EditRegistry(daemon, registry => Expected.Key(registry, Expected.ChromeKey)!["ForceGoogleSafeSearch"] = new JsonObject { ["type"] = "dword", ["value"] = 0 });
        Assert.True(Wait.Until(() => Expected.Value(Expected.Key(daemon.Registry(), Expected.ChromeKey), "ForceGoogleSafeSearch")?["value"]?.ToJsonString() == "1", RepairSeconds));

        var registry = daemon.Registry();
        Expected.AssertValue(registry, Expected.ChromeKey, "HomepageLocation", "string", "\"https://intranet.example.org\"");
        // An owned value set wrongly before SiteBlock started is corrected.
        Expected.AssertValue(registry, Expected.ChromeKey, "SafeSitesFilterBehavior", "dword", "1");
        Expected.AssertValue(registry, Expected.FirefoxKey + @"\WebsiteFilter\Exceptions", "1", "string", "\"https://intranet.example.org/*\"");
    }

    [Fact]
    public void StateFileDeleted_IsRestoredWithTheBlocksKeptAndLogged()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        int repairs = daemon.LogCount("state file repaired");

        File.Delete(daemon.StatePath);

        Assert.True(Wait.Until(() => File.Exists(daemon.StatePath), RepairSeconds));
        Assert.True(Wait.Until(() => { try { return ((JsonArray)daemon.StateJson()["blocked"]!).Any(site => (string?)site!["domain"] == "reddit.com"); } catch (Exception) { return false; } }, RepairSeconds));
        Assert.NotNull(daemon.StateJson()["passwordHash"]);
        Assert.True(daemon.WaitForLogCount("state file repaired", repairs + 1), daemon.LogText());
    }

    [Fact]
    public void StateFileOverwrittenWithAnEmptyObject_IsRestored()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");

        SandboxDaemon.WriteAllText(daemon.StatePath, "{}");

        Assert.True(Wait.Until(() => { try { return daemon.StateJson()["blocked"] is JsonArray blocked && blocked.Count == 1; } catch (Exception) { return false; } }, RepairSeconds), SandboxDaemon.ReadShared(daemon.StatePath));
        Assert.Equal("reddit.com", (string?)daemon.StateJson()["blocked"]![0]!["domain"]);
        Assert.Contains("reddit.com", daemon.Status().Blocked.Select(site => site.Domain));
    }
}

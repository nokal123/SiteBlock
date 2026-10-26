using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// Brave's TorDisabled value in a real sandbox siteblockd's registry.json. Expected values: 06-windows.md § SiteBlock.Core (Windows browser policy rules: Brave's key holds
// "TorDisabled (DWORD 1)", "the adult-filter values (including Brave's TorDisabled) are left out only during an uninstall", "A value of the right name but the wrong type ...
// counts as wrong and is rewritten", values SiteBlock does not own are never changed) and § BrowserPolicyEnforcer (compare by name, type and content; "browser policy repaired
// (<browser>)"; the uninstall pass deletes a policy key only when nothing else is left in it).
public sealed class BraveTorDisabledTests
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

    // True when Brave's TorDisabled is exactly DWORD 1 in the registry file.
    private static bool BraveTorDisabledIsRight(SandboxDaemon daemon)
    {
        var value = Expected.Value(Expected.Key(daemon.Registry(), Expected.BraveKey), "TorDisabled");
        return (string?)value?["type"] == "dword" && value["value"]?.ToJsonString() == "1";
    }

    [Fact]
    public void Startup_WritesTorDisabledAsDwordOneInBravesKeyOnly()
    {
        using var daemon = SandboxDaemon.Start();

        var registry = daemon.Registry();

        Expected.AssertValue(registry, Expected.BraveKey, "TorDisabled", "dword", "1");
        foreach (var (keyPath, _) in registry)
        {
            if (string.Equals(keyPath, Expected.BraveKey, StringComparison.OrdinalIgnoreCase)) continue;
            Assert.Null(Expected.Value(registry[keyPath] as JsonObject, "TorDisabled"));
        }
    }

    // A hand edit that sets TorDisabled to the string "1", the string "true", DWORD 0 or DWORD 2, or deletes it, is undone within a tick to DWORD 1 and logged for Brave.
    [Theory]
    [InlineData("string", "\"1\"")]
    [InlineData("string", "\"true\"")]
    [InlineData("dword", "0")]
    [InlineData("dword", "2")]
    [InlineData(null, null)]
    public void HandEditOfTorDisabled_IsRewrittenAsDwordOneAndLoggedForBrave(string? type, string? jsonValue)
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        Assert.True(Wait.Until(() => BraveTorDisabledIsRight(daemon), RepairSeconds), daemon.Registry().ToJsonString());
        int repairs = daemon.LogCount("browser policy repaired (Brave)");

        EditRegistry(daemon, registry =>
        {
            var brave = Expected.Key(registry, Expected.BraveKey)!;
            brave.Remove("TorDisabled");
            if (type is not null) brave["TorDisabled"] = new JsonObject { ["type"] = type, ["value"] = JsonNode.Parse(jsonValue!) };
        });

        Assert.True(Wait.Until(() => BraveTorDisabledIsRight(daemon), RepairSeconds), daemon.Registry().ToJsonString());
        Expected.AssertAdultFilterValues(daemon.Registry());
        Assert.True(daemon.WaitForLogCount("browser policy repaired (Brave)", repairs + 1), daemon.LogText());
    }

    // A company value in Brave's key beside a wrong TorDisabled: the company value is kept and only TorDisabled is put right.
    [Fact]
    public void CompanyValueBesideAWrongTorDisabled_IsKeptWhileTorDisabledIsPutRight()
    {
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.RegistryPath, """
            { "SOFTWARE\\Policies\\BraveSoftware\\Brave": { "HomepageLocation": { "type": "string", "value": "https://intranet.example.org" }, "TorDisabled": { "type": "dword", "value": 0 } } }
            """));

        Assert.True(Wait.Until(() => BraveTorDisabledIsRight(daemon), RepairSeconds), daemon.Registry().ToJsonString());

        var registry = daemon.Registry();
        Expected.AssertValue(registry, Expected.BraveKey, "HomepageLocation", "string", "\"https://intranet.example.org\"");
        Expected.AssertAdultFilterValues(registry);
    }

    // A TorDisabled in Chrome's key is not SiteBlock's (only Brave owns it): it is left exactly as it is, also through the uninstall.
    [Fact]
    public void TorDisabledInChromesKey_IsLeftAloneThroughRepairPassesAndTheUninstall()
    {
        using var daemon = SandboxDaemon.Start(prepare: d => File.WriteAllText(d.RegistryPath, """
            { "SOFTWARE\\Policies\\Google\\Chrome": { "TorDisabled": { "type": "dword", "value": 0 } } }
            """));
        daemon.SetupAndAdd("reddit.com");
        int repairs = daemon.LogCount("browser policy repaired (Chrome)");
        Thread.Sleep(TimeSpan.FromSeconds(1));

        Expected.AssertValue(daemon.Registry(), Expected.ChromeKey, "TorDisabled", "dword", "0");
        Assert.Equal(repairs, daemon.LogCount("browser policy repaired (Chrome)"));

        Assert.True(daemon.Send(new Request(Command.Uninstall, Password: Defaults.Password)).Ok);
        Assert.Equal(0, daemon.WaitForExit(15));
        var chrome = Expected.Key(daemon.Registry(), Expected.ChromeKey);
        Assert.NotNull(chrome);
        Assert.Single(chrome!);
        Expected.AssertValue(daemon.Registry(), Expected.ChromeKey, "TorDisabled", "dword", "0");
    }

    // The uninstall removes TorDisabled with the other owned values. With a company value left, Brave's key stays holding exactly that value; with nothing left, the key is deleted.
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Uninstall_RemovesTorDisabledAndDeletesBravesKeyOnlyWhenNothingElseIsLeft(bool companyValue)
    {
        using var daemon = SandboxDaemon.Start(prepare: d =>
        {
            if (companyValue) File.WriteAllText(d.RegistryPath, """{ "SOFTWARE\\Policies\\BraveSoftware\\Brave": { "HomepageLocation": { "type": "string", "value": "https://intranet.example.org" } } }""");
        });
        daemon.SetupAndAdd("reddit.com");
        Assert.True(Wait.Until(() => BraveTorDisabledIsRight(daemon), RepairSeconds), daemon.Registry().ToJsonString());

        Assert.True(daemon.Send(new Request(Command.Uninstall, Password: Defaults.Password)).Ok);
        // TorDisabled stays during the uninstall wait: the adult filter is on until the uninstall finishes.
        Assert.True(BraveTorDisabledIsRight(daemon), daemon.Registry().ToJsonString());
        Assert.Equal(0, daemon.WaitForExit(15));

        var registry = daemon.Registry();
        Assert.Null(Expected.Key(registry, Expected.Blocklist(Expected.BraveKey)));
        if (companyValue)
        {
            var brave = Expected.Key(registry, Expected.BraveKey);
            Assert.NotNull(brave);
            Assert.Equal(["HomepageLocation"], brave!.Select(entry => entry.Key));
        }
        else
        {
            Assert.Null(Expected.Key(registry, Expected.BraveKey));
        }
    }
}

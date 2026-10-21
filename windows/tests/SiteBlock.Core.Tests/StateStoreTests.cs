using System.Text.Json.Nodes;
using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// state.json on disk. Expected values come from 01-overview-and-data.md § Data Model (field names and shapes), 02-core-components.md § Models and Protocol Types
// (an unreadable temporaryUnblock record is dropped while the rest loads) and § StateStore, and 06-windows.md § SiteBlock.Core (JSON: camelCase names, sorted keys,
// missing optional keys read as null, unknown keys ignored, a file written by either version reads in the other).
public sealed class StateStoreTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "sbq-store-" + Guid.NewGuid().ToString("N")[..10]);

    public StateStoreTests() => Directory.CreateDirectory(_folder);

    public void Dispose()
    {
        if (Directory.Exists(_folder)) Directory.Delete(_folder, recursive: true);
    }

    private string StatePath => Path.Combine(_folder, "state.json");

    // A state file as the Swift daemon writes it, built by hand from the data model: every field name as the design spells it.
    private const string SwiftWrittenState = """
        {
          "blocked" : [
            { "domain" : "reddit.com", "hosts" : [ "reddit.com", "www.reddit.com" ],
              "temporaryUnblock" : { "startsIn" : { "remainingSeconds" : 0, "totalSeconds" : 3600 }, "window" : { "remainingSeconds" : 900.5, "totalSeconds" : 1800 } } },
            { "domain" : "x.com", "hosts" : [ "x.com" ], "pendingUnblock" : { "remainingSeconds" : 120, "totalSeconds" : 1800 } }
          ],
          "blockedPaths" : [ { "domain" : "youtube.com", "path" : "/shorts", "temporaryUnblock" : { "startsIn" : { "remainingSeconds" : 50, "totalSeconds" : 60 }, "window" : { "remainingSeconds" : 300, "totalSeconds" : 300 } } } ],
          "delaySeconds" : 1800,
          "failedAttempts" : 2,
          "lockout" : { "remainingSeconds" : 10, "totalSeconds" : 900 },
          "passwordHash" : { "algorithm" : "pbkdf2-sha256", "hash" : "aGFzaA==", "iterations" : 210000, "salt" : "c2FsdA==" },
          "pendingDelayChange" : { "countdown" : { "remainingSeconds" : 30, "totalSeconds" : 1800 }, "newDelaySeconds" : 600 },
          "savedDNS" : { "{4D36E972-E325-11CE-BFC1-08002BE10318}" : [ "192.168.1.1" ] },
          "uninstalling" : false,
          "version" : 1,
          "someFutureField" : { "ignored" : true }
        }
        """;

    [Fact]
    public void Load_AStateWrittenWithTheDesignFieldNames_ReadsEveryField()
    {
        File.WriteAllText(StatePath, SwiftWrittenState);

        var state = new StateStore(StatePath).Load();

        Assert.NotNull(state);
        Assert.Equal(1800, state!.DelaySeconds);
        Assert.Equal(2, state.FailedAttempts);
        Assert.Equal("pbkdf2-sha256", state.PasswordHash!.Algorithm);
        Assert.Equal(210_000, state.PasswordHash.Iterations);
        Assert.Equal(["reddit.com", "x.com"], state.Blocked.Select(site => site.Domain));
        var open = state.Blocked[0].TemporaryUnblock!;
        Assert.True(open.IsOpen);
        Assert.Equal(900.5, open.Window.RemainingSeconds);
        Assert.Equal(120, state.Blocked[1].PendingUnblock!.RemainingSeconds);
        Assert.Null(state.Blocked[1].TemporaryUnblock);
        var rule = Assert.Single(state.BlockedPaths!);
        Assert.Equal("/shorts", rule.Path);
        Assert.False(rule.TemporaryUnblock!.IsOpen);
        Assert.Equal(600, state.PendingDelayChange!.NewDelaySeconds);
        Assert.Equal(10, state.Lockout!.RemainingSeconds);
        Assert.Equal(["192.168.1.1"], state.SavedDNS!["{4D36E972-E325-11CE-BFC1-08002BE10318}"]);
        Assert.False(File.Exists(StatePath + ".corrupt"));
        Assert.Empty(Directory.GetFiles(_folder, "state.json.corrupt-*"));
    }

    [Fact]
    public void SaveThenLoad_KeepsAWaitingAndAnOpenTemporaryUnblockWithTheirRemainingTimes()
    {
        var state = PersistedState.Fresh(1800);
        state.PasswordHash = new PasswordHash("pbkdf2-sha256", 210_000, "c2FsdA==", "aGFzaA==");
        state.Blocked.Add(new BlockedSite("reddit.com", ["reddit.com"], temporaryUnblock: new TemporaryUnblock(new Countdown(1234.25, 3600), new Countdown(1800))));
        state.Blocked.Add(new BlockedSite("x.com", ["x.com"], temporaryUnblock: new TemporaryUnblock(new Countdown(0, 60), new Countdown(77.75, 300))));
        state.BlockedPaths = [new BlockedPath("youtube.com", "/Shorts", temporaryUnblock: new TemporaryUnblock(new Countdown(5, 10), new Countdown(300)))];
        var store = new StateStore(StatePath, Path.Combine(_folder, "backup.json"));

        store.Save(state);
        var loaded = new StateStore(StatePath).Load()!;

        Assert.Equal(1234.25, loaded.Blocked[0].TemporaryUnblock!.StartsIn.RemainingSeconds);
        Assert.Equal(3600, loaded.Blocked[0].TemporaryUnblock!.StartsIn.TotalSeconds);
        Assert.False(loaded.Blocked[0].TemporaryUnblock!.IsOpen);
        Assert.True(loaded.Blocked[1].TemporaryUnblock!.IsOpen);
        Assert.Equal(77.75, loaded.Blocked[1].TemporaryUnblock!.Window.RemainingSeconds);
        Assert.Equal("/Shorts", loaded.BlockedPaths!.Single().Path);
        Assert.Equal(5, loaded.BlockedPaths!.Single().TemporaryUnblock!.StartsIn.RemainingSeconds);
        Assert.Equal(File.ReadAllText(StatePath), File.ReadAllText(Path.Combine(_folder, "backup.json")));
    }

    [Fact]
    public void Save_WritesTheDesignFieldNamesInSortedOrder()
    {
        var state = PersistedState.Fresh(1800);
        state.Blocked.Add(new BlockedSite("reddit.com", ["reddit.com"], pendingUnblock: new Countdown(60)));

        new StateStore(StatePath).Save(state);

        var root = (JsonObject)JsonNode.Parse(File.ReadAllText(StatePath))!;
        var keys = root.Select(entry => entry.Key).ToList();
        Assert.Equal(keys.Order(StringComparer.Ordinal), keys);
        Assert.Contains("delaySeconds", keys);
        Assert.Contains("failedAttempts", keys);
        Assert.Contains("uninstalling", keys);
        Assert.Contains("blocked", keys);
        var site = (JsonObject)root["blocked"]![0]!;
        Assert.Equal("reddit.com", (string?)site["domain"]);
        Assert.Equal(60, (double)site["pendingUnblock"]!["remainingSeconds"]!);
        Assert.Equal(60, (double)site["pendingUnblock"]!["totalSeconds"]!);
        var siteKeys = site.Select(entry => entry.Key).ToList();
        Assert.Equal(siteKeys.Order(StringComparer.Ordinal), siteKeys);
    }

    [Fact]
    public void Load_ATemporaryUnblockMissingItsWindow_IsDroppedWhileTheRestLoadsAndTheFileIsNotSetAside()
    {
        File.WriteAllText(StatePath, """
            {
              "version": 1, "delaySeconds": 1800, "failedAttempts": 0, "uninstalling": false,
              "blocked": [
                { "domain": "reddit.com", "hosts": ["reddit.com"], "temporaryUnblock": { "startsIn": { "remainingSeconds": 10, "totalSeconds": 10 } } },
                { "domain": "x.com", "hosts": ["x.com"], "temporaryUnblock": "garbage" }
              ],
              "blockedPaths": [ { "domain": "youtube.com", "path": "/shorts", "temporaryUnblock": { "window": { "remainingSeconds": 1, "totalSeconds": 1 } } } ]
            }
            """);

        var state = new StateStore(StatePath).Load();

        Assert.NotNull(state);
        Assert.Equal(["reddit.com", "x.com"], state!.Blocked.Select(site => site.Domain));
        Assert.All(state.Blocked, site => Assert.Null(site.TemporaryUnblock));
        Assert.Null(state.BlockedPaths!.Single().TemporaryUnblock);
        Assert.Empty(Directory.GetFiles(_folder, "state.json.corrupt-*"));
    }

    [Fact]
    public void Load_AFileWithoutTheOptionalKeys_ReadsThemAsNull()
    {
        File.WriteAllText(StatePath, """{ "version": 1, "delaySeconds": 900, "failedAttempts": 0, "uninstalling": false, "blocked": [ { "domain": "reddit.com", "hosts": ["reddit.com"] } ] }""");

        var state = new StateStore(StatePath).Load();

        Assert.NotNull(state);
        Assert.Equal(900, state!.DelaySeconds);
        Assert.Null(state.PasswordHash);
        Assert.Null(state.SavedDNS);
        Assert.True(state.BlockedPaths is null || state.BlockedPaths.Count == 0);
        Assert.Null(state.Blocked.Single().TemporaryUnblock);
        Assert.Empty(Directory.GetFiles(_folder, "state.json.corrupt-*"));
    }

    [Fact]
    public void Load_AnEmptyObject_IsSetAsideAsCorruptAndTheBackupIsUsed()
    {
        string backup = Path.Combine(_folder, "backup.json");
        var good = PersistedState.Fresh(1800);
        good.Blocked.Add(new BlockedSite("reddit.com", ["reddit.com"]));
        new StateStore(StatePath, backup).Save(good);
        File.WriteAllText(StatePath, "{}");

        var state = new StateStore(StatePath, backup).Load();

        Assert.Equal("reddit.com", state!.Blocked.Single().Domain);
        Assert.Single(Directory.GetFiles(_folder, "state.json.corrupt-*"));
        Assert.False(File.Exists(StatePath));
    }
}

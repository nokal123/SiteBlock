import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/01-overview-and-data.md § Data Model (PersistedState: "`blockedPaths` ... Optional in the file (an older
// state.json without it decodes as no path rules)"; BlockedPath) and 02-core-components.md § StateStore.

// A temporary folder that is removed afterwards.
private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siteblock-pathstate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

// A state.json exactly as the INSTALLED daemon writes it today: the sorted-key JSON the encoder produces, with every field of the PersistedState of that
// release including `savedDNS` (the adult content filter had been added) and with NO `blockedPaths` key. It is typed out here, not produced by the
// current encoder, so it stays an old-format file whatever PersistedState does. The CRITICAL property: a daemon that upgrades over this file must load
// it with every site intact, instead of treating it as corrupt, setting it aside and starting with an empty block list.
private let installedDaemonStateJSON = """
{"blocked":[{"domain":"youtube.com","hosts":["youtube.com","www.youtube.com","youtu.be"],"pendingUnblock":{"remainingSeconds":600.25,"totalSeconds":1800}},{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"]},{"domain":"example.com","hosts":["example.com"]}],"delaySeconds":3600,"failedAttempts":1,"passwordHash":{"algorithm":"pbkdf2-sha256","hash":"aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g=","iterations":210000,"salt":"c2FsdHNhbHRzYWx0c2FsdA=="},"savedDNS":{"A1B2":["192.168.1.1"],"C3D4":[]},"uninstalling":false,"version":1}
"""

@Suite struct PathRuleStateTests {
    @Test func theInstalledDaemonsStateFileDecodesWithEverySiteIntactAndNoPathRules() throws {
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(installedDaemonStateJSON.utf8))
        #expect(state.blockedPaths == nil)
        #expect(state.blocked.map(\.domain) == ["youtube.com", "reddit.com", "example.com"])
        #expect(state.blocked[0].hosts == ["youtube.com", "www.youtube.com", "youtu.be"])
        #expect(state.blocked[0].pendingUnblock == Countdown(remainingSeconds: 600.25, totalSeconds: 1800))
        #expect(state.delaySeconds == 3600 && state.failedAttempts == 1 && state.version == 1)
        #expect(state.passwordHash?.iterations == 210_000)
        #expect(state.savedDNS == ["A1B2": ["192.168.1.1"], "C3D4": []])
    }

    // The path that matters: the daemon calls StateStore.load at startup. The file must come back with its sites, must not be renamed to
    // state.json.corrupt-*, and must not be rewritten by the load.
    @Test func loadingTheInstalledDaemonsFileKeepsEverySiteAndSetsNothingAside() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data(installedDaemonStateJSON.utf8).write(to: url)
            let loaded = try #require(StateStore(url: url).load(), "the installed daemon's state file was treated as corrupt and its sites were lost")
            #expect(loaded.blocked.map(\.domain) == ["youtube.com", "reddit.com", "example.com"])
            #expect(loaded.blockedPaths == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["state.json"], "nothing may be set aside or created")
            #expect(try Data(contentsOf: url) == Data(installedDaemonStateJSON.utf8), "a load must not rewrite the file")
        }
    }

    // The same through the backup copy, which the installed daemon also wrote in the old format.
    @Test func theInstalledDaemonsBackupFileLoadsWhenThePrimaryIsMissing() throws {
        try withTempDirectory { dir in
            let backup = dir.appendingPathComponent("state.backup.json")
            try Data(installedDaemonStateJSON.utf8).write(to: backup)
            let loaded = try #require(StateStore(url: dir.appendingPathComponent("state.json"), backupURL: backup).load())
            #expect(loaded.blocked.count == 3)
        }
    }

    // After the old file is loaded, a rule can be added and saved, and the next load returns both the old sites and the new rule.
    @Test func aRuleAddedToALoadedOldFileSurvivesASaveAndALoad() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data(installedDaemonStateJSON.utf8).write(to: url)
            let store = StateStore(url: url)
            var state = try #require(store.load())
            state.blockedPaths = [BlockedPath(domain: "youtube.com", path: "/shorts"), BlockedPath(domain: "x.com", path: "/Home", pendingUnblock: Countdown(remainingSeconds: 5.5, totalSeconds: 10))]
            try store.save(state)
            let reloaded = try #require(StateStore(url: url).load())
            #expect(reloaded == state)
            #expect(reloaded.blocked.map(\.domain) == ["youtube.com", "reddit.com", "example.com"])
            #expect(reloaded.blockedPaths?.map(\.path) == ["/shorts", "/Home"], "the case of a path is kept")
            #expect(reloaded.blockedPaths?[1].pendingUnblock == Countdown(remainingSeconds: 5.5, totalSeconds: 10))
        }
    }

    // The engine started from the old file works, and the first rule it adds goes into the state.
    @Test func anEngineStartedFromTheOldFileAcceptsARuleAndReportsItInTheSnapshot() throws {
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(installedDaemonStateJSON.utf8))
        let engine = Engine(state: state, policy: designPolicy)
        #expect(engine.send(.status).status?.blockedPaths == [])
        expectSuccess(engine.send(.addPath, domain: "x.com/Home"))
        #expect(engine.send(.status).status?.blockedPaths?.map(\.rule) == ["x.com/Home"])
        // A rule on a site the old file already blocks as a whole is refused: the whole site covers it.
        expectFailure(engine.send(.addPath, domain: "reddit.com/r/all"), .alreadyBlocked)
        #expect(engine.state.blocked.count == 3)
    }

    // Only the field added later is optional: a file missing a first-release field is still damaged.
    @Test(arguments: ["blocked", "delaySeconds", "failedAttempts", "uninstalling", "version"])
    func aFileMissingAFirstReleaseFieldIsStillCorrupt(missing: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(installedDaemonStateJSON.utf8)) as? [String: Any])
        object.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONCoding.decoder.decode(PersistedState.self, from: data) }
    }

    // A state with rules writes them under the key `blockedPaths`, each with domain, path and the optional countdown; a state without writes no such key.
    @Test func aStateWithRulesEncodesThemUnderBlockedPathsAndAStateWithoutLeavesTheKeyOut() throws {
        var state = PersistedState.fresh()
        state.blockedPaths = [BlockedPath(domain: "youtube.com", path: "/shorts")]
        let object = try #require(try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(state)) as? [String: Any])
        let rules = try #require(object["blockedPaths"] as? [[String: Any]])
        #expect(rules.count == 1)
        #expect(rules[0]["domain"] as? String == "youtube.com" && rules[0]["path"] as? String == "/shorts")
        #expect(rules[0]["pendingUnblock"] == nil)
        let plain = try #require(try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(PersistedState.fresh())) as? [String: Any])
        #expect(plain["blockedPaths"] == nil, "a state without rules stays readable by a daemon that predates them")
    }

    // An empty list in the file is a valid state with no rules.
    @Test func anEmptyBlockedPathsListDecodesAsNoRules() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(installedDaemonStateJSON.utf8)) as? [String: Any])
        object["blockedPaths"] = [Any]()
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(state.blockedPaths == [])
        #expect(state.blocked.count == 3)
    }

    // A rule with a damaged field makes the file damaged (the rule needs both a domain and a path), rather than silently dropping the rule.
    @Test(arguments: ["domain", "path"])
    func aRuleMissingARequiredFieldMakesTheFileUndecodable(missing: String) throws {
        var rule: [String: Any] = ["domain": "youtube.com", "path": "/shorts"]
        rule.removeValue(forKey: missing)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(installedDaemonStateJSON.utf8)) as? [String: Any])
        object["blockedPaths"] = [rule]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONCoding.decoder.decode(PersistedState.self, from: data) }
    }
}

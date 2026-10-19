import Foundation
import Testing
import SiteBlockCore

// Saving and loading temporary unblocks. Expected values come from Design Plans/01-overview-and-data.md § Data Model (BlockedSite.temporaryUnblock and
// BlockedPath.temporaryUnblock: "Optional in the file ... a missing key must never make the file count as corrupt, because that would discard the block list";
// TemporaryUnblock: two countdowns, `isOpen` and `isFinished` computed and not stored) and 02-core-components.md § StateStore ("The temporaryUnblock key on a site
// or path rule is not required: a file without it decodes with nil"). Every test that touches files uses a real temporary folder and the real StateStore.

// A temporary folder that is removed afterwards.
private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siteblock-tempunblock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

// A state.json exactly as a daemon from before temporary unblocks wrote it: sorted-key JSON with sites and path rules, a permanent unblock on one site and one rule, the
// password hash, savedDNS, and NO `temporaryUnblock` key anywhere. It is typed out here, not produced by today's encoder, so it stays an old-format file whatever PersistedState does.
// The CRITICAL property: a daemon that starts on this file must keep every site and rule instead of treating the file as corrupt and starting with an empty block list.
private let stateJSONWithoutTheKey = """
{"blocked":[{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"],"pendingUnblock":{"remainingSeconds":600.25,"totalSeconds":1800}},{"domain":"example.com","hosts":["example.com","www.example.com"]}],"blockedPaths":[{"domain":"youtube.com","path":"/shorts"},{"domain":"x.com","path":"/Home","pendingUnblock":{"remainingSeconds":5.5,"totalSeconds":10}}],"delaySeconds":3600,"failedAttempts":1,"passwordHash":{"algorithm":"pbkdf2-sha256","hash":"aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g=","iterations":210000,"salt":"c2FsdHNhbHRzYWx0c2FsdA=="},"savedDNS":{"A1B2":["192.168.1.1"]},"uninstalling":false,"version":1}
"""

// A state holding all four shapes: a site and a rule that wait, and a site and a rule that are open, with fractional remaining times (a stored remainder is a Double).
private func stateWithTemporaryUnblocks() -> PersistedState {
    let waiting = TemporaryUnblock(startsIn: Countdown(remainingSeconds: 123.456789, totalSeconds: 3600), window: Countdown(remainingSeconds: 1800, totalSeconds: 1800))
    let open = TemporaryUnblock(startsIn: Countdown(remainingSeconds: 0, totalSeconds: 3600), window: Countdown(remainingSeconds: 612.25, totalSeconds: 1800))
    let sites = [BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], temporaryUnblock: waiting), BlockedSite(domain: "example.com", hosts: ["example.com"], temporaryUnblock: open), BlockedSite(domain: "plain.example", hosts: ["plain.example"])]
    let rules = [BlockedPath(domain: "youtube.com", path: "/shorts", temporaryUnblock: waiting), BlockedPath(domain: "x.com", path: "/Home", temporaryUnblock: open), BlockedPath(domain: "y.example", path: "/a")]
    return PersistedState(blocked: sites, delaySeconds: 3600, blockedPaths: rules)
}

@Suite struct TemporaryUnblockPersistenceTests {
    // The key is optional: a file written without it decodes with nil on every site and rule, and everything else in the file is kept as it was.
    @Test func aStateTextWithoutTheTemporaryUnblockKeyDecodesWithNilAndKeepsTheBlockList() throws {
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(stateJSONWithoutTheKey.utf8))
        #expect(state.blocked.map(\.domain) == ["reddit.com", "example.com"])
        #expect(state.blocked.map(\.hosts) == [["reddit.com", "www.reddit.com"], ["example.com", "www.example.com"]])
        #expect(state.blocked.allSatisfy { $0.temporaryUnblock == nil })
        #expect(state.blockedPaths?.map(\.path) == ["/shorts", "/Home"])
        #expect(state.blockedPaths?.allSatisfy { $0.temporaryUnblock == nil } == true)
        #expect(state.blocked.first?.pendingUnblock == Countdown(remainingSeconds: 600.25, totalSeconds: 1800))
        #expect(state.blockedPaths?.last?.pendingUnblock == Countdown(remainingSeconds: 5.5, totalSeconds: 10))
        #expect(state.delaySeconds == 3600 && state.failedAttempts == 1 && state.passwordHash?.iterations == 210_000 && state.savedDNS == ["A1B2": ["192.168.1.1"]])
    }

    // The path that matters: the daemon calls StateStore.load at startup. The file must come back with its sites and rules, must not be renamed to state.json.corrupt-*, and must not be rewritten by the load.
    @Test func loadingAFileWithoutTheKeyKeepsEverythingAndSetsNothingAside() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data(stateJSONWithoutTheKey.utf8).write(to: url)
            let loaded = try #require(StateStore(url: url).load(), "a file without the temporaryUnblock key was treated as corrupt and the block list was lost")
            #expect(loaded.blocked.map(\.domain) == ["reddit.com", "example.com"] && loaded.blockedPaths?.count == 2)
            #expect(loaded.blocked.allSatisfy { $0.temporaryUnblock == nil } && loaded.blockedPaths?.allSatisfy { $0.temporaryUnblock == nil } == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["state.json"], "nothing may be set aside or created")
            #expect(try Data(contentsOf: url) == Data(stateJSONWithoutTheKey.utf8), "a load must not rewrite the file")
        }
    }

    // The same through the backup copy when the primary file is missing.
    @Test func aBackupWithoutTheKeyLoadsWhenThePrimaryIsMissing() throws {
        try withTempDirectory { dir in
            let backup = dir.appendingPathComponent("state.backup.json")
            try Data(stateJSONWithoutTheKey.utf8).write(to: backup)
            let loaded = try #require(StateStore(url: dir.appendingPathComponent("state.json"), backupURL: backup).load())
            #expect(loaded.blocked.count == 2 && loaded.blockedPaths?.count == 2)
        }
    }

    // After the old file has been loaded, a temporary unblock can be added and saved, and the next load returns the old data and the new unblock.
    @Test func aTemporaryUnblockAddedToALoadedOldFileSurvivesASaveAndALoad() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data(stateJSONWithoutTheKey.utf8).write(to: url)
            let store = StateStore(url: url)
            var state = try #require(store.load())
            state.blocked[1].temporaryUnblock = TemporaryUnblock(startsIn: Countdown(seconds: 3600), window: Countdown(seconds: 900))
            state.blockedPaths?[0].temporaryUnblock = TemporaryUnblock(startsIn: Countdown(remainingSeconds: 0, totalSeconds: 3600), window: Countdown(remainingSeconds: 10.5, totalSeconds: 900))
            try store.save(state)
            let reloaded = try #require(StateStore(url: url).load())
            #expect(reloaded == state)
            #expect(reloaded.blocked[0].pendingUnblock == Countdown(remainingSeconds: 600.25, totalSeconds: 1800), "the old data is intact")
        }
    }

    // 05 § Unit Tests: "a state holding a waiting and an open temporary unblock survives save then load with the same remaining times".
    @Test func aWaitingAndAnOpenTemporaryUnblockSurviveSaveAndLoadWithTheSameRemainingTimes() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url, backupURL: dir.appendingPathComponent("backup.json"))
            let state = stateWithTemporaryUnblocks()
            try store.save(state)
            let loaded = try #require(StateStore(url: url).load())
            #expect(loaded == state)
            let waiting = loaded.blocked[0].temporaryUnblock
            #expect(waiting?.startsIn.remainingSeconds == 123.456789 && waiting?.startsIn.totalSeconds == 3600)
            #expect(waiting?.window.remainingSeconds == 1800 && waiting?.window.totalSeconds == 1800)
            #expect(waiting?.isOpen == false && waiting?.isFinished == false)
            let open = loaded.blocked[1].temporaryUnblock
            #expect(open?.startsIn.remainingSeconds == 0 && open?.window.remainingSeconds == 612.25 && open?.window.totalSeconds == 1800)
            #expect(open?.isOpen == true && open?.isFinished == false)
            #expect(loaded.blocked[2].temporaryUnblock == nil && loaded.blockedPaths?[2].temporaryUnblock == nil)
            #expect(loaded.blockedPaths?[0].temporaryUnblock == waiting && loaded.blockedPaths?[1].temporaryUnblock == open)
            // The backup copy holds the same data.
            let fromBackup = try #require(StateStore(url: dir.appendingPathComponent("missing.json"), backupURL: dir.appendingPathComponent("backup.json")).load())
            #expect(fromBackup == state)
        }
    }

    // 01 § Data Model, TemporaryUnblock: "isOpen: Bool (computed, not stored)" and "isFinished (computed, not stored)". The stored object holds exactly the two countdowns, each with its two fields.
    @Test func theStoredTemporaryUnblockHoldsExactlyTheTwoCountdowns() throws {
        let data = try JSONCoding.encoder.encode(stateWithTemporaryUnblocks())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sites = try #require(object["blocked"] as? [[String: Any]])
        let temp = try #require(sites[0]["temporaryUnblock"] as? [String: Any])
        #expect(Set(temp.keys) == ["startsIn", "window"], "got keys \(temp.keys.sorted())")
        let startsIn = try #require(temp["startsIn"] as? [String: Any])
        #expect(Set(startsIn.keys) == ["remainingSeconds", "totalSeconds"])
        #expect(startsIn["remainingSeconds"] as? Double == 123.456789 && startsIn["totalSeconds"] as? Double == 3600)
        let window = try #require(temp["window"] as? [String: Any])
        #expect(window["remainingSeconds"] as? Double == 1800 && window["totalSeconds"] as? Double == 1800)
        let rules = try #require(object["blockedPaths"] as? [[String: Any]])
        #expect(Set(try #require(rules[1]["temporaryUnblock"] as? [String: Any]).keys) == ["startsIn", "window"])
    }

    // An entry without a temporary unblock writes no key for it (the key is optional in the file), so a file stays readable by a daemon from before the field.
    @Test func anEntryWithoutATemporaryUnblockWritesNoKeyForIt() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(stateWithTemporaryUnblocks())) as? [String: Any])
        let sites = try #require(object["blocked"] as? [[String: Any]])
        let rules = try #require(object["blockedPaths"] as? [[String: Any]])
        #expect(sites[2]["temporaryUnblock"] == nil && rules[2]["temporaryUnblock"] == nil)
        #expect(sites[0]["temporaryUnblock"] != nil && rules[1]["temporaryUnblock"] != nil)
    }

    // A state typed by hand from the design's field names decodes into the matching values, in all three phases (waiting, open, and the stored shape of a finished one).
    @Test func aTemporaryUnblockWrittenByHandFromTheDesignDecodes() throws {
        let text = """
        {"blocked":[{"domain":"a.example","hosts":["a.example"],"temporaryUnblock":{"startsIn":{"remainingSeconds":90.5,"totalSeconds":120},"window":{"remainingSeconds":300,"totalSeconds":300}}},{"domain":"b.example","hosts":["b.example"],"temporaryUnblock":{"startsIn":{"remainingSeconds":0,"totalSeconds":120},"window":{"remainingSeconds":299.5,"totalSeconds":300}}},{"domain":"c.example","hosts":["c.example"],"temporaryUnblock":{"startsIn":{"remainingSeconds":0,"totalSeconds":120},"window":{"remainingSeconds":0,"totalSeconds":300}}},{"domain":"d.example","hosts":["d.example"],"temporaryUnblock":null}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}
        """
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(text.utf8))
        let temps = state.blocked.map(\.temporaryUnblock)
        #expect(temps[0] == TemporaryUnblock(startsIn: Countdown(remainingSeconds: 90.5, totalSeconds: 120), window: Countdown(remainingSeconds: 300, totalSeconds: 300)))
        #expect(temps[0]?.isOpen == false && temps[0]?.isFinished == false)
        #expect(temps[1]?.isOpen == true && temps[1]?.isFinished == false)
        #expect(temps[2]?.isOpen == false && temps[2]?.isFinished == true)
        #expect(temps[3] == nil, "an explicit null is the same as a missing key")
    }

    // 01 § Data Model: isOpen is "startsIn.remainingSeconds <= 0 and window.remainingSeconds > 0", isFinished is "both <= 0". All four combinations, and the boundary just above 0.
    @Test(arguments: [(5.0, 5.0, false, false), (0.000001, 5.0, false, false), (0.0, 5.0, true, false), (0.0, 0.000001, true, false), (0.0, 0.0, false, true), (5.0, 0.0, false, false), (0.000001, 0.0, false, false)])
    func isOpenAndIsFinishedFollowTheDesignsDefinitions(starts: Double, window: Double, open: Bool, finished: Bool) {
        let temp = TemporaryUnblock(startsIn: Countdown(remainingSeconds: starts, totalSeconds: 10), window: Countdown(remainingSeconds: window, totalSeconds: 10))
        #expect(temp.isOpen == open && temp.isFinished == finished, "starts \(starts), window \(window)")
    }

    // A file missing a field the first release required is still corrupt: only the temporaryUnblock key became optional.
    @Test(arguments: ["blocked", "delaySeconds", "failedAttempts", "uninstalling", "version"])
    func theRequiredFieldsAreStillRequired(missing: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(stateJSONWithoutTheKey.utf8)) as? [String: Any])
        object.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONCoding.decoder.decode(PersistedState.self, from: data) }
    }

    // 02 § Models and Protocol Types: "A `temporaryUnblock` object that is present but cannot be read (for example it lacks `startsIn` or `window`) is dropped, decoding as `nil`, and the rest of the file loads. A file that fails to load is set
    // aside as corrupt, which could take the block list with it, while dropping the record only means the site or rule stays blocked." An earlier version of this test expected such a file not to decode; the design was changed to the rule above.
    // The same damaged value is put on a site and on a path rule, next to a site and a rule that are fine.
    static let unreadableValues = [
        #"{"startsIn":{"remainingSeconds":1,"totalSeconds":2}}"#,
        #"{"window":{"remainingSeconds":1,"totalSeconds":2}}"#,
        "{}", "5", #""soon""#, "[1,2]", "true",
        #"{"startsIn":{"remainingSeconds":"x","totalSeconds":2},"window":{"remainingSeconds":1,"totalSeconds":2}}"#,
        #"{"startsIn":{"remainingSeconds":1},"window":{"remainingSeconds":1,"totalSeconds":2}}"#,
    ]

    // A state text with `value` as the temporaryUnblock of site a.example and of rule c.example/x, a plain site b.example and a plain rule d.example/y.
    static func stateText(withTemporaryUnblock value: String) -> String {
        #"{"blocked":[{"domain":"a.example","hosts":["a.example","www.a.example"],"temporaryUnblock":"# + value + #"},{"domain":"b.example","hosts":["b.example"]}],"blockedPaths":[{"domain":"c.example","path":"/x","temporaryUnblock":"# + value + #"},{"domain":"d.example","path":"/y"}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}"#
    }

    @Test(arguments: TemporaryUnblockPersistenceTests.unreadableValues)
    func aTemporaryUnblockThatCannotBeReadIsDroppedAndTheBlockListIsKept(value: String) throws {
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(Self.stateText(withTemporaryUnblock: value).utf8))
        #expect(state.blocked.map(\.domain) == ["a.example", "b.example"] && state.blocked.map(\.hosts) == [["a.example", "www.a.example"], ["b.example"]])
        #expect(state.blockedPaths?.map(\.domain) == ["c.example", "d.example"] && state.blockedPaths?.map(\.path) == ["/x", "/y"])
        #expect(state.blocked.allSatisfy { $0.temporaryUnblock == nil }, "the unreadable record is dropped")
        #expect(state.blockedPaths?.allSatisfy { $0.temporaryUnblock == nil } == true, "also on a path rule")
        #expect(state.delaySeconds == 60 && state.version == 1)
        // The site and the rule are still blocked: the engine started from this state holds their names and entries.
        let engine = Engine(state: state, policy: temporaryPolicy)
        #expect(engine.blockedHosts == ["a.example", "b.example", "www.a.example"])
        #expect(engine.browserBlockEntries.chrome == ["a.example", "b.example", "c.example/x", "d.example/y"])
    }

    // Through the real StateStore: the file loads, nothing is set aside as corrupt, and the load does not rewrite it.
    @Test(arguments: TemporaryUnblockPersistenceTests.unreadableValues)
    func loadingAFileWithAnUnreadableTemporaryUnblockKeepsEverythingAndSetsNothingAside(value: String) throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let text = Self.stateText(withTemporaryUnblock: value)
            try Data(text.utf8).write(to: url)
            let loaded = try #require(StateStore(url: url).load(), "a file with an unreadable temporaryUnblock was treated as corrupt and the block list was lost")
            #expect(loaded.blocked.map(\.domain) == ["a.example", "b.example"] && loaded.blockedPaths?.count == 2)
            #expect(loaded.blocked.allSatisfy { $0.temporaryUnblock == nil } && loaded.blockedPaths?.allSatisfy { $0.temporaryUnblock == nil } == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["state.json"], "nothing may be set aside or created")
            #expect(try Data(contentsOf: url) == Data(text.utf8), "a load must not rewrite the file")
        }
    }

    // Dropping is per record: a readable record next to an unreadable one keeps its times.
    @Test func aReadableRecordNextToAnUnreadableOneIsKept() throws {
        let text = #"{"blocked":[{"domain":"a.example","hosts":["a.example"],"temporaryUnblock":{"startsIn":{"remainingSeconds":9.5,"totalSeconds":60},"window":{"remainingSeconds":300,"totalSeconds":300}}},{"domain":"b.example","hosts":["b.example"],"temporaryUnblock":{"window":{"remainingSeconds":1,"totalSeconds":2}}}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}"#
        let state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(text.utf8))
        #expect(state.blocked[0].temporaryUnblock == TemporaryUnblock(startsIn: Countdown(remainingSeconds: 9.5, totalSeconds: 60), window: Countdown(remainingSeconds: 300, totalSeconds: 300)))
        #expect(state.blocked[1].temporaryUnblock == nil)
    }

    // Only the temporaryUnblock record is forgiven. The fields a site and a rule need to exist (their name and hosts, their domain and path) are still required, so a damaged entry still fails the file.
    @Test(arguments: [
        #"{"blocked":[{"hosts":["a.example"]}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}"#,
        #"{"blocked":[{"domain":"a.example"}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}"#,
        #"{"blocked":[],"blockedPaths":[{"path":"/x"}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}"#,
        #"{"blocked":[],"blockedPaths":[{"domain":"c.example"}],"delaySeconds":60,"failedAttempts":0,"uninstalling":false,"version":1}"#,
    ])
    func aSiteOrRuleMissingItsOwnRequiredFieldsStillFailsTheFile(text: String) {
        #expect(throws: (any Error).self) { try JSONCoding.decoder.decode(PersistedState.self, from: Data(text.utf8)) }
    }

    // The engine started from a loaded old file accepts a temporary unblock and reports it in the snapshot.
    @Test func anEngineStartedFromTheOldFileAcceptsATemporaryUnblock() throws {
        var state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(stateJSONWithoutTheKey.utf8))
        state.passwordHash = try PasswordHasher.make(password: rightPassword, iterations: 1000)
        let engine = Engine(state: state, policy: temporaryPolicy)
        expectSuccess(engine.temporarily("example.com", seconds: 900, start: 3600))
        expectSuccess(engine.temporarily("youtube.com/shorts", seconds: 900, start: 3600, rule: true))
        #expect(engine.temporaryStatus(of: "example.com") == TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 900, windowSeconds: 900, isOpen: false))
        #expect(engine.temporaryStatus(ofRule: "youtube.com/shorts") == TemporaryUnblockStatus(opensInSeconds: 3600, secondsRemaining: 900, windowSeconds: 900, isOpen: false))
    }
}

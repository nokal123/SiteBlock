import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § StateStore and 01-overview-and-data.md § Data Model
// (state.json, mode 0600). Every test uses a real temporary folder and the real file system.

// Makes a fresh empty folder under the system temp directory.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("siteblock-statestore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Runs the body with a fresh temp folder and removes the folder afterwards, restoring permissions first so a read-only folder can go.
private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let dir = try makeTempDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

// The permission bits of a file, for example 0o600.
private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
}

private func fileNumber(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

private func names(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

// A state with every field filled in, including fractional countdown values.
private func fullState(delay: Int = 1800, sites: Int = 2) -> PersistedState {
    let hash = PasswordHash(algorithm: "pbkdf2-sha256", iterations: 210_000, salt: "c2FsdHNhbHRzYWx0c2FsdA==", hash: "aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g=")
    var blocked = [BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], pendingUnblock: Countdown(remainingSeconds: 1234.5678901234567, totalSeconds: 1800))]
    for index in 1..<max(sites, 1) { blocked.append(BlockedSite(domain: "site\(index).example.com", hosts: ["site\(index).example.com", "www.site\(index).example.com"])) }
    return PersistedState(passwordHash: hash, blocked: blocked, delaySeconds: delay, pendingDelayChange: PendingDelayChange(newDelaySeconds: 600, countdown: Countdown(remainingSeconds: 0.1 + 0.2, totalSeconds: 1800)), pendingUninstall: Countdown(remainingSeconds: 42, totalSeconds: 1800), recovery: Countdown(seconds: 172_800), failedAttempts: 3, lockout: Countdown(remainingSeconds: 12.5, totalSeconds: 900), uninstalling: true)
}

@Suite struct StateStoreTests {
    // MARK: load

    @Test func loadOfAMissingFileReturnsNilAndCreatesNothing() throws {
        try withTempDirectory { dir in
            let store = StateStore(url: dir.appendingPathComponent("state.json"))
            #expect(store.load() == nil)
            let listing = try names(in: dir)
            #expect(listing.isEmpty)
        }
    }

    @Test func loadReturnsTheSameStateThatSaveWrote() throws {
        try withTempDirectory { dir in
            let store = StateStore(url: dir.appendingPathComponent("state.json"))
            let state = fullState()
            try store.save(state)
            #expect(store.load() == state)
            #expect(StateStore(url: dir.appendingPathComponent("state.json")).load() == state, "a new store object must read the same file")
        }
    }

    @Test func aFractionalCountdownSurvivesSaveAndLoadBitForBit() throws {
        try withTempDirectory { dir in
            let store = StateStore(url: dir.appendingPathComponent("state.json"))
            try store.save(fullState())
            let loaded = try #require(store.load())
            #expect(loaded.blocked.first?.pendingUnblock?.remainingSeconds == 1234.5678901234567)
            #expect(loaded.pendingDelayChange?.countdown.remainingSeconds == 0.1 + 0.2)
        }
    }

    @Test func loadDoesNotChangeAValidFile() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            try store.save(fullState())
            let before = try Data(contentsOf: url)
            _ = store.load()
            _ = store.load()
            #expect(try Data(contentsOf: url) == before)
            #expect(try names(in: dir) == ["state.json"])
        }
    }

    // The schema on disk is the design's data model, so a file written by hand from the design must load.
    @Test func loadReadsAFileWrittenByHandFromTheDesignsFieldNames() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let json = """
            {"version":1,"passwordHash":{"algorithm":"pbkdf2-sha256","iterations":210000,"salt":"c2FsdA==","hash":"aGFzaA=="},\
            "blocked":[{"domain":"reddit.com","hosts":["reddit.com","www.reddit.com"],"pendingUnblock":{"remainingSeconds":100.5,"totalSeconds":1800}}],\
            "delaySeconds":1800,"pendingDelayChange":{"newDelaySeconds":600,"countdown":{"remainingSeconds":10,"totalSeconds":1800}},\
            "pendingUninstall":{"remainingSeconds":20,"totalSeconds":1800},"recovery":{"remainingSeconds":30,"totalSeconds":172800},\
            "failedAttempts":2,"lockout":{"remainingSeconds":40,"totalSeconds":900},"uninstalling":true}
            """
            try Data(json.utf8).write(to: url)
            let expected = PersistedState(version: 1, passwordHash: PasswordHash(algorithm: "pbkdf2-sha256", iterations: 210_000, salt: "c2FsdA==", hash: "aGFzaA=="), blocked: [BlockedSite(domain: "reddit.com", hosts: ["reddit.com", "www.reddit.com"], pendingUnblock: Countdown(remainingSeconds: 100.5, totalSeconds: 1800))], delaySeconds: 1800, pendingDelayChange: PendingDelayChange(newDelaySeconds: 600, countdown: Countdown(remainingSeconds: 10, totalSeconds: 1800)), pendingUninstall: Countdown(remainingSeconds: 20, totalSeconds: 1800), recovery: Countdown(remainingSeconds: 30, totalSeconds: 172_800), failedAttempts: 2, lockout: Countdown(remainingSeconds: 40, totalSeconds: 900), uninstalling: true)
            #expect(StateStore(url: url).load() == expected)
        }
    }

    // MARK: save

    @Test func saveCreatesTheFileWithMode0600() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try StateStore(url: url).save(fullState())
            #expect(try mode(of: url) == 0o600)
        }
    }

    // A previous file with wider permissions must not carry them over when it is replaced.
    @Test func saveOverAnExistingWorldReadableFileLeavesMode0600() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try StateStore(url: url).save(fullState())
            #expect(try mode(of: url) == 0o600)
        }
    }

    @Test func everySaveKeepsMode0600AndLeavesNoTemporaryFileBehind() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            for delay in [60, 120, 1800, 3600] {
                try store.save(fullState(delay: delay))
                #expect(try mode(of: url) == 0o600)
                #expect(try names(in: dir) == ["state.json"])
                #expect(store.load()?.delaySeconds == delay)
            }
        }
    }

    // 02-core-components.md: save writes the sorted-keys JSON. The bytes must be the real JSON of the state, in sorted key order.
    @Test func saveWritesSortedKeyJSONOfTheState() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let state = fullState()
            try StateStore(url: url).save(state)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let expected = try encoder.encode(state)
            let written = try Data(contentsOf: url)
            // The design does not say whether a final newline follows the JSON, so one is tolerated.
            #expect(written == expected || written == expected + Data("\n".utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
            #expect(Set(object.keys) == ["version", "passwordHash", "blocked", "delaySeconds", "pendingDelayChange", "pendingUninstall", "recovery", "failedAttempts", "lockout", "uninstalling"])
        }
    }

    // The file is replaced by renaming a finished temporary file over it, so the file's identity (inode) changes on every save.
    // An in-place rewrite would keep the same inode and could be seen half-written.
    @Test func saveReplacesTheFileByRenameInsteadOfRewritingItInPlace() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            try store.save(fullState(delay: 100))
            let first = try fileNumber(of: url)
            try store.save(fullState(delay: 200))
            let second = try fileNumber(of: url)
            #expect(first != second)
            #expect(store.load()?.delaySeconds == 200)
        }
    }

    // The design says each write goes to "a temp file in the same folder" without naming it, so a stale file called
    // state.json.tmp from an older crash is just a stray file. The save must still succeed and produce a whole state.json.
    @Test func saveSucceedsWhenAStrayStateJsonTmpFileIsAlreadyInTheFolder() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data("half-written garbage".utf8).write(to: dir.appendingPathComponent("state.json.tmp"))
            let store = StateStore(url: url)
            try store.save(fullState())
            #expect(store.load() == fullState())
            #expect(try mode(of: url) == 0o600)
        }
    }

    // A save that fails must leave the previous state untouched. A read-only folder makes creating the temporary file fail.
    // Root ignores directory permissions, so under root the folder would stay writable and the save would succeed; the test is
    // reported as skipped there instead of returning early and counting as a pass.
    @Test(.enabled(if: getuid() != 0, "root ignores directory permissions, so a read-only folder would not make the save fail"))
    func aFailedSaveLeavesThePreviousStateIntact() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            let original = fullState(delay: 111)
            try store.save(original)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            #expect(throws: (any Error).self) { try store.save(fullState(delay: 222)) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            #expect(store.load() == original)
            #expect(try names(in: dir) == ["state.json"])
        }
    }

    // MARK: corrupt files

    // 02-core-components.md: an undecodable file is renamed to state.json.corrupt-<unix time> and load returns nil.
    @Test(arguments: [
        ("empty file", Data()),
        ("whitespace only", Data("   \n".utf8)),
        ("not JSON", Data("this is not json".utf8)),
        ("unclosed brace", Data("{".utf8)),
        ("array instead of object", Data("[]".utf8)),
        ("null", Data("null".utf8)),
        ("binary garbage", Data([0xFF, 0xFE, 0x00, 0x01, 0x80])),
        ("wrong field type", Data(#"{"version":1,"blocked":[],"delaySeconds":"soon","failedAttempts":0,"uninstalling":false}"#.utf8)),
        ("blocked is not a list", Data(#"{"version":1,"blocked":"nope","delaySeconds":1800,"failedAttempts":0,"uninstalling":false}"#.utf8)),
    ])
    func loadOfACorruptFileRenamesItAndReturnsNil(label: String, bytes: Data) throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try bytes.write(to: url)
            let before = Date().timeIntervalSince1970
            #expect(StateStore(url: url).load() == nil, "\(label)")
            let after = Date().timeIntervalSince1970
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(label): state.json must have been moved away")
            let allNames = try names(in: dir)
            let corrupt = allNames.filter { $0.hasPrefix("state.json.corrupt-") }
            #expect(corrupt.count == 1, "\(label): \(allNames)")
            #expect(allNames.count == 1)
            guard let name = corrupt.first else { return }
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == bytes, "\(label): the corrupt file's bytes must be kept for inspection")
            let stamp = Double(name.dropFirst("state.json.corrupt-".count))
            #expect(stamp != nil, "\(name) should end in a unix time")
            if let stamp { #expect(stamp >= before - 5 && stamp <= after + 5, "\(name) is not within 5 seconds of now") }
        }
    }

    @Test func loadOfATruncatedValidFileTreatsItAsCorrupt() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let whole = try encoder.encode(fullState())
            let half = whole.prefix(whole.count / 2)
            try half.write(to: url)
            #expect(StateStore(url: url).load() == nil)
            let listing = try names(in: dir)
            #expect(listing.contains { $0.hasPrefix("state.json.corrupt-") })
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    // After a corrupt file is set aside the daemon starts fresh: saving works, loading returns the new state, the old bytes stay.
    @Test func afterACorruptFileIsSetAsideASaveAndLoadWorkNormally() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data("garbage".utf8).write(to: url)
            let store = StateStore(url: url)
            #expect(store.load() == nil)
            try store.save(fullState(delay: 300))
            #expect(store.load()?.delaySeconds == 300)
            #expect(try mode(of: url) == 0o600)
            let corrupt = try names(in: dir).filter { $0.hasPrefix("state.json.corrupt-") }
            #expect(corrupt.count == 1)
        }
    }

    // The point of renaming is to avoid a restart loop: a second corrupt file in the same second must still give nil, not a crash.
    @Test func loadReturnsNilForEachOfTwoCorruptFilesEvenWhenTheyAreSetAsideInTheSameSecond() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            try Data("garbage one".utf8).write(to: url)
            #expect(store.load() == nil)
            try Data("garbage two".utf8).write(to: url)
            #expect(store.load() == nil)
            try store.save(fullState())
            #expect(store.load() == fullState())
        }
    }

    // 02-core-components.md § StateStore: "When a corrupt file is renamed and state.json.corrupt-<unix time> already exists (two corrupt
    // loads in the same second), a counter suffix keeps both files." The three loads below take a few milliseconds, so they almost always
    // share a second, but the check holds either way: nothing may be lost, so three corrupt files must leave three files with their own bytes.
    @Test func threeCorruptLoadsInQuickSuccessionLeaveThreeCorruptFilesEachWithItsOwnBytes() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            let written = [Data("garbage one".utf8), Data("garbage two".utf8), Data("garbage three".utf8)]
            for bytes in written {
                try bytes.write(to: url)
                #expect(store.load() == nil)
            }
            let corrupt = try names(in: dir).filter { $0.hasPrefix("state.json.corrupt-") }
            #expect(corrupt.count == 3, "\(corrupt)")
            let kept = try corrupt.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
            #expect(Set(kept) == Set(written), "every corrupt file's bytes must be kept")
            #expect(try names(in: dir).count == 3)
        }
    }

    // The collision made certain: files already occupy the corrupt-<unix time> name for every second this load could use, with bytes that
    // must survive. The new corrupt file takes the counter name ("...-1", as the design shows) and nothing is overwritten.
    @Test func aCorruptFileWhoseNameIsAlreadyTakenIsKeptUnderACounterSuffixAndTheOlderFileIsNotOverwritten() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let now = Int(Date().timeIntervalSince1970)
            var earlier: [String: Data] = [:]
            for second in (now - 2)...(now + 3) {
                let name = "state.json.corrupt-\(second)"
                let bytes = Data("an earlier corrupt file from second \(second)".utf8)
                try bytes.write(to: dir.appendingPathComponent(name))
                earlier[name] = bytes
            }
            let newest = Data("the newest corrupt bytes".utf8)
            try newest.write(to: url)
            #expect(StateStore(url: url).load() == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            for (name, bytes) in earlier { #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == bytes, "\(name) was overwritten") }
            let corrupt = try names(in: dir).filter { $0.hasPrefix("state.json.corrupt-") }
            #expect(corrupt.count == earlier.count + 1, "\(corrupt)")
            let added = Array(Set(corrupt).subtracting(earlier.keys))
            #expect(added.count == 1)
            let addedName = added.first ?? ""
            #expect(earlier.keys.contains { $0 + "-1" == addedName }, "expected a name like state.json.corrupt-<unix time>-1, got \(addedName)")
            #expect(try Data(contentsOf: dir.appendingPathComponent(addedName)) == newest)
            // A second corrupt file after that one is kept as well.
            let afterwards = Data("one more corrupt file".utf8)
            try afterwards.write(to: url)
            #expect(StateStore(url: url).load() == nil)
            let all = try names(in: dir).filter { $0.hasPrefix("state.json.corrupt-") }
            #expect(all.count == earlier.count + 2)
            #expect(try all.contains { try Data(contentsOf: dir.appendingPathComponent($0)) == afterwards })
            #expect(try Data(contentsOf: dir.appendingPathComponent(addedName)) == newest)
        }
    }

    // MARK: atomicity under concurrent reading

    // 02-core-components.md: the file is "either the old version or the new version, never half-written". A reader that
    // loads continuously while a writer saves states of very different sizes must always get a whole state, and no
    // load may decide the live file is corrupt and move it away.
    @Test func aReaderRunningWhileAWriterSavesAlwaysSeesAWholeState() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let writer = StateStore(url: url)
            let reader = StateStore(url: url)
            let small = fullState(delay: 111, sites: 1)
            let big = fullState(delay: 222, sites: 4000)
            try writer.save(small)
            let done = Locked(false)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                for round in 0..<120 { try? writer.save(round % 2 == 0 ? big : small) }
                done.set(true)
                group.leave()
            }
            var loads = 0
            var failures = 0
            while !done.get() || loads < 50 {
                if let loaded = reader.load(), loaded.delaySeconds == 111 || loaded.delaySeconds == 222 { loads += 1 } else { failures += 1; loads += 1 }
                if failures > 0 { break }
            }
            group.wait()
            #expect(failures == 0, "a load returned nothing or a partial state while a save was running")
            let listing = try names(in: dir)
            #expect(listing.filter { $0.hasPrefix("state.json.corrupt-") }.isEmpty)
            #expect(reader.load() != nil)
        }
    }
}

// Backup copy and hand-edit detection. Expected values come from the updated 02-core-components.md § StateStore:
// load returns the primary when it decodes, otherwise the backup when that decodes, otherwise nil; save writes the primary
// and then the backup, each atomically with mode 0600; matchesLastSave is false when either file is missing or differs
// byte for byte from what this store last wrote.
@Suite struct StateStoreBackupTests {
    // Makes a primary folder and a separate backup folder under one temp folder, runs the body, and cleans up.
    private func withStores(_ body: (_ primary: URL, _ backup: URL) throws -> Void) throws {
        try withTempDirectory { dir in
            let primaryDir = dir.appendingPathComponent("state", isDirectory: true)
            let backupDir = dir.appendingPathComponent("backup", isDirectory: true)
            try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try body(primaryDir.appendingPathComponent("state.json"), backupDir.appendingPathComponent("state.json"))
        }
    }

    @Test func saveWritesBothFilesWithTheSameStateAndMode0600() throws {
        try withStores { primary, backup in
            try StateStore(url: primary, backupURL: backup).save(fullState())
            #expect(StateStore(url: primary).load() == fullState())
            #expect(StateStore(url: backup).load() == fullState())
            #expect(try mode(of: primary) == 0o600)
            #expect(try mode(of: backup) == 0o600)
            #expect(try Data(contentsOf: primary) == Data(contentsOf: backup))
        }
    }

    @Test func saveLeavesNoTemporaryFilesInEitherFolder() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            for delay in [60, 120, 1800] { try store.save(fullState(delay: delay)) }
            #expect(try names(in: primary.deletingLastPathComponent()) == ["state.json"])
            #expect(try names(in: backup.deletingLastPathComponent()) == ["state.json"])
        }
    }

    @Test func loadWithNoPrimaryFileReturnsTheBackupsState() throws {
        try withStores { primary, backup in
            try StateStore(url: primary, backupURL: backup).save(fullState(delay: 777))
            try FileManager.default.removeItem(at: primary)
            #expect(StateStore(url: primary, backupURL: backup).load()?.delaySeconds == 777)
        }
    }

    @Test func loadWithACorruptPrimaryReturnsTheBackupsStateAndSetsTheCorruptPrimaryAside() throws {
        try withStores { primary, backup in
            try StateStore(url: primary, backupURL: backup).save(fullState(delay: 888))
            try Data("garbage".utf8).write(to: primary)
            #expect(StateStore(url: primary, backupURL: backup).load() == fullState(delay: 888))
            #expect(!FileManager.default.fileExists(atPath: primary.path))
            let listing = try names(in: primary.deletingLastPathComponent())
            #expect(listing.filter { $0.hasPrefix("state.json.corrupt-") }.count == 1)
        }
    }

    @Test func loadReturnsNilWhenThePrimaryIsMissingAndTheBackupIsMissingOrCorrupt() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            #expect(store.load() == nil)
            try Data("garbage".utf8).write(to: backup)
            #expect(store.load() == nil)
        }
    }

    @Test func loadReturnsNilWhenBothFilesAreCorrupt() throws {
        try withStores { primary, backup in
            try Data("garbage one".utf8).write(to: primary)
            try Data("garbage two".utf8).write(to: backup)
            #expect(StateStore(url: primary, backupURL: backup).load() == nil)
        }
    }

    @Test func loadPrefersAValidPrimaryOverADifferentOrBrokenOrMissingBackup() throws {
        try withStores { primary, backup in
            try StateStore(url: backup).save(fullState(delay: 100))
            try StateStore(url: primary).save(fullState(delay: 200))
            #expect(StateStore(url: primary, backupURL: backup).load()?.delaySeconds == 200)
            try Data("garbage".utf8).write(to: backup)
            #expect(StateStore(url: primary, backupURL: backup).load()?.delaySeconds == 200)
            try FileManager.default.removeItem(at: backup)
            #expect(StateStore(url: primary, backupURL: backup).load()?.delaySeconds == 200)
        }
    }

    @Test func eachSaveRefreshesTheBackupToTheNewestState() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState(delay: 100))
            try store.save(fullState(delay: 200))
            #expect(StateStore(url: backup).load()?.delaySeconds == 200)
        }
    }

    // The primary is written first, so even when the backup cannot be written the primary already holds the new state. But the save
    // still throws: 02-core-components.md § StateStore says "save throws when either the primary or the backup write fails, so the
    // daemon knows to retry". The earlier version of this test swallowed the error with `try?`, which would have passed even if save
    // reported success for a failed backup write. matchesLastSave must then say false, because the backup holds the older bytes.
    // Root ignores directory permissions, so the test is skipped under root instead of returning early and counting as a pass.
    @Test(.enabled(if: getuid() != 0, "root ignores directory permissions, so a read-only backup folder would not make the write fail"))
    func thePrimaryIsWrittenEvenWhenTheBackupFolderCannotBeWrittenButSaveThrows() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState(delay: 100))
            #expect(store.matchesLastSave())
            let backupDir = backup.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backupDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir.path) }
            #expect(throws: (any Error).self) { try store.save(fullState(delay: 200)) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir.path)
            #expect(StateStore(url: primary).load()?.delaySeconds == 200)
            #expect(StateStore(url: backup).load()?.delaySeconds == 100, "the backup keeps its last good copy")
            #expect(!store.matchesLastSave(), "the backup is behind the primary, so the caller must be told to write it again")
            // The retry the daemon would make: once the folder is writable again the same save succeeds and both files agree.
            try store.save(fullState(delay: 200))
            #expect(store.matchesLastSave())
            #expect(StateStore(url: backup).load()?.delaySeconds == 200)
        }
    }

    // MARK: matchesLastSave

    @Test func matchesLastSaveIsTrueRightAfterASave() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState())
            #expect(store.matchesLastSave())
            try store.save(fullState(delay: 4000))
            #expect(store.matchesLastSave())
        }
    }

    // Changing 1800 to 1801 keeps the file the same length, so only a byte comparison (not a size check) notices.
    @Test func matchesLastSaveIsFalseWhenThePrimaryIsEditedWithoutChangingItsLength() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState(delay: 1800))
            let original = try Data(contentsOf: primary)
            let text = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"delaySeconds\":1800", with: "\"delaySeconds\":1801")
            #expect(Data(text.utf8).count == original.count && Data(text.utf8) != original)
            try Data(text.utf8).write(to: primary)
            #expect(!store.matchesLastSave())
        }
    }

    @Test func matchesLastSaveIsFalseWhenTheBackupIsEdited() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState())
            try Data("{}".utf8).write(to: backup)
            #expect(!store.matchesLastSave())
        }
    }

    @Test func matchesLastSaveIsFalseWhenEitherFileIsMissing() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState())
            let saved = try Data(contentsOf: primary)
            try FileManager.default.removeItem(at: primary)
            #expect(!store.matchesLastSave())
            try saved.write(to: primary)
            #expect(store.matchesLastSave())
            try FileManager.default.removeItem(at: backup)
            #expect(!store.matchesLastSave())
        }
    }

    // Only the bytes count: rewriting identical bytes (a new modification time) is not an edit, and a new save puts things right.
    @Test func matchesLastSaveIgnoresARewriteOfIdenticalBytesAndRecoversAfterANewSave() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            try store.save(fullState())
            try Data(contentsOf: primary).write(to: primary)
            #expect(store.matchesLastSave())
            try Data("tampered".utf8).write(to: primary)
            #expect(!store.matchesLastSave())
            try store.save(fullState())
            #expect(store.matchesLastSave())
        }
    }

    @Test func matchesLastSaveWithoutABackupWatchesThePrimaryAlone() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(url: url)
            try store.save(fullState())
            #expect(store.matchesLastSave())
            try Data("tampered".utf8).write(to: url)
            #expect(!store.matchesLastSave())
            try store.save(fullState())
            try FileManager.default.removeItem(at: url)
            #expect(!store.matchesLastSave())
        }
    }
}

// 02-core-components.md § StateStore: matchesLastSave "false when either file is missing or its bytes differ from what this store last
// wrote or loaded. A store that has neither saved nor loaded returns true."
@Suite struct StateStoreMatchesLastSaveTests {
    private func withStores(_ body: (_ primary: URL, _ backup: URL) throws -> Void) throws {
        try withTempDirectory { dir in
            let primaryDir = dir.appendingPathComponent("state", isDirectory: true)
            let backupDir = dir.appendingPathComponent("backup", isDirectory: true)
            try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try body(primaryDir.appendingPathComponent("state.json"), backupDir.appendingPathComponent("state.json"))
        }
    }

    @Test func aStoreThatHasNeitherSavedNorLoadedMatchesWhateverIsOnDisk() throws {
        try withStores { primary, backup in
            #expect(StateStore(url: primary, backupURL: backup).matchesLastSave(), "no files at all")
            try Data("anything at all".utf8).write(to: primary)
            #expect(StateStore(url: primary, backupURL: backup).matchesLastSave(), "a primary this store never wrote or loaded")
            try Data("something else".utf8).write(to: backup)
            #expect(StateStore(url: primary, backupURL: backup).matchesLastSave(), "a backup this store never wrote or loaded")
            #expect(StateStore(url: primary).matchesLastSave(), "a single-file store")
            #expect(StateStore(url: backup.deletingLastPathComponent().appendingPathComponent("never-created.json")).matchesLastSave())
        }
    }

    // A load that finds nothing has not loaded anything, so the store is still fresh.
    @Test func aLoadThatFindsNothingLeavesTheStoreFresh() throws {
        try withStores { primary, backup in
            let store = StateStore(url: primary, backupURL: backup)
            #expect(store.load() == nil)
            #expect(store.matchesLastSave())
        }
    }

    // After a load, the bytes that were loaded are the ones to compare against.
    @Test func afterALoadBothFilesMustHoldTheBytesThatWereLoaded() throws {
        try withStores { primary, backup in
            try StateStore(url: primary, backupURL: backup).save(fullState())
            let loader = StateStore(url: primary, backupURL: backup)
            #expect(loader.load() == fullState())
            #expect(loader.matchesLastSave())
            try Data("tampered".utf8).write(to: backup)
            #expect(!loader.matchesLastSave())
        }
    }

    // A primary that exists with no backup yet: the load succeeds, but the backup is missing, so the caller is told to write it.
    @Test func aLoadWhoseBackupIsMissingReportsAMismatchUntilTheNextSave() throws {
        try withStores { primary, backup in
            try StateStore(url: primary).save(fullState())
            let store = StateStore(url: primary, backupURL: backup)
            #expect(store.load() == fullState())
            #expect(!store.matchesLastSave())
            try store.save(fullState())
            #expect(store.matchesLastSave())
        }
    }

    // A load that fell back to the backup: the primary is missing, so the caller is told to write it back.
    @Test func aLoadThatFellBackToTheBackupReportsAMismatchUntilThePrimaryIsWrittenBack() throws {
        try withStores { primary, backup in
            try StateStore(url: primary, backupURL: backup).save(fullState(delay: 321))
            try FileManager.default.removeItem(at: primary)
            let store = StateStore(url: primary, backupURL: backup)
            #expect(store.load()?.delaySeconds == 321)
            #expect(!store.matchesLastSave())
            try store.save(fullState(delay: 321))
            #expect(store.matchesLastSave())
            #expect(StateStore(url: primary).load()?.delaySeconds == 321)
        }
    }
}

// A tiny thread-safe box for the test's "writer finished" flag.
private final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    // Returns the current value.
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    // Replaces the current value.
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}

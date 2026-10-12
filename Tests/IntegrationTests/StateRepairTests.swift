import Foundation
import SiteBlockCore
import Testing

// The state file (state.json) and its backup copy: self-repair while the daemon runs, recovery after a crash.
// Design: 03-daemon-cli-app.md § DaemonRuntime (startup step 2, tick step 5); 02-core-components.md § StateStore; 01-overview-and-data.md § Threat Model.
@Suite("State file repair and recovery")
struct StateRepairTests {
    // One way of damaging the state files by hand while the daemon runs.
    enum Damage: CaseIterable, CustomTestStringConvertible {
        case stateDeleted, stateEmptied, stateOverwrittenWithBraces, stateOverwrittenWithGarbage, stateTruncated, blocksEditedOut, passwordEditedOut, uninstallingFlagSet, backupDeleted, backupOverwrittenWithBraces, bothDeleted
        var testDescription: String { String(describing: self) }

        // Damages the files of a running daemon.
        func apply(to daemon: SandboxDaemon) throws {
            let state = daemon.statePath
            let backup = daemon.stateBackupPath
            switch self {
            case .stateDeleted: try FileManager.default.removeItem(atPath: state)
            case .stateEmptied: try writeText("", to: state)
            case .stateOverwrittenWithBraces: try writeText("{}", to: state)
            case .stateOverwrittenWithGarbage: try writeText("this is not json {{{", to: state)
            case .stateTruncated:
                let data = try Data(contentsOf: URL(fileURLWithPath: state))
                try data.prefix(data.count / 2).write(to: URL(fileURLWithPath: state))
            case .blocksEditedOut: try editJSONObject(at: state) { $0["blocked"] = [Any]() }
            case .passwordEditedOut: try editJSONObject(at: state) { $0["passwordHash"] = NSNull() }
            case .uninstallingFlagSet: try editJSONObject(at: state) { $0["uninstalling"] = true }
            case .backupDeleted: try FileManager.default.removeItem(atPath: backup)
            case .backupOverwrittenWithBraces: try writeText("{}", to: backup)
            case .bothDeleted:
                try FileManager.default.removeItem(atPath: state)
                try FileManager.default.removeItem(atPath: backup)
            }
        }
    }

    // The task's first extra bullet, widened: deleting or damaging either state file while the daemon runs is repaired within about 1 s, the blocks are kept, and the daemon keeps running and blocking.
    @Test(arguments: Damage.allCases)
    func damagedStateFilesAreRewrittenFromMemoryWithinOneSecond(damage: Damage) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "youtube.com")
            let before = try #require(daemon.stateObject())
            try #require(readJSONObject(daemon.stateBackupPath) != nil, "the backup copy must exist after a command")
            try damage.apply(to: daemon)
            let repaired = waitUntil(timeout: 1.0, interval: 0.01) {
                guard let primary = readJSONObject(daemon.statePath), let backup = readJSONObject(daemon.stateBackupPath) else { return false }
                return primary.isEqual(before) && backup.isEqual(before)
            }
            #expect(repaired != nil, "not repaired within 1 s. state.json: \(readText(daemon.statePath)?.prefix(300) ?? "missing"); backup: \(readText(daemon.stateBackupPath)?.prefix(300) ?? "missing")")
            #expect(permissions(of: daemon.statePath) == 0o600)
            #expect(permissions(of: daemon.stateBackupPath) == 0o600)
            #expect(daemon.isRunning)
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com", "youtube.com"])
            #expect(status.passwordSet)
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["reddit.com", "youtube.com"])))
            #expect(daemon.logContains("state file repaired"), "03 § DaemonRuntime tick step 5 says to log it")
        }
    }

    // 05 Security: the repair must not be needed when nothing was touched, so the log says nothing about repairs after ordinary commands.
    @Test func ordinaryCommandsNeverLogAStateFileRepair() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.add, domain: "youtube.com").requireOK()
            pause(0.8)
            #expect(!daemon.logText().contains("state file repaired"))
        }
    }

    // The task's second extra bullet: after kill -9, deleting state.json and restarting brings the blocks (and the password) back from the backup copy.
    @Test func afterKill9DeletingStateJsonAndRestartingRestoresEverythingFromTheBackup() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "youtube.com")
            try #require(FileManager.default.fileExists(atPath: daemon.stateBackupPath))
            #expect(daemon.kill9() != nil)
            try FileManager.default.removeItem(atPath: daemon.statePath)
            try daemon.start()
            let status = try daemon.status()
            #expect(status.passwordSet, "the password hash must come back with the backup")
            #expect(status.blocked.map(\.domain) == ["reddit.com", "youtube.com"], "blocks come back in the order they were added")
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["reddit.com", "youtube.com"])))
            // The restored password is the real one: the wrong one is refused as a wrong password (not as "not set up"), the right one works.
            let wrong = try daemon.send(.unblock, domain: "reddit.com", password: "not-it-not-it")
            #expect(wrong.errorCode == .wrongPassword)
            try daemon.send(.unblock, domain: "reddit.com", password: SandboxDaemon.password).requireOK()
        }
    }

    // 03 § DaemonRuntime: a daemon that started from the backup writes the state files again (startup writes both when the backup was the source, and the tick repairs a missing file), so state.json is back within 1 s and equals what was lost.
    @Test func stateJsonReappearsWithinOneSecondOfARestartFromTheBackup() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let before = try #require(daemon.stateObject())
            daemon.kill9()
            try FileManager.default.removeItem(atPath: daemon.statePath)
            try daemon.start()
            let back = waitUntil(timeout: 1.0, interval: 0.01) { readJSONObject(daemon.statePath)?.isEqual(before) == true }
            #expect(back != nil, "state.json was not recreated from the backup within 1 s")
        }
    }

    // 02 § StateStore.load: a damaged primary is renamed aside as state.json.corrupt-<time> and the backup is used, so a restart after tampering still has every block.
    @Test(arguments: ["not json at all", "{}", "", "{\"version\":1}", "{\"version\":1,\"delaySeconds\":\"soon\"}"])
    func aDamagedPrimaryAfterKill9IsSetAsideAndTheBackupIsUsed(damaged: String) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "youtube.com")
            daemon.kill9()
            try writeText(damaged, to: daemon.statePath)
            try daemon.start()
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com", "youtube.com"], "blocks lost after primary \(damaged.debugDescription)")
            #expect(status.passwordSet)
            let aside = daemon.listing(of: daemon.stateDir).filter { $0.range(of: "^state\\.json\\.corrupt-[0-9]+$", options: .regularExpression) != nil }
            #expect(aside.count == 1, "the damaged file should be kept as state.json.corrupt-<unix time>; folder holds \(daemon.listing(of: daemon.stateDir))")
        }
    }

    // 02 § StateStore.load: when no state can be read at all, the daemon starts fresh instead of crashing in a restart loop.
    @Test(arguments: ["missing", "garbage"])
    func withNoReadableStateTheDaemonStartsFreshInsteadOfCrashing(kind: String) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            // The first start wrote the Private Relay names and logged a repair for it (see logCount); only a repair logged after the restart would be wrong.
            let repairsBeforeRestart = daemon.logCount(of: "hosts file repaired")
            daemon.kill9()
            for path in [daemon.statePath, daemon.stateBackupPath] {
                if kind == "missing" { try FileManager.default.removeItem(atPath: path) } else { try writeText("###", to: path) }
            }
            try daemon.start()
            let status = try daemon.status()
            #expect(status.passwordSet == false)
            #expect(status.blocked.isEmpty)
            #expect(status.delaySeconds == 2, "a fresh state has the policy's default delay")
            #expect(daemon.isRunning)
            // With nothing left to block, the startup pass takes the blocked sites out of the managed section. Design change (01 § How Blocking Works, Adult content filter): the section stays, holding only the Private Relay names.
            #expect(daemon.hostsText() == ExpectedHosts.idleText)
            // 03 § HostsEnforcer step 7: a daemon that started with lost state does not report its removal of blocks as a repair.
            let logged = daemon.logContains("blocks removed from hosts file")
            let log = daemon.logText()
            #expect(logged, "log was:\n\(log)")
            #expect(daemon.logCount(of: "hosts file repaired") == repairsBeforeRestart, "removing blocks because the state was lost is not a repair")
            let reply = try daemon.send(.add, domain: "reddit.com")
            #expect(reply.errorCode == .notSetUp)
            try daemon.setUp()
        }
    }

    // After a crash the socket file is still there but nobody listens. The client must report "not running", and a restart must replace the stale socket instead of failing.
    @Test func aStaleSocketAfterKill9MeansNotRunningAndDoesNotBlockTheRestart() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.kill9()
            #expect(FileManager.default.fileExists(atPath: daemon.socketPath), "kill -9 leaves the socket file behind")
            #expect(throws: ClientError.notRunning) { _ = try daemon.client().send(Request(command: .status)) }
            try daemon.start()
            let status = try daemon.status()
            #expect(status.blocked.map(\.domain) == ["reddit.com"])
        }
    }

    // 03 § DaemonRuntime step 2 / Signals: a graceful stop (SIGTERM) exits with code 0, saves the state, and a restart brings back the password, the blocks and the delay.
    @Test func gracefulStopExitsWithZeroAndARestartKeepsEverything() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com", "youtube.com")
            try daemon.send(.setDelay, password: SandboxDaemon.password, seconds: 300).requireOK()
            let exit = try #require(daemon.terminate())
            #expect(exit.status == 0 && !exit.killedBySignal, "SIGTERM must end the daemon with exit code 0")
            #expect(readJSONObject(daemon.statePath) != nil)
            try daemon.start()
            let status = try daemon.status()
            #expect(status.passwordSet)
            #expect(status.blocked.map(\.domain) == ["reddit.com", "youtube.com"])
            #expect(status.delaySeconds == 300)
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: ["reddit.com", "youtube.com"])))
            let wrong = try daemon.send(.unblock, domain: "youtube.com", password: "wrong-again")
            #expect(wrong.errorCode == .wrongPassword)
        }
    }

    // 02 § HostsFileEditor "Input guard": blocked hosts are reloaded from state.json, so a forged entry must not reach root's hosts file. A hostile host is dropped, and names that are only padded or upper case are cleaned (trimmed and lowercased) and then written.
    @Test func hostNamesForgedIntoTheStateFileNeverProduceUncleanHostsLines() throws {
        let hostile = ["evil.com\n0.0.0.0 bank.com", "has space.example", "", "   ", "#x.example", "bad_underscore.example", "x\u{0}y.example", "ünïcode.example", "a\tb.example"]
        let cleaned = [" padded.example ", "UPPER.example", "ok-name.example"]
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.terminate()
            for path in [daemon.statePath, daemon.stateBackupPath] {
                try editJSONObject(at: path) { object in
                    var sites = object["blocked"] as? [[String: Any]] ?? []
                    sites[0]["hosts"] = (sites[0]["hosts"] as? [String] ?? []) + hostile + cleaned
                    object["blocked"] = sites
                }
            }
            try daemon.start()
            let expectedHosts = ExpectedHosts.expand("reddit.com") + ["padded.example", "upper.example", "ok-name.example"]
            let took = waitUntil(timeout: 1.0, interval: 0.01) { daemon.hostsText() == ExpectedHosts.text(blocking: expectedHosts) }
            #expect(took != nil, "file now:\n\(daemon.hostsText())")
            #expect(!daemon.hostsText().contains("bank.com"))
            for line in HostsView(daemon.hostsText()).managedLines { #expect(InjectionTests.isCleanManagedLine(line), "unclean line \(line.debugDescription)") }
        }
    }

    // 02 § HostsFileEditor "Input guard": "localhost, broadcasthost, or ends in .local or .localhost" are never written, because render step 3 would also delete the stock lines the Mac needs. Such names forged into a blocked site's hosts in state.json (any case, padded) are dropped when the daemon restarts: the hosts file equals the exact expected text and the stock localhost and broadcasthost lines are still there.
    @Test func systemNamesForgedIntoTheStateFileAreDroppedAndTheStockLinesSurvive() throws {
        let forged = ["localhost", "broadcasthost", "printer.local", "x.localhost", "LOCALHOST", " LocalHost ", "BroadcastHost", "Printer.LOCAL", "a.b.localhost"]
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            daemon.terminate()
            for path in [daemon.statePath, daemon.stateBackupPath] {
                try editJSONObject(at: path) { object in
                    var sites = object["blocked"] as? [[String: Any]] ?? []
                    sites[0]["hosts"] = (sites[0]["hosts"] as? [String] ?? []) + forged
                    object["blocked"] = sites
                }
            }
            try daemon.start()
            let expected = ExpectedHosts.text(blocking: ExpectedHosts.expand("reddit.com"))
            let ok = waitUntil(timeout: 1.5, interval: 0.02) { daemon.hostsText() == expected }
            #expect(ok != nil, "file now:\n\(daemon.hostsText())")
            let text = daemon.hostsText()
            for stock in ["127.0.0.1\tlocalhost", "255.255.255.255\tbroadcasthost", "::1             localhost"] {
                #expect(HostsView(text).count(of: stock) == 1, "the stock line \(stock.debugDescription) must survive exactly once")
            }
            for name in ["localhost", "broadcasthost", "printer.local", "x.localhost", "b.localhost"] {
                #expect(!text.lowercased().contains("0.0.0.0 \(name)") && !text.lowercased().contains(":: \(name)"), "\(name) must never be written into the section")
            }
            #expect(HostsView(text).beginCount == 1 && HostsView(text).endCount == 1)
            // The block itself still works.
            #expect(HostsView(text).blocks("reddit.com"))
        }
    }
}

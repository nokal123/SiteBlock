import Foundation
import SiteBlockCore
import Testing

// What the DNS enforcer does after the family DNS provider is switched by an update, against the real siteblockd in sandbox mode.
// Design: 03-daemon-cli-app.md § 11 DNSEnforcer (pass step 1: a service that already has a record keeps its first saved value, so another known provider's servers are never
// recorded as someone's originals; Reachability check: services that hold ANY known provider's list and have a record count as overridden, so a service still on the previous
// provider gets its saved servers back while the family servers do not answer; Uninstall), 02-core-components.md § 15 FamilyDNSProviders (the three known providers and their
// addresses, CleanBrowsing Family active), 01-overview-and-data.md § Fixed Policy Values (the four servers).
//
// "A switch" is simulated the way it happens on a real Mac: a daemon that ran with the previous provider left the services on that provider's four servers and its record in
// the state file. Here the test lets the daemon record the real originals, stops it with SIGKILL, puts the services on another known provider's servers, and starts it again.
// The sandbox stand-ins (root/network-services.json and the root/family-dns-unreachable marker) are described at the top of DNSEnforcerTests.swift.
//
// Every address is typed from the design text, never read from the providers file, so a wrong address in the file fails these tests.

// CleanBrowsing Family Filter, the active provider (02 § 15, 01 § Fixed Policy Values).
private let cleanBrowsing = ["185.228.168.168", "185.228.169.168", "2a0d:2a00:1::", "2a0d:2a00:2::"]
// The two other known providers (02 § 15).
private let cloudflareFamilies = ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]
private let adguardFamily = ["94.140.14.15", "94.140.15.16", "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff"]

// The originals the services start with: a Wi-Fi with a router address set by hand and an Ethernet with nothing set.
private let originals: [String: [String]] = ["WIFI": ["192.168.1.1"], "ETH": []]

// Helpers for the stand-in network settings. The polling lives in methods rather than in closures written inside each test, for the compiler reason given in DNSEnforcerTests.swift.
private extension SandboxDaemon {
    var switchServicesPath: String { root + "/network-services.json" }

    // Replaces the whole stand-in settings file in one step, the way the daemon writes it.
    func writeSwitchServices(_ services: [String: [String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: services, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: switchServicesPath), options: .atomic)
    }

    // The servers of every service in the file, keyed by service ID.
    func allServers() -> [String: [String]] {
        let all = (readJSONObject(switchServicesPath) as? [String: [String: Any]]) ?? [:]
        return all.compactMapValues { $0["servers"] as? [String] }
    }

    // Sets the servers of the named services (keeping their names and everything else), and adds a service when it is new.
    func putServers(_ changes: [String: [String]]) throws {
        var all = (readJSONObject(switchServicesPath) as? [String: [String: Any]]) ?? [:]
        for (id, servers) in changes {
            var entry = all[id] ?? ["name": "Service \(id)"]
            entry["servers"] = servers
            all[id] = entry
        }
        try writeSwitchServices(all)
    }

    // The saved originals in a state file (the primary one by default), or nil when the key is missing.
    func savedOriginals(at path: String? = nil) -> [String: [String]]? {
        readJSONObject(path ?? statePath)?["savedDNS"] as? [String: [String]]
    }

    // Waits until every named service holds exactly the given servers; returns the seconds it took, or nil on timeout.
    func waitForAll(_ expected: [String: [String]], timeout: Double) -> Double? {
        waitUntil(timeout: timeout, interval: 0.01) {
            let now = self.allServers()
            return expected.allSatisfy { now[$0.key] == $0.value }
        }
    }

    // Polls every 2 ms until the named service holds the given servers and returns the saved record read at that same moment, or nil when the servers never appeared.
    func savedOriginalsWhenServersAppear(on id: String, servers: [String], timeout: Double) -> [String: [String]]? {
        let watch = Stopwatch()
        while watch.elapsed < timeout {
            if allServers()[id] == servers { return savedOriginals() ?? [:] }
            pause(0.002)
        }
        return nil
    }

    // Records every distinct value the saved record takes while polling for this long, so a record that is briefly replaced and then put back is still seen.
    func distinctSavedRecords(for seconds: Double) -> [[String: [String]]] {
        var seen: [[String: [String]]] = []
        let watch = Stopwatch()
        while watch.elapsed < seconds {
            let now = savedOriginals() ?? [:]
            if !seen.contains(now) { seen.append(now) }
            pause(0.005)
        }
        return seen
    }

    // Switches the pretend "family servers do not answer" on or off.
    func setUnreachableMarker(_ unreachable: Bool) throws {
        let path = root + "/family-dns-unreachable"
        if unreachable { try Data().write(to: URL(fileURLWithPath: path)) } else { try? FileManager.default.removeItem(atPath: path) }
    }
}

// Starts a sandbox daemon on the two usual services, waits until it has recorded the originals and set CleanBrowsing, stops it with SIGKILL, and runs the body with the daemon stopped.
private func withOverriddenThenStopped<T>(setUp: Bool = false, _ body: (SandboxDaemon) throws -> T) throws -> T {
    try withDaemon(start: false) { daemon in
        try daemon.writeSwitchServices(["WIFI": ["name": "Wi-Fi", "servers": ["192.168.1.1"]], "ETH": ["name": "Ethernet", "servers": [String]()]])
        try daemon.start()
        if setUp { try daemon.setUp() }
        try require(daemon.waitForAll(["WIFI": cleanBrowsing, "ETH": cleanBrowsing], timeout: 3.0) != nil, "the first daemon never set the CleanBrowsing servers: \(daemon.allServers())")
        try require(daemon.savedOriginals() == originals, "the first daemon recorded \(String(describing: daemon.savedOriginals()))")
        daemon.kill9()
        return try body(daemon)
    }
}

@Suite("Family DNS provider switch")
struct FamilyDNSProviderSwitchTests {
    // 03 § 11 pass step 1: a service on a previous provider's four servers is "not exactly the family list", so it gets the active provider's servers; because it already has
    // a record, the record keeps the first saved value and the previous provider's servers are never written into it, neither at the moment the servers change nor later.
    @Test(arguments: [("Cloudflare for Families", cloudflareFamilies), ("AdGuard DNS Family Protection", adguardFamily)])
    func aServiceOnAPreviousProvidersServersIsMovedToCleanBrowsingAndKeepsItsRealOriginal(_ previous: (name: String, servers: [String])) throws {
        try withOverriddenThenStopped { daemon in
            try daemon.putServers(["WIFI": previous.servers, "ETH": previous.servers])
            try daemon.start()

            let recordAtSwitch = daemon.savedOriginalsWhenServersAppear(on: "WIFI", servers: cleanBrowsing, timeout: 3.0)
            #expect(recordAtSwitch == originals, "when CleanBrowsing first appeared after the switch from \(previous.name) the record held \(String(describing: recordAtSwitch))")
            #expect(daemon.waitForAll(["WIFI": cleanBrowsing, "ETH": cleanBrowsing], timeout: 2.0) != nil, "not every service left \(previous.name): \(daemon.allServers())")
            // Later passes (one per tick in a sandbox) keep the services and the record as they are.
            let records = daemon.distinctSavedRecords(for: 1.0)
            #expect(records == [originals], "the record changed after the switch: \(records)")
            #expect(daemon.allServers() == ["WIFI": cleanBrowsing, "ETH": cleanBrowsing])
            #expect(daemon.savedOriginals(at: daemon.stateBackupPath) == originals, "the backup copy of the state must keep the real originals too")
        }
    }

    // 03 § 11 Reachability check: while the family servers do not answer, services that hold any known provider's list and have a record are put back to their saved servers,
    // and the record is kept. A service on Cloudflare's servers WITHOUT a record was never overridden by SiteBlock, so it is left as it is and nothing is recorded for it;
    // that service also shows the restore is about "known list plus record", not about Cloudflare's servers alone.
    @Test func aServiceStillOnThePreviousProviderGetsItsOriginalBackWhenTheFamilyServersStopAnswering() throws {
        try withOverriddenThenStopped { daemon in
            try daemon.putServers(["WIFI": cloudflareFamilies, "ETH": cloudflareFamilies, "OWN": cloudflareFamilies])
            try daemon.setUnreachableMarker(true)
            try daemon.start()

            // "Unreachable" takes 3 failed checks in a row; in a sandbox a check runs every 0.2 s tick, so the restore is due within about a second.
            #expect(daemon.waitForAll(originals, timeout: 5.0) != nil, "the services on Cloudflare's servers did not get their originals back: \(daemon.allServers())\nlog:\n\(daemon.logText())")
            pause(0.8)
            #expect(daemon.allServers() == ["WIFI": ["192.168.1.1"], "ETH": [], "OWN": cloudflareFamilies], "after the restore: \(daemon.allServers())")
            #expect(daemon.savedOriginals() == originals, "the record must be kept and must not gain the service SiteBlock never overrode")
            #expect(daemon.logCount(of: "family DNS unreachable; using the network's own DNS until it answers") == 1, "log:\n\(daemon.logText())")

            // When the family servers answer again, step 1 applies CleanBrowsing from the same record. OWN has no record, so its own servers (Cloudflare's) are recorded first.
            try daemon.setUnreachableMarker(false)
            #expect(daemon.waitForAll(["WIFI": cleanBrowsing, "ETH": cleanBrowsing, "OWN": cleanBrowsing], timeout: 3.0) != nil, "CleanBrowsing was not applied again: \(daemon.allServers())")
            #expect(daemon.savedOriginals() == ["WIFI": ["192.168.1.1"], "ETH": [], "OWN": cloudflareFamilies])
        }
    }

    // Control for the test above: with the family servers answering, a service on another known provider's servers is NOT put back, it is moved to CleanBrowsing. So the
    // restore above happened because of the unreachable answer.
    @Test func whileTheFamilyServersAnswerAServiceOnThePreviousProviderIsNeverPutBack() throws {
        try withOverriddenThenStopped { daemon in
            try daemon.putServers(["WIFI": cloudflareFamilies])
            try daemon.start()
            #expect(daemon.waitForAll(["WIFI": cleanBrowsing], timeout: 3.0) != nil, "Wi-Fi: \(daemon.allServers())")
            pause(0.8)
            #expect(daemon.allServers()["WIFI"] == cleanBrowsing, "the Wi-Fi was put back although the family servers answer")
            #expect(daemon.logCount(of: "family DNS unreachable; using the network's own DNS until it answers") == 0)
        }
    }

    // 03 § 11 Uninstall, end to end after a switch: the uninstaller puts back the servers saved before SiteBlock ever changed anything, not the previous provider's.
    @Test func theUninstallAfterASwitchRestoresTheRealOriginalsNotThePreviousProvider() throws {
        try withOverriddenThenStopped(setUp: true) { daemon in
            try daemon.putServers(["WIFI": cloudflareFamilies, "ETH": cloudflareFamilies])
            try daemon.start()
            try require(daemon.waitForAll(["WIFI": cleanBrowsing, "ETH": cleanBrowsing], timeout: 3.0) != nil, "after the restart: \(daemon.allServers())")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.uninstall, password: SandboxDaemon.password).requireOK()
            let exit = try #require(daemon.waitForExit(timeout: 6.0), "the daemon never exited after the uninstall delay")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.allServers() == ["WIFI": ["192.168.1.1"], "ETH": []], "after the uninstall: \(daemon.allServers())")
        }
    }
}

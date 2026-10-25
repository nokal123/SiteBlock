import Foundation
import SiteBlockCore
import Testing

// The DNS layer of the adult content filter, against the real siteblockd running in sandbox mode.
// Design: 03-daemon-cli-app.md § 11 DNSEnforcer (backend, pass, reachability check, uninstall) and § Daemon Runtime; 01-overview-and-data.md § How Blocking Works (Adult content filter), § Data Model (`savedDNS`), § Fixed Policy Values (the four family servers).
//
// The sandbox stands in for the Mac's network settings with root/network-services.json, a dictionary from service ID to {"name": String, "servers": [String]}. Three optional keys are sandbox test hooks: "enabled": false, "interfaceType": "<type>" (default "Ethernet") and "ignoreWrites": true (the service accepts a change without applying it, like a backend with a bug). The sandbox stands in for the reachability check with the file root/family-dns-unreachable: the family servers count as unreachable exactly while it exists. The file root/family-dns-probe-delay holds a number of seconds that every check sleeps before it answers. The check runs on its own background queue (03 § 11 "Reachability check"), never on the engine queue, and passes read its stored result; until the first check has finished the settings are left as they are. The tick is 0.2 s and, in a sandbox only, the fallback DNS pass and the check both run once per tick, so a repair is seen in a fraction of a second.

// The tests that count checks ("unreachable" needs 3 failed checks in a row, 03 § 11) rely on two properties of the sandbox hooks: the checks run one at a time, and a check looks at the marker file when it starts and then sleeps the delay. So with a delay D, every check that fails because of a marker that appeared at time T started after T and lasts D, and N failed checks cannot end before T + N*D, however the daemon is scheduled. In a sandbox the re-check after a failed check comes one tick later (03 § 11), and a check also starts every tick, so with a long delay the next check starts as soon as the one before it has ended.

// The four family servers in the order the design gives them (01 § Fixed Policy Values).
// The servers the daemon sets are the active provider's in the built-in providers file (FamilyDNSProvidersTests pins which provider that is).
private let familyServers = FamilyDNSProviders.builtIn!.activeProvider.servers
private let unreachableLine = "family DNS unreachable; using the network's own DNS until it answers"

// Helpers that read and edit the stand-in network settings and the saved state.
private extension SandboxDaemon {
    var servicesPath: String { root + "/network-services.json" }
    var unreachableMarkerPath: String { root + "/family-dns-unreachable" }
    var probeDelayPath: String { root + "/family-dns-probe-delay" }

    // Writes the stand-in network settings (a dictionary from service ID to its entry) the way the daemon does, by replacing the file in one step.
    func writeServices(_ services: [String: [String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: services, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: servicesPath), options: .atomic)
    }

    // The entry of one service, or nil when the file or the service is missing.
    func serviceEntry(_ id: String) -> [String: Any]? {
        (readJSONObject(servicesPath) as? [String: Any])?[id] as? [String: Any]
    }

    // The DNS servers one service has right now, or nil when the service does not exist.
    func servers(of id: String) -> [String]? {
        serviceEntry(id)?["servers"] as? [String]
    }

    // Changes the servers of one service the way a person (or another program) would, keeping the rest of the file.
    func setServers(of id: String, to servers: [String]) throws {
        var all = (readJSONObject(servicesPath) as? [String: [String: Any]]) ?? [:]
        all[id]?["servers"] = servers
        try writeServices(all)
    }

    // Adds a service to the file, keeping the others.
    func addService(_ id: String, name: String, servers: [String]) throws {
        var all = (readJSONObject(servicesPath) as? [String: [String: Any]]) ?? [:]
        all[id] = ["name": name, "servers": servers]
        try writeServices(all)
    }

    // The saved original servers in a state file (the primary by default), or nil when the key is missing.
    func savedDNS(at path: String? = nil) -> [String: [String]]? {
        readJSONObject(path ?? statePath)?["savedDNS"] as? [String: [String]]
    }

    // Waits until every named service holds exactly the given servers; returns the seconds it took, or nil on timeout. The polling lives in this method rather than in a closure written inside each test, because the Swift 6.2 compiler on this Mac mis-compiled such nested closures in these tests (the condition was never evaluated and the wait returned at once).
    func waitForServers(_ expected: [String: [String]], timeout: Double = 2.0) -> Double? {
        waitUntil(timeout: timeout, interval: 0.01) { expected.allSatisfy { self.servers(of: $0.key) == $0.value } }
    }

    // Waits until every named service holds exactly the four family servers.
    func waitForFamily(_ ids: [String], timeout: Double = 3.0) -> Double? {
        waitForServers(Dictionary(uniqueKeysWithValues: ids.map { ($0, familyServers) }), timeout: timeout)
    }

    // Polls every 2 ms until the service holds the family servers and, in the same instant, reads the saved record from the state file. Returns what the record held at that moment, or nil when the servers never appeared.
    func savedDNSWhenFamilyServersFirstAppear(on id: String, timeout: Double = 3.0) -> [String: [String]]? {
        let watch = Stopwatch()
        while watch.elapsed < timeout {
            if isFamily(servers(of: id)) { return savedDNS() ?? [:] }
            pause(0.002)
        }
        return nil
    }

    // Makes every family-DNS check sleep this many seconds before it answers (the sandbox stand-in for a slow network). The file is replaced in one step (write, then rename) so a check that starts at that very moment reads the old number or the new one, never a half-written empty file, which would count as "no delay".
    func setProbeDelay(_ seconds: Double) throws {
        try Data("\(seconds)".utf8).write(to: URL(fileURLWithPath: probeDelayPath), options: .atomic)
    }

    // Polls every 10 ms until the stopwatch reads `seconds` and describes the first moment any of the listed services did not hold exactly the family servers, or returns nil when they held them the whole time. A restore that is undone within a few milliseconds can fall between two polls, so tests that need "never switched" also compare the settings file's identity and read the log. The polling lives here, not in a closure inside a test, for the compiler reason given at waitForServers.
    func firstDepartureFromFamilyServers(_ ids: [String], until seconds: Double, on watch: Stopwatch) -> String? {
        while watch.elapsed < seconds {
            for id in ids where !isFamily(servers(of: id)) { return "at \(watch.elapsed) s \(id) held \(String(describing: servers(of: id)))" }
            pause(0.01)
        }
        return nil
    }

    // Switches the pretend "family servers do not answer" on or off.
    func setFamilyDNSUnreachable(_ unreachable: Bool) throws {
        if unreachable {
            try Data().write(to: URL(fileURLWithPath: unreachableMarkerPath))
        } else {
            try? FileManager.default.removeItem(atPath: unreachableMarkerPath)
        }
    }
}

// True when the service holds exactly the four family servers, in order.
private func isFamily(_ servers: [String]?) -> Bool { servers == familyServers }

// Starts a sandbox daemon on a network with the given services (and optionally with the family servers pretending to be unreachable), runs the body, and always cleans up.
private func withNetwork<T>(_ services: [String: [String: Any]], unreachable: Bool = false, probeDelay: Double? = nil, _ body: (SandboxDaemon) throws -> T) throws -> T {
    try withDaemon(start: false) { daemon in
        try daemon.writeServices(services)
        if unreachable { try daemon.setFamilyDNSUnreachable(true) }
        if let probeDelay { try daemon.setProbeDelay(probeDelay) }
        try daemon.start()
        return try body(daemon)
    }
}

// The usual two services of the tests: Wi-Fi with a router's address set by hand, and Ethernet with nothing set.
private let wifiAndEthernet: [String: [String: Any]] = [
    "WIFI": ["name": "Wi-Fi", "servers": ["192.168.1.1"]],
    "ETH": ["name": "Ethernet", "servers": [String]()],
]

@Suite("Adult filter DNS layer")
struct DNSEnforcerTests {
    static let password = SandboxDaemon.password

    // MARK: first override

    // 03 § 11 pass step 1 and 01 § Data Model (`savedDNS`): every service whose servers are not the family list gets them, and the servers it had before are recorded first. This happens at startup, with no password set yet (the filter does not wait for one). The Wi-Fi's own name and settings stay; an empty list in the record means "none set by hand".
    @Test func theFirstOverrideSavesTheOriginalsAndSetsTheFamilyServersOnEveryService() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            // The first reachability check starts at once and its result schedules the first pass, so both services are overridden and recorded a moment after startup. (That the record is written BEFORE the servers are replaced is checked by aNewServiceIsOverriddenAndItsOriginalsAreSaved, whose override happens in a later pass that a test can watch.)
            #expect(daemon.waitForFamily(["WIFI"], timeout: 3.0) != nil, "the Wi-Fi never got the family servers: \(String(describing: daemon.serviceEntry("WIFI")))")
            #expect(daemon.waitForFamily(["ETH"], timeout: 2.0) != nil, "Ethernet: \(String(describing: daemon.serviceEntry("ETH")))")
            #expect(daemon.serviceEntry("WIFI")?["name"] as? String == "Wi-Fi", "the rest of the entry must stay")
            let status = try daemon.status()
            #expect(status.passwordSet == false, "the filter must not wait for a password")
            #expect(daemon.savedDNS() == ["WIFI": ["192.168.1.1"], "ETH": []])
            #expect(daemon.savedDNS(at: daemon.stateBackupPath) == ["WIFI": ["192.168.1.1"], "ETH": []], "the backup copy of the state holds the originals too")
            #expect(daemon.logContains("DNS settings set to the family servers for 2 network services"), "log:\n\(daemon.logText())")
        }
    }

    // A service that is already on the family servers needs no change and no record, and nothing about it is logged.
    @Test func aServiceAlreadyOnTheFamilyServersIsNotRecordedOrChanged() throws {
        try withNetwork(["MINE": ["name": "Mine", "servers": familyServers]]) { daemon in
            pause(1.0)
            #expect(daemon.servers(of: "MINE") == familyServers)
            #expect(daemon.savedDNS() == nil, "nothing was overridden, so nothing is recorded")
            #expect(!daemon.logText().contains("DNS settings"), "log:\n\(daemon.logText())")
        }
    }

    // MARK: tamper repair

    // 03 § 11: "a hand edit in System Settings ... is undone". A service set to other servers is set back to the family servers, the record keeps the FIRST original (not the hand-edited value), and the pass is logged as a repair.
    @Test func aHandEditIsRepairedAndTheFirstSavedOriginalIsKept() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            let repairsBefore = daemon.logCount(of: "DNS settings repaired")
            try daemon.setServers(of: "WIFI", to: ["9.9.9.9"])
            let repaired = daemon.waitForFamily(["WIFI"], timeout: 2.0)
            #expect(repaired != nil, "the hand-edited servers were not replaced: \(String(describing: daemon.servers(of: "WIFI")))")
            #expect(daemon.savedDNS()?["WIFI"] == ["192.168.1.1"], "the record must keep the first original, not the edited value")
            #expect(daemon.logContains("DNS settings repaired"))
            #expect(daemon.logCount(of: "DNS settings repaired") == repairsBefore + 1)
        }
    }

    // Emptying a service by hand (back to "automatic") is also undone.
    @Test func removingTheServersByHandIsRepaired() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI"], timeout: 3.0) != nil)
            try daemon.setServers(of: "WIFI", to: [])
            #expect(daemon.waitForFamily(["WIFI"], timeout: 2.0) != nil)
            #expect(daemon.savedDNS()?["WIFI"] == ["192.168.1.1"])
        }
    }

    // The family list must match exactly, in order: the same four servers in another order are not "right" and are set again.
    @Test func theFamilyServersInTheWrongOrderAreSetAgain() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI"], timeout: 3.0) != nil)
            try daemon.setServers(of: "WIFI", to: familyServers.reversed())
            #expect(daemon.waitForFamily(["WIFI"], timeout: 2.0) != nil)
        }
    }

    // MARK: new services

    // 03 § 11 step 1: "A service that appears later (a new adapter) is handled the same way": overridden, and its own originals recorded next to the others.
    @Test func aNewServiceIsOverriddenAndItsOriginalsAreSaved() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            try daemon.addService("USB", name: "USB LAN", servers: ["8.8.8.8", "8.8.4.4"])
            // The record is polled at the very moment the family servers first appear on the new service: the originals must already be on disk then, because they are written down BEFORE they are replaced.
            let savedWhenFirstSeen = daemon.savedDNSWhenFamilyServersFirstAppear(on: "USB", timeout: 2.0)
            #expect(savedWhenFirstSeen != nil, "the new service stayed on \(String(describing: daemon.servers(of: "USB")))")
            #expect(savedWhenFirstSeen == ["WIFI": ["192.168.1.1"], "ETH": [], "USB": ["8.8.8.8", "8.8.4.4"]], "when the family servers first appeared the state file held \(String(describing: savedWhenFirstSeen))")
            #expect(daemon.savedDNS() == ["WIFI": ["192.168.1.1"], "ETH": [], "USB": ["8.8.8.8", "8.8.4.4"]], "state: \(readText(daemon.statePath) ?? "nil")")
        }
    }

    // MARK: skipped services

    // 03 § 11 Backend: services that are disabled, or whose interface is a VPN type (PPP, IPSec, L2TP, VPN), are left alone and are not recorded; the ordinary service next to them is overridden.
    @Test(arguments: ["PPP", "IPSec", "L2TP", "VPN"])
    func aDisabledServiceAndAVPNServiceAreLeftAlone(vpnType: String) throws {
        let services: [String: [String: Any]] = [
            "OK": ["name": "Wi-Fi", "servers": ["192.168.1.1"]],
            "OFF": ["name": "Old Ethernet", "servers": ["10.0.0.1"], "enabled": false],
            "VPN": ["name": "Work VPN", "servers": ["10.1.1.1"], "interfaceType": vpnType],
        ]
        try withNetwork(services) { daemon in
            #expect(daemon.waitForFamily(["OK"], timeout: 3.0) != nil)
            pause(0.8)
            #expect(daemon.servers(of: "OFF") == ["10.0.0.1"], "a disabled service was changed")
            #expect(daemon.servers(of: "VPN") == ["10.1.1.1"], "a \(vpnType) service was changed")
            #expect(daemon.savedDNS() == ["OK": ["192.168.1.1"]], "only the service that was changed is recorded")
        }
    }

    // MARK: reachability

    // 03 § 11 "Reachability check": when neither family server answers, nothing is overridden and nothing is recorded, and the log says so once however many passes run (the tick is 0.2 s, so about five run in a second). The other layers stay on: the hosts file keeps its section. When the servers answer again, they are applied at once and the log says that, and the unreachable line is not written again.
    @Test func whenTheFamilyServersAreUnreachableNothingIsOverriddenAndWhenTheyAnswerAgainTheyAre() throws {
        try withNetwork(wifiAndEthernet, unreachable: true) { daemon in
            pause(1.2)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"], "the Wi-Fi was changed although the family servers do not answer")
            #expect(daemon.servers(of: "ETH") == [])
            #expect(daemon.savedDNS() == nil, "nothing was overridden, so nothing may be recorded")
            #expect(daemon.logCount(of: unreachableLine) == 1, "the unreachable line must be logged once per change; log:\n\(daemon.logText())")
            #expect(daemon.hostsText() == ExpectedHosts.idleText, "the hosts layer stays on while DNS is skipped")

            try daemon.setFamilyDNSUnreachable(false)
            #expect(daemon.waitForFamily(["WIFI", "ETH"], timeout: 2.0) != nil, "the family servers were not applied once they answered")
            #expect(daemon.savedDNS() == ["WIFI": ["192.168.1.1"], "ETH": []])
            #expect(daemon.logContains("family DNS answers again; DNS settings set to the family servers for 2 network services"), "log:\n\(daemon.logText())")
            #expect(daemon.logCount(of: unreachableLine) == 1)
        }
    }

    // 03 § 11: if services are already overridden when the family servers stop answering (the Mac joined a Wi-Fi with a sign-in page), their saved servers are put back and the record is KEPT; when the servers answer again, the family servers are applied again from the same record. Coming back is not a "repair" (nobody tampered), and the unreachable line is logged once for the whole outage.
    @Test func unreachableWhileOverriddenPutsTheOriginalsBackKeepsTheRecordAndReappliesWhenReachable() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            let record: [String: [String]] = ["WIFI": ["192.168.1.1"], "ETH": []]
            try #require(daemon.savedDNS() == record)
            let repairsBefore = daemon.logCount(of: "DNS settings repaired")

            try daemon.setFamilyDNSUnreachable(true)
            let restored = daemon.waitForServers(["WIFI": ["192.168.1.1"], "ETH": []])
            #expect(restored != nil, "the originals were not put back: Wi-Fi \(String(describing: daemon.servers(of: "WIFI"))), Ethernet \(String(describing: daemon.servers(of: "ETH")))")
            pause(0.8)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"] && daemon.servers(of: "ETH") == [], "the services were overridden again while the family servers do not answer")
            #expect(daemon.savedDNS() == record, "the record must be kept while the originals are in place")
            #expect(daemon.logCount(of: unreachableLine) == 1, "log:\n\(daemon.logText())")

            try daemon.setFamilyDNSUnreachable(false)
            #expect(daemon.waitForFamily(["WIFI", "ETH"], timeout: 2.0) != nil, "the family servers were not applied again")
            #expect(daemon.savedDNS() == record, "applying again must not change the first saved originals")
            #expect(daemon.logCount(of: "DNS settings repaired") == repairsBefore, "coming back after an outage is not tampering")
            #expect(daemon.logCount(of: unreachableLine) == 1)

            // A second outage is a new change of state and is logged again.
            try daemon.setFamilyDNSUnreachable(true)
            #expect(daemon.waitForServers(["WIFI": ["192.168.1.1"]], timeout: 2.0) != nil)
            #expect(daemon.logCount(of: unreachableLine) == 2)
        }
    }

    // While the family servers do not answer, a service the user sets by hand is left alone (the network's own DNS stays), and a new service is not overridden either.
    @Test func whileUnreachableNeitherAHandEditNorANewServiceIsOverridden() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI"], timeout: 3.0) != nil)
            try daemon.setFamilyDNSUnreachable(true)
            try #require(daemon.waitForServers(["WIFI": ["192.168.1.1"]], timeout: 2.0) != nil)
            try daemon.setServers(of: "WIFI", to: ["1.2.3.4"])
            try daemon.addService("NEW", name: "New", servers: ["5.6.7.8"])
            pause(1.0)
            #expect(daemon.servers(of: "WIFI") == ["1.2.3.4"])
            #expect(daemon.servers(of: "NEW") == ["5.6.7.8"])
            #expect(daemon.savedDNS()?["NEW"] == nil, "a service that was never overridden must not be recorded")
        }
    }

    // MARK: "unreachable" needs 3 failed checks in a row

    // 03 § 11 "Reachability check": a success counts at once, but the answer only turns to "unreachable" after 3 failed checks in a row, because a single lost reply "must not switch the Mac's DNS back and forth". Here the family servers stop answering for the time of exactly ONE check. The probe delay makes every check take 2 s, and the checks run one after the other on one queue, so two checks never start less than 2 s apart. The marker is created together with the delay and removed 2 s later, so at most one check can start while it exists, and one does, because a check starts within a tick (0.2 s) of the new delay: the margin is about 1.8 s. That check fails and the answer must stay "reachable": the services never leave the family servers, the settings file is never written (a switch back and forth would rewrite it twice), nothing about unreachable or about the servers answering again is logged, and no pass logs a repair. The marker is created BEFORE the delay: a check that starts between the two (a few microseconds) reads the old delay (none) and fails at once, which makes it two failed checks in all and still not three, whereas the other order could let a check start before the marker and sleep through the whole window, so that no check fails at all. The test ends with a lasting outage as a positive control, because "the line was never logged" only proves something if the line IS logged when the servers really are unreachable.
    @Test func aBriefOutageOfOneFailedCheckNeverSwitchesTheServicesBackOrLogsAnything() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            let originals: [String: [String]] = ["WIFI": ["192.168.1.1"], "ETH": []]
            try #require(daemon.savedDNS() == originals)
            // Lets the first pass finish completely before the settings file is fingerprinted.
            pause(0.5)
            let settingsBefore = identity(of: daemon.servicesPath)
            let repairsBefore = daemon.logCount(of: "DNS settings repaired")
            let checkSeconds = 2.0
            let outage = Stopwatch()
            try daemon.setFamilyDNSUnreachable(true)
            try daemon.setProbeDelay(checkSeconds)
            let leftDuringOutage = daemon.firstDepartureFromFamilyServers(["WIFI", "ETH"], until: checkSeconds, on: outage)
            try daemon.setFamilyDNSUnreachable(false)
            try daemon.setProbeDelay(0)
            // The failed check ends up to about 0.2 s after the marker is gone and a successful check follows at once. Watching 1.5 s more covers both, and it covers the moment a one-failure switch would act: right when the failed check ends.
            let leftAfterwards = daemon.firstDepartureFromFamilyServers(["WIFI", "ETH"], until: checkSeconds + 1.5, on: outage)
            #expect(leftDuringOutage == nil, "the services left the family servers during a one-check outage: \(String(describing: leftDuringOutage)); log:\n\(daemon.logText())")
            #expect(leftAfterwards == nil, "the services left the family servers after a one-check outage: \(String(describing: leftAfterwards)); log:\n\(daemon.logText())")
            #expect(identity(of: daemon.servicesPath) == settingsBefore, "the settings file was rewritten although no pass had anything to change")
            #expect(daemon.logCount(of: unreachableLine) == 0, "one failed check was announced as an outage; log:\n\(daemon.logText())")
            #expect(!daemon.logText().contains("family DNS answers again"), "log:\n\(daemon.logText())")
            #expect(daemon.logCount(of: "DNS settings repaired") == repairsBefore)
            #expect(daemon.savedDNS() == originals)

            // Positive control: with the delay gone, checks run once per tick, so a lasting outage is announced after about 0.6 s and the originals come back.
            try daemon.setFamilyDNSUnreachable(true)
            #expect(daemon.waitForServers(originals, timeout: 4.0) != nil, "the originals never came back in a real outage: Wi-Fi \(String(describing: daemon.servers(of: "WIFI")))")
            #expect(daemon.logCount(of: unreachableLine) == 1, "log:\n\(daemon.logText())")
        }
    }

    // 03 § 11: the answer turns to "unreachable" after 3 failed checks in a row. With every check slowed to 1.5 s and the marker created together with the delay, the first failed check starts at most a tick (0.2 s) later, and each next check starts only after the one before it has ended. So three failed checks need at least 4.5 s from the marker (three sleeps of 1.5 s), however the daemon is scheduled, and the answer cannot change before that: one failed check ends at 1.5 s at the earliest and two at 3.0 s. The services must stay on the family servers until then (which also covers the moment when only one check can have completed, and the moment when only two can). Then the originals must come back, and not as late as a fourth failed check could end (6.0 s): the bound 5.7 s leaves about 1.0 s over the expected 4.7 s. The delay file is written BEFORE the marker so that no check can start after the marker and read the old, empty delay: that check would end at once and make the earliest possible restore earlier than the 4.5 s bound.
    @Test func aLastingOutagePutsTheOriginalsBackOnlyAfterThreeFailedChecksHaveEnded() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            let originals: [String: [String]] = ["WIFI": ["192.168.1.1"], "ETH": []]
            try #require(daemon.savedDNS() == originals)
            let checkSeconds = 1.5
            let outage = Stopwatch()
            try daemon.setProbeDelay(checkSeconds)
            try daemon.setFamilyDNSUnreachable(true)
            // The stopwatch started before the marker existed, so it never runs ahead of the three sleeps; 0.05 s is taken off for the clock rounding of the sleep itself.
            let leftEarly = daemon.firstDepartureFromFamilyServers(["WIFI", "ETH"], until: 3 * checkSeconds - 0.05, on: outage)
            #expect(leftEarly == nil, "the services were put back before three failed checks could have ended: \(String(describing: leftEarly)); log:\n\(daemon.logText())")
            #expect(daemon.logCount(of: unreachableLine) == 0, "the outage was announced before three failed checks could have ended; log:\n\(daemon.logText())")

            let latest = 4 * checkSeconds - 0.3
            let restored = daemon.waitForServers(originals, timeout: latest - outage.elapsed)
            let restoredAt = outage.elapsed
            #expect(restored != nil, "the originals were not put back by \(latest) s although three failed checks had ended: Wi-Fi \(String(describing: daemon.servers(of: "WIFI"))), Ethernet \(String(describing: daemon.servers(of: "ETH")))")
            #expect(restoredAt >= 3 * checkSeconds - 0.05, "restored at \(restoredAt) s, before three 1.5 s checks could have ended")
            #expect(daemon.savedDNS() == originals, "the record must be kept")
            #expect(daemon.logContains(unreachableLine), "log:\n\(daemon.logText())")
            #expect(daemon.logCount(of: unreachableLine) == 1)
        }
    }

    // 03 § 11: "A success counts at once". After an outage has been announced and the originals are back, the family servers answer again: ONE successful check must be enough to apply the family servers. The marker is removed and the delay set to 1.5 s, so each check takes 1.5 s; the first successful check starts within a tick and ends about 1.5 s later, the family servers are expected at about 1.8 s, and the bound is 2.7 s. A rule that wanted two successful checks could not finish before 3.0 s (the second success starts only after the first has ended) and one that wanted three not before 4.5 s, so the bound separates them from "at once" with about 0.3 s to spare on one side and 0.9 s on the other. The marker goes first and the delay second: a check that starts between the two sees no marker and no delay, succeeds at once and applies the family servers at once, which still satisfies the bound; the other order could let a check read the marker, sleep 1.5 s over the failure, and push the expected time to about 3.2 s.
    @Test func oneSuccessfulCheckAfterAnOutageAppliesTheFamilyServersAtOnce() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            let originals: [String: [String]] = ["WIFI": ["192.168.1.1"], "ETH": []]
            try #require(daemon.savedDNS() == originals)
            try daemon.setFamilyDNSUnreachable(true)
            try #require(daemon.waitForServers(originals, timeout: 4.0) != nil, "the outage was never acted on: log:\n\(daemon.logText())")
            try #require(daemon.logContains(unreachableLine))
            pause(0.3)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"] && daemon.servers(of: "ETH") == [], "the services were overridden while the outage was still on")

            let checkSeconds = 1.5
            let recovery = Stopwatch()
            try daemon.setFamilyDNSUnreachable(false)
            try daemon.setProbeDelay(checkSeconds)
            let latest = 2 * checkSeconds - 0.3
            let backAfter = daemon.waitForFamily(["WIFI", "ETH"], timeout: latest - recovery.elapsed)
            #expect(backAfter != nil, "the family servers were not applied by \(latest) s after the servers answered again (one successful check ends after about 1.5 s): Wi-Fi \(String(describing: daemon.servers(of: "WIFI"))), Ethernet \(String(describing: daemon.servers(of: "ETH"))); log:\n\(daemon.logText())")
            #expect(daemon.savedDNS() == originals, "applying again must keep the first saved originals")
            #expect(daemon.logContains("family DNS answers again; DNS settings set to the family servers for 2 network services"), "log:\n\(daemon.logText())")
            #expect(daemon.logCount(of: unreachableLine) == 1)
        }
    }

    // 03 § 11: the 3 failed checks must be "in a row". A successful check in between starts the count again. Three brief outages of exactly one failed check each (the trick of the first test above: 1.0 s marker window, every check 1.0 s) are separated by successful checks, so there are three failed checks in all but never two in a row. The answer must never turn to "unreachable". Each round lasts 2.5 s from its start: the failed check ends 1.0 to 1.2 s in, a successful check follows at once (the delay is 0 again by then), and 1.3 s of quiet are left before the next round, so the next failure can never directly follow the last. Without a reset on success the third round would make three and announce an outage; the closing positive control shows that such an announcement is visible in the log.
    @Test func failedChecksSeparatedBySuccessfulOnesNeverAddUpToAnOutage() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            let originals: [String: [String]] = ["WIFI": ["192.168.1.1"], "ETH": []]
            try #require(daemon.savedDNS() == originals)
            pause(0.5)
            let settingsBefore = identity(of: daemon.servicesPath)
            let checkSeconds = 1.0
            var departures: [String] = []
            for round in 1...3 {
                let outage = Stopwatch()
                try daemon.setFamilyDNSUnreachable(true)
                try daemon.setProbeDelay(checkSeconds)
                if let left = daemon.firstDepartureFromFamilyServers(["WIFI", "ETH"], until: checkSeconds, on: outage) { departures.append("round \(round), during the outage, \(left)") }
                try daemon.setFamilyDNSUnreachable(false)
                try daemon.setProbeDelay(0)
                if let left = daemon.firstDepartureFromFamilyServers(["WIFI", "ETH"], until: 2.5, on: outage) { departures.append("round \(round), after the outage, \(left)") }
            }
            #expect(departures.isEmpty, "the services left the family servers: \(departures); log:\n\(daemon.logText())")
            #expect(identity(of: daemon.servicesPath) == settingsBefore, "the settings file was rewritten although no pass had anything to change")
            #expect(daemon.logCount(of: unreachableLine) == 0, "three failed checks that were not in a row were announced as an outage; log:\n\(daemon.logText())")
            #expect(daemon.savedDNS() == originals)

            // Positive control: a lasting outage (checks are fast again) is announced and the originals come back.
            try daemon.setFamilyDNSUnreachable(true)
            #expect(daemon.waitForServers(originals, timeout: 4.0) != nil, "the originals never came back in a real outage")
            #expect(daemon.logCount(of: unreachableLine) == 1, "log:\n\(daemon.logText())")
        }
    }

    // MARK: the check never holds up the daemon

    // 03 § 11 "Reachability check": the check runs on a background queue, so commands and ticks never wait on the network. The check here sleeps 1.5 s and then says "unreachable"; while it sleeps (and it sleeps again after every tick, since a new check starts each 0.2 s), `status` and `setup` must still answer in under 300 ms. If the check ran on the engine queue, which every command waits for, each of these would wait up to 1.5 s. The log shows the first check was still running during the first measurement, so the answers really were given during a check.
    @Test func statusAndSetupAnswerInUnder300msWhileTheFamilyCheckIsSlowAndUnreachable() throws {
        try withNetwork(wifiAndEthernet, unreachable: true, probeDelay: 1.5) { daemon in
            let unreachableLoggedAtFirstCall = daemon.logText().contains(unreachableLine)
            var slowest = 0.0
            for _ in 0..<10 {
                let watch = Stopwatch()
                _ = try daemon.status()
                slowest = max(slowest, watch.elapsed)
                pause(0.08)
            }
            let setupWatch = Stopwatch()
            try daemon.setUp()
            let setupSeconds = setupWatch.elapsed
            #expect(!unreachableLoggedAtFirstCall, "the first check had already finished at the first call, so the test measured nothing; log:\n\(daemon.logText())")
            #expect(slowest < 0.3, "the slowest status took \(slowest) s while the check was sleeping")
            #expect(setupSeconds < 0.3, "setup took \(setupSeconds) s while the check was sleeping")
            // The check does finish in the end: the result is acted on once (nothing to override on an unreachable network), and the services are untouched.
            // 03 § 11: "unreachable" now needs 3 failed checks in a row (each slowed to 1.5 s here, re-checked one tick apart), so it arrives after about 4.5 s; the old 3 s limit assumed one failed check was enough.
            #expect(daemon.logContains(unreachableLine, within: 7.0), "log:\n\(daemon.logText())")
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"] && daemon.servers(of: "ETH") == [])
            #expect(daemon.savedDNS() == nil)
        }
    }

    // 03 § 11: "Until the first result arrives, passes leave the current settings as they are." With a reachable network and a first check that takes 1.2 s, nothing is overridden or recorded before the check finishes (the startup pass, the fallback passes every 0.2 s and the commands all run during that time), and the result of the first check then triggers the pass that overrides both services.
    @Test func untilTheFirstCheckHasFinishedNothingIsChangedAndItsResultTriggersTheFirstPass() throws {
        try withNetwork(wifiAndEthernet, probeDelay: 1.2) { daemon in
            let watch = Stopwatch()
            try daemon.setUp()
            pause(0.6 - watch.elapsed)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"] && daemon.servers(of: "ETH") == [], "the services were changed before the first check had finished")
            #expect(daemon.savedDNS() == nil, "nothing may be recorded before anything is changed")
            #expect(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil, "the first check's result did not trigger the first pass")
            #expect(watch.elapsed >= 1.0, "the services were overridden after \(watch.elapsed) s, before the 1.2 s check could have finished")
            #expect(daemon.savedDNS() == ["WIFI": ["192.168.1.1"], "ETH": []])
        }
    }

    // The unknown state also means "no restore": a daemon that restarts while the services are already on the family servers, on a network where the family servers do not answer, must not touch them until its first check has finished. When the result arrives (unreachable), the originals are put back.
    @Test func aRestartLeavesOverriddenServicesAloneUntilTheFirstCheckHasFinished() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            daemon.kill9()
            try daemon.setFamilyDNSUnreachable(true)
            try daemon.setProbeDelay(1.2)
            let watch = Stopwatch()
            try daemon.start()
            pause(0.6 - watch.elapsed)
            #expect(isFamily(daemon.servers(of: "WIFI")) && isFamily(daemon.servers(of: "ETH")), "the overridden services were changed before the first check had finished")
            // 03 § 11: "unreachable" needs 3 failed checks in a row (each slowed to 1.2 s here), so the originals return after about 3.6 s; the old 3 s limit assumed one failed check was enough.
            #expect(daemon.waitForServers(["WIFI": ["192.168.1.1"], "ETH": []], timeout: 6.0) != nil, "the originals were not put back once the check said unreachable")
            #expect(watch.elapsed >= 1.0, "the originals came back after \(watch.elapsed) s, before the 1.2 s check could have finished")
            #expect(daemon.savedDNS() == ["WIFI": ["192.168.1.1"], "ETH": []], "the record must be kept")
        }
    }

    // MARK: change that does not take effect

    // 03 § 11 and the verify-after-write rule: after a change the service is read back; one that does not hold what was written is put back as it was, the failure is logged, and that service is not tried again for 10 minutes. A service that ignores writes (a backend with a bug) is simulated with "ignoreWrites". The log line appears exactly once although about five passes run in a second, which is what the pause is for; the healthy service next to it is overridden normally.
    @Test func aChangeThatDoesNotTakeEffectIsLoggedOnceLeftAloneAndNotRetried() throws {
        let services: [String: [String: Any]] = [
            "OK": ["name": "Wi-Fi", "servers": ["192.168.1.1"]],
            "STUCK": ["name": "Stuck Adapter", "servers": ["10.2.2.2"], "ignoreWrites": true],
        ]
        try withNetwork(services) { daemon in
            #expect(daemon.waitForFamily(["OK"], timeout: 3.0) != nil)
            let line = "DNS change did not take effect for Stuck Adapter; left the network's DNS in place"
            #expect(daemon.logContains(line), "log:\n\(daemon.logText())")
            pause(1.2)
            #expect(daemon.logCount(of: line) == 1, "the stuck service was tried again within the 10 minute pause; log:\n\(daemon.logText())")
            #expect(daemon.servers(of: "STUCK") == ["10.2.2.2"], "the stuck service must keep the network's own DNS")
            #expect(daemon.isRunning)
        }
    }

    // MARK: uninstall

    // 03 § 11 "Uninstall" and § Uninstaller step 3: the sandbox uninstall puts every service's original servers back (the empty list for the service that had none set by hand) in the same step that clears the hosts section and the Chrome keys. The checks run after the daemon exits with code 0, so no late pass can be hiding a leftover.
    @Test func theUninstallRestoresTheOriginalServers() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try daemon.setUp()
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            try daemon.addService("USB", name: "USB LAN", servers: ["8.8.8.8"])
            try #require(daemon.waitForFamily(["USB"], timeout: 2.0) != nil)
            try daemon.requireTwoSecondDelay()
            try daemon.send(.uninstall, password: Self.password).requireOK()
            #expect(isFamily(daemon.servers(of: "WIFI")), "the family servers stay during the countdown")
            let exit = try #require(daemon.waitForExit(timeout: 6.0), "the daemon never exited after the uninstall delay")
            #expect(exit.status == 0 && !exit.killedBySignal)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"])
            #expect(daemon.servers(of: "ETH") == [], "a service that had no servers set by hand must get none again")
            #expect(daemon.servers(of: "USB") == ["8.8.8.8"])
            #expect(daemon.logContains("DNS settings restored for 3 network services"), "log:\n\(daemon.logText())")
        }
    }

    // The uninstall also restores a service that was put back and left on its own DNS during an outage, and does nothing wrong when the family servers are unreachable at that moment (the originals are already in place).
    @Test func theUninstallDuringAnOutageLeavesTheOriginalsInPlace() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try daemon.setUp()
            try #require(daemon.waitForFamily(["WIFI"], timeout: 3.0) != nil)
            try daemon.setFamilyDNSUnreachable(true)
            try #require(daemon.waitForServers(["WIFI": ["192.168.1.1"]], timeout: 2.0) != nil)
            try daemon.send(.uninstall, password: Self.password).requireOK()
            let exit = try #require(daemon.waitForExit(timeout: 6.0))
            #expect(exit.status == 0)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"] && daemon.servers(of: "ETH") == [])
        }
    }

    // MARK: restart

    // The record survives a restart (it is in the state file), so a daemon that starts while the services are still overridden does not mistake the family servers for the originals, and a later uninstall still restores the real originals.
    @Test func theRecordSurvivesARestartSoTheUninstallStillRestoresTheRealOriginals() throws {
        try withNetwork(wifiAndEthernet) { daemon in
            try daemon.setUp()
            try #require(daemon.waitForFamily(["WIFI", "ETH"], timeout: 3.0) != nil)
            daemon.kill9()
            try daemon.start()
            pause(0.8)
            #expect(daemon.savedDNS() == ["WIFI": ["192.168.1.1"], "ETH": []], "the family servers were recorded as originals after the restart")
            try daemon.requireTwoSecondDelay()
            try daemon.send(.uninstall, password: Self.password).requireOK()
            _ = daemon.waitForExit(timeout: 6.0)
            #expect(daemon.servers(of: "WIFI") == ["192.168.1.1"] && daemon.servers(of: "ETH") == [])
        }
    }
}

// `siteblockd --print-dns-plan`: the read-only diagnostic. Run here with --sandbox, so it reads the stand-in settings; run without --sandbox it reads this Mac's real settings, which a test must not depend on.
// Design: 03-daemon-cli-app.md § 11 DNSEnforcer (the diagnostic reads the network settings and the reachability check and writes nothing).
@Suite("siteblockd --print-dns-plan")
struct DNSPlanTests {
    // The names of everything in a folder tree, with sizes and modification times of the files, so any new, removed or rewritten file shows as a difference.
    private func fingerprint(_ root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var lines: [String] = []
        for case let relative as String in walker {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/" + relative)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            let time = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            lines.append("\(relative) \(size) \(time)")
        }
        return lines.sorted()
    }

    private static let services: [String: [String: Any]] = [
        "WIFI": ["name": "Wi-Fi", "servers": ["192.168.1.1"], "interfaceType": "IEEE80211"],
        "ETH": ["name": "Ethernet", "servers": [String]()],
        "OFF": ["name": "Old Dongle", "servers": ["10.0.0.1"], "enabled": false],
        "VPN": ["name": "Work VPN", "servers": ["10.1.1.1", "10.1.1.2"], "interfaceType": "VPN"],
        "DONE": ["name": "Already Family", "servers": familyServers],
    ]

    // Lists every service with its ID, name, interface type, enabled flag, skip reason, current servers and what SiteBlock would set, prints the reachability result, exits 0, and changes nothing: the settings file keeps every byte and no file appears or changes anywhere in the sandbox folder (so no state, log or socket is created, which also shows no daemon was started).
    @Test(.enabled(if: geteuid() != 0))
    func itDescribesEveryServiceAndTheReachabilityAndChangesNothing() throws {
        try withDaemon(start: false) { daemon in
            try daemon.writeServices(Self.services)
            let before = fingerprint(daemon.root)
            let bytesBefore = FileManager.default.contents(atPath: daemon.servicesPath)
            let result = try runDaemonProgram(["--print-dns-plan", "--sandbox", daemon.root])
            #expect(result.status == 0 && !result.timedOut, "exit \(result.status); stderr: \(result.stderr)")
            let out = result.stdout
            for expected in [
                "Family DNS reachability: reachable",
                "Family servers: \(familyServers.joined(separator: ", "))",
                "Network services: 5",
                "- WIFI", "name: Wi-Fi", "interface type: IEEE80211", "current ServerAddresses: 192.168.1.1",
                "- ETH", "name: Ethernet", "interface type: Ethernet", "current ServerAddresses: (none set by hand; the network's own DNS is used)",
                "- OFF", "enabled: no", "skipped: yes, the service is disabled", "SiteBlock would set: nothing (the service is disabled)",
                "- VPN", "interface type: VPN", "skipped: yes, VPN-type interface", "current ServerAddresses: 10.1.1.1, 10.1.1.2",
                "- DONE", "SiteBlock would set: nothing (already the family servers)",
                "SiteBlock would set: \(familyServers.joined(separator: ", ")) (the current servers would be saved first)",
            ] { #expect(out.contains(expected), "missing \"\(expected)\" in:\n\(out)") }
            #expect(out.components(separatedBy: "enabled: yes").count - 1 == 4, "four services are enabled; output:\n\(out)")
            #expect(out.components(separatedBy: "skipped: no").count - 1 == 3, "three services are not skipped; output:\n\(out)")
            #expect(FileManager.default.contents(atPath: daemon.servicesPath) == bytesBefore, "the settings file was rewritten")
            #expect(fingerprint(daemon.root) == before, "something in the sandbox folder was created or changed")
        }
    }

    // When the family servers do not answer, the report says so and plans nothing for the services that have other servers.
    @Test(.enabled(if: geteuid() != 0))
    func whenTheFamilyServersAreUnreachableItSaysSoAndPlansNothing() throws {
        try withDaemon(start: false) { daemon in
            try daemon.writeServices(Self.services)
            try daemon.setFamilyDNSUnreachable(true)
            let result = try runDaemonProgram(["--print-dns-plan", "--sandbox", daemon.root])
            #expect(result.status == 0)
            #expect(result.stdout.contains("Family DNS reachability: UNREACHABLE"), "\(result.stdout)")
            #expect(result.stdout.contains("SiteBlock would set: nothing (the family servers do not answer on this network, so the network's own DNS stays)"), "\(result.stdout)")
            #expect(!result.stdout.contains("the current servers would be saved first"), "\(result.stdout)")
        }
    }

    // A sandbox folder with no settings file has no services: the report says so and still exits 0.
    @Test(.enabled(if: geteuid() != 0))
    func withNoServicesFileItReportsZeroServicesAndExitsZero() throws {
        try withDaemon(start: false) { daemon in
            let result = try runDaemonProgram(["--print-dns-plan", "--sandbox", daemon.root])
            #expect(result.status == 0)
            #expect(result.stdout.contains("Network services: 0"), "\(result.stdout)")
        }
    }

    // A settings file that is not valid cannot be read: the program says so on standard error and exits 1, and still changes nothing.
    @Test(.enabled(if: geteuid() != 0))
    func aDamagedSettingsFileIsReportedAndLeftAlone() throws {
        try withDaemon(start: false) { daemon in
            try writeText("this is not json", to: daemon.servicesPath)
            let result = try runDaemonProgram(["--print-dns-plan", "--sandbox", daemon.root])
            #expect(result.status == 1, "exit \(result.status)")
            #expect(result.stderr.contains("cannot read the network settings"), "\(result.stderr)")
            #expect(readText(daemon.servicesPath) == "this is not json")
        }
    }

    // The mode is a mode like --version: combining it with --daemon is a usage error (exit 64) and nothing is read.
    @Test(.enabled(if: geteuid() != 0))
    func itCannotBeCombinedWithTheDaemonMode() throws {
        let result = try runDaemonProgram(["--print-dns-plan", "--daemon"])
        #expect(result.status == 64, "exit \(result.status); stderr: \(result.stderr)")
    }
}

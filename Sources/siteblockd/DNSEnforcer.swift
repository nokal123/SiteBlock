import Foundation
import SiteBlockCore
import SystemConfiguration

/// One network service (a Wi-Fi or Ethernet connection, for example) as the DNS code sees it.
struct DNSService: Equatable {
    /// The interface types that mean a VPN: PPP (dial-up style tunnels, which includes L2TP), IPSec, and "VPN" (the type macOS gives VPNs made by apps, whose constant `kSCNetworkInterfaceTypeVPN` is not in the public headers, so its text is written out). Services of these types are left alone, because a VPN supplies its own DNS servers.
    static let vpnInterfaceTypes: Set<String> = [kSCNetworkInterfaceTypePPP as String, kSCNetworkInterfaceTypeIPSec as String, kSCNetworkInterfaceTypeL2TP as String, "VPN"]

    /// The SystemConfiguration service ID, which stays the same when the user renames the service.
    let id: String
    /// The name shown in System Settings, for the log.
    let name: String
    /// The kind of interface under the service, such as "Ethernet", "IEEE80211" (Wi-Fi) or "PPP"; "none" when the service has no interface.
    let interfaceType: String
    /// False when the service is switched off in System Settings.
    let isEnabled: Bool
    /// The DNS servers set by hand on this service; empty when none are set and the service uses whatever the network provides.
    var servers: [String]

    /// True when the service is on a VPN-type interface.
    var isVPN: Bool { DNSService.vpnInterfaceTypes.contains(interfaceType) }

    /// True when SiteBlock may replace this service's servers: it is switched on and is not a VPN.
    var isManaged: Bool { isEnabled && !isVPN }

    /// The reason SiteBlock leaves this service alone, or nil when it manages it.
    var skipReason: String? {
        if !isEnabled { return "the service is disabled" }
        if isVPN { return "VPN-type interface (a VPN supplies its own DNS servers)" }
        return nil
    }
}

/// A failed read or write of the network settings, with a sentence for the log.
struct DNSBackendError: Error, LocalizedError {
    /// What went wrong.
    let message: String

    /// The sentence describing the failure.
    var errorDescription: String? { message }
}

/// How the DNS enforcer reads and changes the Mac's network settings. Production uses the SystemConfiguration framework; sandbox runs use a JSON file, so tests can create services and tamper with them.
protocol DNSSettingsBackend {
    /// Lists every network service with the DNS servers set on it, read fresh from the stored settings each time. Throws when the settings cannot be read.
    func readServices() throws -> [DNSService]

    /// Sets the DNS servers of the given services in one step: service ID to the servers it should have. An empty list removes the setting, so the service uses the network's own DNS again. A service ID that no longer exists is skipped. Throws when the change cannot be saved or applied.
    func apply(_ servers: [String: [String]]) throws
}

/// The sandbox stand-in for the Mac's network settings: a JSON file holding a dictionary from service ID to `{"name": String, "servers": [String]}`. A missing file means the Mac has no network services. Three optional keys let tests set up awkward services: `"enabled": false` (a disabled service), `"interfaceType": "VPN"` (any interface type text; the default is "Ethernet"), and `"ignoreWrites": true` (a service that accepts a change without applying it, like a settings backend with a bug).
final class FileDNSBackend: DNSSettingsBackend {
    private let path: String

    /// Creates a backend that reads and writes the JSON file at the path.
    init(path: String) {
        self.path = path
    }

    /// Reads the file into a dictionary of service entries. A missing file is an empty dictionary; a file that is not a JSON object of objects throws.
    private func readEntries() throws -> [String: [String: Any]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let entries = object as? [String: [String: Any]] else {
            throw DNSBackendError(message: "\(path) is not a JSON object of service entries")
        }
        return entries
    }

    /// Returns every service in the file, sorted by ID. An entry without a usable `servers` list has no servers set.
    func readServices() throws -> [DNSService] {
        try readEntries().sorted { $0.key < $1.key }.map { id, entry in
            DNSService(id: id, name: entry["name"] as? String ?? id, interfaceType: entry["interfaceType"] as? String ?? "Ethernet", isEnabled: entry["enabled"] as? Bool ?? true, servers: entry["servers"] as? [String] ?? [])
        }
    }

    /// Writes the new server lists into the file. The file is replaced in one step, so a reader never sees half of it. Entries for service IDs that are not in the file are ignored, and so are entries marked `"ignoreWrites": true`.
    func apply(_ servers: [String: [String]]) throws {
        var entries = try readEntries()
        for (id, list) in servers where entries[id] != nil && entries[id]?["ignoreWrites"] as? Bool != true { entries[id]?["servers"] = list }
        do {
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw DNSBackendError(message: "cannot write \(path): \(error.localizedDescription)")
        }
    }
}

/// The real network settings, read and changed in-process through the SystemConfiguration framework. It never runs `networksetup`, so a check starts no new process.
final class SystemConfigurationDNSBackend: DNSSettingsBackend {
    /// The key inside a service's DNS settings that holds the server addresses.
    private static let serversKey = kSCPropNetDNSServerAddresses as String

    /// The sentence for the last SystemConfiguration error, for the log.
    private static func lastError() -> String {
        String(cString: SCErrorString(SCError()))
    }

    /// Opens the Mac's network preferences. Throws when they cannot be opened. Opening and reading them needs no special rights; only saving a change does.
    private func openPreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, "siteblockd" as CFString, nil) else {
            throw DNSBackendError(message: "cannot open the network preferences: \(Self.lastError())")
        }
        return preferences
    }

    /// Lists every network service, read fresh from the stored preferences (a new `SCPreferences` is opened on each call, so a change that was just saved is seen).
    func readServices() throws -> [DNSService] {
        let preferences = try openPreferences()
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return [] }
        var result: [DNSService] = []
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            let name = SCNetworkServiceGetName(service) as String? ?? id
            var interfaceType = "none"
            if let interface = SCNetworkServiceGetInterface(service), let type = SCNetworkInterfaceGetInterfaceType(interface) as String? { interfaceType = type }
            var servers: [String] = []
            if let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS), let configuration = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] {
                servers = configuration[Self.serversKey] as? [String] ?? []
            }
            result.append(DNSService(id: id, name: name, interfaceType: interfaceType, isEnabled: SCNetworkServiceGetEnabled(service), servers: servers))
        }
        return result
    }

    /// Sets the DNS servers of each given service, then saves and applies all the changes at once. The service's other DNS settings (such as search domains) are kept. A list that is empty removes `ServerAddresses`.
    func apply(_ servers: [String: [String]]) throws {
        let preferences = try openPreferences()
        for (id, list) in servers.sorted(by: { $0.key < $1.key }) {
            // A service that was deleted since it was read is skipped.
            guard let service = SCNetworkServiceCopy(preferences, id as CFString) else { continue }
            var dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            // A service that never had DNS settings has no DNS protocol entry yet, so one is added before it is filled in.
            if dns == nil {
                _ = SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeDNS)
                dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            }
            guard let dns else { throw DNSBackendError(message: "service \(id) has no DNS settings that can be changed: \(Self.lastError())") }
            var configuration = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] ?? [:]
            if list.isEmpty {
                configuration.removeValue(forKey: Self.serversKey)
            } else {
                configuration[Self.serversKey] = list
            }
            guard SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary) else {
                throw DNSBackendError(message: "cannot change the DNS settings of service \(id): \(Self.lastError())")
            }
        }
        guard SCPreferencesCommitChanges(preferences) else { throw DNSBackendError(message: "cannot save the network preferences: \(Self.lastError())") }
        guard SCPreferencesApplyChanges(preferences) else { throw DNSBackendError(message: "cannot apply the network preferences: \(Self.lastError())") }
    }
}

/// The sandbox stand-in for the check: the family servers count as unreachable exactly while the marker file exists, and an optional delay file makes every check sleep that many seconds first (so tests can show that a slow check never holds up the daemon). Only a sandbox `Paths` names these files, so the installed service never builds this probe and can never read a fake.
final class FileFamilyDNSProbe: FamilyDNSProbe {
    private let markerPath: String
    private let delayPath: String?

    /// Creates a probe that looks for the marker file and, when a path is given, reads a delay in seconds from the delay file.
    init(markerPath: String, delayPath: String?) {
        self.markerPath = markerPath
        self.delayPath = delayPath
    }

    /// Reads both files, sleeps for the delay (at most 10 seconds), and then reports unreachable if the marker file existed when the check started, and reachable otherwise. The files are looked at on every call, so a test can change the answer while a daemon runs.
    func check() -> FamilyDNSCheck {
        let unreachable = FileManager.default.fileExists(atPath: markerPath)
        if let delayPath, let text = readText(delayPath), let delay = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), delay > 0 {
            Thread.sleep(forTimeInterval: min(delay, 10))
        }
        return unreachable ? FamilyDNSCheck(reachable: false, detail: "pretending the family servers do not answer (the sandbox marker file exists)") : FamilyDNSCheck(reachable: true, detail: "pretending the family servers answer (sandbox)")
    }

    /// Reads a small text file, or nil when it is missing.
    private func readText(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Keeps the latest answer to "do the family DNS servers answer on this network?" without ever making the engine queue wait. It runs the check on its own serial background queue: once at once when started, then every `interval` seconds, and again whenever `probeNow()` is called (the daemon calls it when macOS reports a network change). The latest result is kept behind a lock so the engine queue can read it at any time. When a result differs from the one before it (the first result counts as different), `onChange` is called on the background queue, and the daemon uses that to schedule a DNS pass on the engine queue.
final class FamilyDNSMonitor {
    private let probe: FamilyDNSProbe
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private let lock = NSLock()
    // The newest result and when it arrived; nil until the first check has finished.
    private var newest: (check: FamilyDNSCheck, at: ContinuousClock.Instant)?
    // True between a call to probeNow() and the moment its check starts, so a burst of network-change notifications queues one check, not many.
    private var checkQueued = false
    private var stopped = false
    private var timer: DispatchSourceTimer?
    // Failed checks in a row since the last success. One lost reply is common on real networks, so the answer only turns to "unreachable" after `failuresBeforeUnreachable` of them; until then the previous answer stands.
    private var consecutiveFailures = 0
    // How many failed checks in a row count as "unreachable" (3).
    private let failuresBeforeUnreachable: Int
    // How long to wait before re-checking after a failed check that did not yet change the answer (5 seconds when installed; the sandbox tick in tests).
    private var failureRetryInterval: TimeInterval = 5

    /// Creates a monitor that runs `probe` on `queue` and calls `onChange` when the answer changes. The queue defaults to a private serial queue; it must never be the engine queue.
    init(probe: FamilyDNSProbe, queue: DispatchQueue = DispatchQueue(label: "siteblockd.dns-probe", qos: .utility), failuresBeforeUnreachable: Int = 3, onChange: @escaping () -> Void) {
        self.probe = probe
        self.queue = queue
        self.failuresBeforeUnreachable = max(1, failuresBeforeUnreachable)
        self.onChange = onChange
    }

    /// The latest result, or nil while no check has finished yet (the "unknown" state, in which the DNS enforcer leaves the settings as they are). Safe to call from any thread.
    var latest: FamilyDNSCheck? {
        lock.lock()
        defer { lock.unlock() }
        return newest?.check
    }

    /// When the latest result arrived, or nil while there is none.
    var latestArrivedAt: ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return newest?.at
    }

    /// Starts the repeating check. The first check begins at once, and then one starts every `interval` seconds. After a failed check that has not yet changed the answer, a re-check runs `retryInterval` seconds later instead of waiting for the next regular one.
    func start(interval: TimeInterval, retryInterval: TimeInterval = 5) {
        lock.lock()
        failureRetryInterval = retryInterval
        lock.unlock()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.runCheck() }
        source.resume()
        lock.lock()
        timer = source
        lock.unlock()
    }

    /// Asks for one more check right away, unless one is already waiting to start. Safe to call from any thread.
    func probeNow() {
        lock.lock()
        let skip = stopped || checkQueued
        if !skip { checkQueued = true }
        lock.unlock()
        if skip { return }
        queue.async { [weak self] in self?.runCheck() }
    }

    /// Stops the repeating check. A check that is already running finishes, but its result no longer triggers anything.
    func stop() {
        lock.lock()
        stopped = true
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Runs one check on the background queue and calls `onChange` when the answer changes. A success is taken at once. A failure only replaces the answer after `failuresBeforeUnreachable` failures in a row; before that the previous answer (or "unknown") stands and a re-check is scheduled `failureRetryInterval` seconds later, so one dropped reply never switches the Mac's DNS back and forth.
    private func runCheck() {
        lock.lock()
        checkQueued = false
        let isStopped = stopped
        lock.unlock()
        if isStopped { return }
        let check = probe.check()
        lock.lock()
        let previous = newest?.check.reachable
        var publish = true
        var retryAfter: TimeInterval?
        if check.reachable {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            if consecutiveFailures < failuresBeforeUnreachable {
                publish = false
                retryAfter = failureRetryInterval
            }
        }
        if publish { newest = (check, ContinuousClock.now) }
        let nowStopped = stopped
        lock.unlock()
        if nowStopped { return }
        if publish && previous != check.reachable { onChange() }
        if let retryAfter { queue.asyncAfter(deadline: .now() + retryAfter) { [weak self] in self?.runCheck() } }
    }
}

/// Keeps every network service's DNS servers set to Cloudflare for Families for as long as SiteBlock is installed, and lets the uninstaller put the original servers back. Cloudflare for Families refuses to look up adult sites, so this is the second layer of the adult content filter (the first is Chrome's policy file). The family servers are only used while they answer on the current network, and a change is only kept if it can be read back. Every method must be called on the engine queue.
final class DNSEnforcer {
    /// The DNS servers every managed service is set to: Cloudflare for Families, two IPv4 and two IPv6 addresses.
    static let familyServers = ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]
    // A failure message that repeats is logged at most this often, so a persistent problem does not write a line every pass.
    private static let repeatedFailureLogInterval = Duration.seconds(60)
    // After a change to a service could not be read back, that service is left alone for this long (10 minutes), so a settings backend with a bug cannot be retried in a loop.
    private static let retryPause = Duration.seconds(600)

    private let paths: Paths
    private let log: Logger
    private let backend: DNSSettingsBackend
    private var lastFailure: (message: String, at: ContinuousClock.Instant)?
    // Whether the last check found the family servers answering; nil before the first check. It is used to log a change of state once.
    private var familyReachable: Bool?
    // For each service whose change did not take effect, the time before which it is not tried again.
    private var retryNotBefore: [String: ContinuousClock.Instant] = [:]

    /// Creates an enforcer. A sandbox run reads `network-services.json` from the sandbox folder; the installed service uses the real network settings. The enforcer never checks reachability itself: the daemon hands it the latest result of `FamilyDNSMonitor` on every pass.
    init(paths: Paths, log: Logger) {
        self.paths = paths
        self.log = log
        self.backend = DNSEnforcer.makeBackend(paths: paths)
    }

    /// Picks the settings backend for these paths: the JSON file in a sandbox, the SystemConfiguration framework otherwise.
    static func makeBackend(paths: Paths) -> DNSSettingsBackend {
        if let file = paths.networkServicesFile { return FileDNSBackend(path: file) }
        return SystemConfigurationDNSBackend()
    }

    /// Picks the reachability check for these paths: the marker file in a sandbox, real DNS queries otherwise.
    static func makeProbe(paths: Paths) -> FamilyDNSProbe {
        if let marker = paths.familyDNSUnreachableMarker { return FileFamilyDNSProbe(markerPath: marker, delayPath: paths.familyDNSProbeDelayFile) }
        return UDPFamilyDNSProbe()
    }

    /// Runs one pass and returns true when the services ended up right (or there was nothing to do).
    ///
    /// With `adultFilterActive` true, the pass looks at `familyDNS`, the latest result of the reachability monitor, and sends no network query itself. With no result yet (nil, the "unknown" state before the first check has finished) it changes nothing at all: no override and no restore. If the family servers answer, every managed service whose servers are not exactly the family list is set to it. A service SiteBlock has not overridden before first has its current servers recorded: `persist` is called with the full record before anything is written, and when `persist` returns false (the state could not be saved) nothing is changed, so the originals are never lost. A service that already has a record keeps its first recorded value, so a hand edit never replaces the real original. After the write, each changed service is read back; one that does not hold the new servers gets its recorded original back and is left alone for 10 minutes. If the family servers do not answer, nothing is overridden, and services that are already overridden get their recorded servers back (the record is kept), until a later pass finds the family servers answering again.
    ///
    /// With `adultFilterActive` false (only the uninstaller does this), every recorded service that still exists gets its recorded servers back, and then the record is cleared through `persist`. If the restore fails, the record stays so it can be tried again.
    ///
    /// No command or countdown ever changes the DNS servers on purpose, so a pass that has to set a service that SiteBlock had already set once is always tampering (or a network that reset its settings) and logs "DNS settings repaired". A service seen for the first time (a fresh install, or a new adapter) logs a plain "set" line instead.
    func enforce(adultFilterActive: Bool, savedDNS: [String: [String]]?, familyDNS: FamilyDNSCheck?, persist: ([String: [String]]?) -> Bool) -> Bool {
        adultFilterActive ? setFamilyServers(savedDNS: savedDNS ?? [:], familyDNS: familyDNS, persist: persist) : restoreOriginals(savedDNS: savedDNS ?? [:], persist: persist)
    }

    /// The filter-on half of `enforce`: when the latest reachability result says the family servers answer, sets them on every managed service that does not have them yet; when it says they do not, puts the originals back; when there is no result yet, does nothing.
    private func setFamilyServers(savedDNS: [String: [String]], familyDNS: FamilyDNSCheck?, persist: ([String: [String]]?) -> Bool) -> Bool {
        // Unknown: the first check has not finished, so nothing is known about this network. Changing the servers now could break the Mac's DNS, and putting originals back would undo work for no reason, so the settings stay as they are until the result arrives (which schedules a new pass).
        guard let check = familyDNS else { return true }
        let services: [DNSService]
        do {
            services = try backend.readServices()
        } catch {
            logFailure("DNS settings could not be read: \(error.localizedDescription)")
            return false
        }
        let now = ContinuousClock.now
        let managed = services.filter(\.isManaged)
        // Services SiteBlock set earlier that still hold the family servers, and services that need the family servers now (leaving out any that are being left alone after a change that did not take effect).
        let overridden = managed.filter { savedDNS[$0.id] != nil && $0.servers == DNSEnforcer.familyServers }
        let candidates = managed.filter { $0.servers != DNSEnforcer.familyServers && !(retryNotBefore[$0.id].map { $0 > now } ?? false) }
        // With nothing to set and nothing set, there is no reason to ask the network anything.
        if overridden.isEmpty && candidates.isEmpty {
            lastFailure = nil
            return true
        }

        if !check.reachable {
            if familyReachable != false { log.log("family DNS unreachable; using the network's own DNS until it answers") }
            familyReachable = false
            return putOriginalsBack(for: overridden, savedDNS: savedDNS)
        }
        let recovering = familyReachable == false
        familyReachable = true

        var record = savedDNS
        var changes: [String: [String]] = [:]
        var repaired: [String] = []
        for service in candidates {
            if record[service.id] == nil {
                record[service.id] = service.servers
            } else {
                repaired.append(service.name)
            }
            changes[service.id] = DNSEnforcer.familyServers
        }
        if changes.isEmpty {
            lastFailure = nil
            return true
        }
        // The originals are written down before they are replaced. If they cannot be saved, the services are left as they are and the next pass tries again.
        if record != savedDNS, !persist(record) {
            logFailure("DNS settings not changed: the original servers could not be saved first")
            return false
        }
        do {
            try backend.apply(changes)
        } catch {
            logFailure("DNS settings could not be changed: \(error.localizedDescription)")
            return false
        }
        lastFailure = nil

        // Read the settings back from the stored preferences. A service that does not hold what was just written is put back as it was, and is not tried again for 10 minutes: a backend that silently ignores the change must neither loop nor leave the Mac with DNS that does not work.
        let failed = servicesThatDidNotTakeTheChange(changes)
        if !failed.isEmpty {
            var original: [String: [String]] = [:]
            for id in failed { original[id] = record[id] ?? [] }
            do {
                try backend.apply(original)
            } catch {
                logFailure("DNS settings could not be put back after a change that did not take effect: \(error.localizedDescription)")
            }
            for id in failed {
                retryNotBefore[id] = ContinuousClock.now + DNSEnforcer.retryPause
                let name = candidates.first { $0.id == id }?.name ?? id
                log.log("DNS change did not take effect for \(name); left the network's DNS in place")
            }
        }
        let applied = changes.count - failed.count
        if applied == 0 { return true }
        if !paths.isSandbox { NameCache.flush(log: log) }
        if recovering {
            log.log("family DNS answers again; DNS settings set to the family servers for \(applied) network \(applied == 1 ? "service" : "services")")
        } else if repaired.isEmpty {
            log.log("DNS settings set to the family servers for \(applied) network \(applied == 1 ? "service" : "services")")
        } else {
            log.log("DNS settings repaired")
        }
        return true
    }

    /// Reads the services back from the stored settings and returns the IDs of those that do not hold the servers that were just written for them (including services that have disappeared or cannot be read back).
    private func servicesThatDidNotTakeTheChange(_ written: [String: [String]]) -> [String] {
        let current = (try? backend.readServices()) ?? []
        return written.keys.sorted().filter { id in current.first { $0.id == id }?.servers != written[id] }
    }

    /// While the family servers do not answer: gives each overridden service its recorded servers back. The record itself is kept, so the family servers can be set again as soon as they answer.
    private func putOriginalsBack(for overridden: [DNSService], savedDNS: [String: [String]]) -> Bool {
        var back: [String: [String]] = [:]
        for service in overridden { back[service.id] = savedDNS[service.id] }
        if back.isEmpty {
            lastFailure = nil
            return true
        }
        do {
            try backend.apply(back)
        } catch {
            logFailure("DNS settings could not be put back while the family servers are unreachable: \(error.localizedDescription)")
            return false
        }
        lastFailure = nil
        if !paths.isSandbox { NameCache.flush(log: log) }
        return true
    }

    /// The uninstall half of `enforce`: puts every recorded service's original servers back, then clears the record.
    private func restoreOriginals(savedDNS: [String: [String]], persist: ([String: [String]]?) -> Bool) -> Bool {
        guard !savedDNS.isEmpty else { return true }
        let services: [DNSService]
        do {
            services = try backend.readServices()
        } catch {
            logFailure("DNS settings could not be read: \(error.localizedDescription)")
            return false
        }
        // A recorded service that no longer exists (its adapter was removed) has nothing to restore. A service that already has its original servers needs no write.
        var changes: [String: [String]] = [:]
        for service in services {
            if let original = savedDNS[service.id], service.servers != original { changes[service.id] = original }
        }
        if !changes.isEmpty {
            do {
                try backend.apply(changes)
            } catch {
                logFailure("DNS settings could not be restored: \(error.localizedDescription)")
                return false
            }
            if !paths.isSandbox { NameCache.flush(log: log) }
            log.log("DNS settings restored for \(changes.count) network \(changes.count == 1 ? "service" : "services")")
        }
        lastFailure = nil
        // The record is cleared only now that the originals are back.
        if !persist(nil) { logFailure("DNS settings restored, but the saved record could not be cleared") }
        return true
    }

    /// Logs a failure message, unless the same message was already logged within the last minute.
    private func logFailure(_ message: String) {
        let now = ContinuousClock.now
        if let last = lastFailure, last.message == message, now - last.at < DNSEnforcer.repeatedFailureLogInterval { return }
        lastFailure = (message, now)
        log.log(message)
    }
}

/// The read-only description printed by `siteblockd --print-dns-plan`: what SiteBlock found on each network service and what it would do about it. It only reads the network settings and sends the reachability query; it never changes anything, needs no root, and does not touch SiteBlock's own state.
enum DNSPlanReport {
    /// Builds the report for these paths (the real network settings and a real reachability query, or the sandbox stand-ins). Throws when the services cannot be read.
    static func text(paths: Paths) throws -> String {
        let services = try DNSEnforcer.makeBackend(paths: paths).readServices()
        let check = DNSEnforcer.makeProbe(paths: paths).check()
        var lines = ["SiteBlock DNS plan (read-only: nothing was changed)"]
        lines.append(paths.isSandbox ? "Mode: sandbox (\(paths.networkServicesFile ?? "no services file"))" : "Mode: this Mac's real network settings")
        lines.append("Family DNS reachability: \(check.reachable ? "reachable" : "UNREACHABLE") (\(check.detail))")
        lines.append("Family servers: \(DNSEnforcer.familyServers.joined(separator: ", "))")
        lines.append("Network services: \(services.count)")
        for service in services {
            lines.append("- \(service.id)")
            lines.append("    name: \(service.name)")
            lines.append("    interface type: \(service.interfaceType)")
            lines.append("    enabled: \(service.isEnabled ? "yes" : "no")")
            lines.append("    skipped: \(service.skipReason.map { "yes, \($0)" } ?? "no")")
            lines.append("    current ServerAddresses: \(service.servers.isEmpty ? "(none set by hand; the network's own DNS is used)" : service.servers.joined(separator: ", "))")
            lines.append("    SiteBlock would set: \(wouldSet(service, check: check))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Describes what a pass would do to one service right now.
    private static func wouldSet(_ service: DNSService, check: FamilyDNSCheck) -> String {
        if let reason = service.skipReason { return "nothing (\(reason))" }
        if service.servers == DNSEnforcer.familyServers {
            return check.reachable ? "nothing (already the family servers)" : "its saved servers back (the family servers do not answer); the saved servers are in SiteBlock's state, which this report does not read"
        }
        if !check.reachable { return "nothing (the family servers do not answer on this network, so the network's own DNS stays)" }
        return "\(DNSEnforcer.familyServers.joined(separator: ", ")) (the current servers would be saved first)"
    }
}

/// Watches the Mac's network settings (production only) and calls a function soon after any DNS setting changes, so a hand edit in System Settings, or joining a new network, is undone within about a second. It uses a SystemConfiguration dynamic store: a notification service that tells a program when named settings change.
final class DNSChangeWatcher {
    // After a notification, wait this long before reacting, so the several notifications one change produces cause one pass.
    private static let settleSeconds = 0.3

    private var store: SCDynamicStore?
    private let queue: DispatchQueue
    private let onChange: () -> Void
    // True between a notification and the pass it scheduled, so a burst of notifications schedules one pass.
    private var passScheduled = false

    /// Starts watching. `onChange` runs on `queue` (the engine queue). Returns nil when the dynamic store cannot be created or the watch cannot be set up; the 30-second fallback pass still covers that case.
    init?(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
        // The callback is a plain C function, so it finds this object again through the `info` pointer. The pointer is not retained: `stop()` ends the callbacks before the object goes away.
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<DNSChangeWatcher>.fromOpaque(info).takeUnretainedValue().notified()
        }
        guard let store = SCDynamicStoreCreate(nil, "siteblockd.dns" as CFString, callback, &context) else { return nil }
        // The per-service DNS settings, and the DNS the Mac is using right now.
        let patterns = ["Setup:/Network/Service/.*/DNS", "State:/Network/Global/DNS"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns), SCDynamicStoreSetDispatchQueue(store, queue) else { return nil }
        self.store = store
    }

    /// Stops the notifications. Safe to call more than once.
    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
    }

    /// Called on the queue for each notification: schedules one pass shortly afterwards unless one is already scheduled.
    private func notified() {
        guard !passScheduled else { return }
        passScheduled = true
        queue.asyncAfter(deadline: .now() + DNSChangeWatcher.settleSeconds) { [weak self] in
            guard let self else { return }
            self.passScheduled = false
            // A stopped watcher (the uninstall has begun) does nothing.
            if self.store != nil { self.onChange() }
        }
    }
}

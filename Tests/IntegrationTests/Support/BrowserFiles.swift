import Foundation
import Testing

// What each browser's policy file must hold and where it lives in the sandbox, written out from Design Plans/03-daemon-cli-app.md § 13
// BrowserPolicyEnforcer ("Targets and their managed keys", "Sandbox") and not read off the implementation.

// The four browsers SiteBlock writes a policy for.
enum BrowserUnderTest: CaseIterable, CustomTestStringConvertible {
    case chrome, edge, brave, firefox

    var testDescription: String { name }

    // The name used in the daemon's log line "browser policy repaired (<name>)".
    var name: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        }
    }

    // The preference domain, which is also the file name without ".plist".
    var bundleID: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.Edge"
        case .brave: return "com.brave.Browser"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    // The line the daemon logs when it rewrites this browser's files and no command caused it.
    var repairedLine: String { "browser policy repaired (\(name))" }

    // The key that holds this browser's block list.
    var listKey: String { self == .firefox ? "WebsiteFilter" : "URLBlocklist" }

    // Every key the design gives this browser (with the block list key included).
    var managedKeys: Set<String> {
        switch self {
        case .chrome: return ["URLBlocklist", "SafeSitesFilterBehavior", "ForceGoogleSafeSearch", "DnsOverHttpsMode"]
        case .edge: return ["URLBlocklist", "DnsOverHttpsMode", "ForceGoogleSafeSearch", "ForceBingSafeSearch"]
        case .brave: return ["URLBlocklist", "DnsOverHttpsMode", "SafeSitesFilterBehavior", "ForceGoogleSafeSearch"]
        case .firefox: return ["EnterprisePoliciesEnabled", "DNSOverHTTPS", "WebsiteFilter"]
        }
    }

    // What a file of this browser holds with the given block list and no other keys: the design's filter keys with their types, plus the list (omitted when empty). The list is Chrome-format entries for Chrome, Edge and Brave, and match patterns for Firefox, whose list sits in {Block: [...]}.
    func expected(list: [String], other: [String: Any] = [:]) -> [String: Any] {
        var plist = other
        switch self {
        case .chrome:
            plist["SafeSitesFilterBehavior"] = 1
            plist["ForceGoogleSafeSearch"] = true
            plist["DnsOverHttpsMode"] = "off"
        case .edge:
            plist["DnsOverHttpsMode"] = "off"
            plist["ForceGoogleSafeSearch"] = true
            plist["ForceBingSafeSearch"] = 2
        case .brave:
            plist["DnsOverHttpsMode"] = "off"
            plist["SafeSitesFilterBehavior"] = 1
            plist["ForceGoogleSafeSearch"] = true
        case .firefox:
            plist["EnterprisePoliciesEnabled"] = true
            plist["DNSOverHTTPS"] = ["Enabled": false, "Locked": true] as [String: Any]
        }
        if !list.isEmpty { plist[listKey] = self == .firefox ? ["Block": list] as [String: Any] : list }
        return plist
    }

    // The block list found in a file of this browser, or nil when the file or the key is missing or has an unexpected shape.
    func list(in plist: [String: Any]?) -> [String]? {
        guard let value = plist?[listKey] else { return nil }
        if self == .firefox { return (value as? [String: Any])?["Block"] as? [String] }
        return value as? [String]
    }

    // The list this browser should hold, given both lists.
    func pick(_ lists: (chrome: [String], firefox: [String])) -> [String] { self == .firefox ? lists.firefox : lists.chrome }
}

// The three kinds of file a browser has.
enum BrowserFileKind: CaseIterable, CustomTestStringConvertible {
    // root/ManagedPreferences/<bundle>.plist
    case machine
    // root/ManagedPreferences/<console user>/<bundle>.plist
    case user
    // root/Preferences/org.mozilla.firefox.plist (Firefox only)
    case libraryPreferences

    var testDescription: String {
        switch self {
        case .machine: return "machine-wide file"
        case .user: return "per-user file"
        case .libraryPreferences: return "Preferences file"
        }
    }
}

// One file to look at: which browser and which of its files.
struct BrowserFileRef: CustomTestStringConvertible {
    let browser: BrowserUnderTest
    let kind: BrowserFileKind

    var testDescription: String { "\(browser.name) \(kind.testDescription)" }

    // Every file the design writes: each browser's machine-wide and per-user file, and Firefox's third file.
    static let all: [BrowserFileRef] = BrowserUnderTest.allCases.flatMap { browser in
        [BrowserFileRef(browser: browser, kind: .machine), BrowserFileRef(browser: browser, kind: .user)] + (browser == .firefox ? [BrowserFileRef(browser: browser, kind: .libraryPreferences)] : [])
    }
}

// Where one sandbox daemon is expected to write the policy files of all four browsers.
struct BrowserFiles {
    // The sandbox folder.
    let root: String
    // The console user's name, or nil when root owns /dev/console (nobody logged in), in which case only the machine-wide files are written.
    let consoleUser: String?

    var managedDirectory: String { root + "/ManagedPreferences" }
    var preferencesDirectory: String { root + "/Preferences" }

    // The path of one file, or nil for a per-user file when nobody is logged in.
    func path(_ ref: BrowserFileRef) -> String? {
        switch ref.kind {
        case .machine: return managedDirectory + "/" + ref.browser.bundleID + ".plist"
        case .user: return consoleUser.map { managedDirectory + "/" + $0 + "/" + ref.browser.bundleID + ".plist" }
        case .libraryPreferences: return ref.browser == .firefox ? preferencesDirectory + "/org.mozilla.firefox.plist" : nil
        }
    }

    // The files that exist for one browser.
    func paths(of browser: BrowserUnderTest) -> [String] {
        BrowserFileRef.all.filter { $0.browser == browser }.compactMap { path($0) }
    }

    // Every file the daemon writes.
    var all: [String] { BrowserFileRef.all.compactMap { path($0) } }

    // The refs that exist on this Mac (a per-user ref is skipped when nobody is logged in).
    var refs: [BrowserFileRef] { BrowserFileRef.all.filter { path($0) != nil } }
}

extension SandboxDaemon {
    // Works out where the four browsers' files are from the sandbox folder and the owner of /dev/console. Throws when /dev/console cannot be inspected.
    func browserFiles() throws -> BrowserFiles {
        let attributes = try FileManager.default.attributesOfItem(atPath: "/dev/console")
        guard let uid = (attributes[.ownerAccountID] as? NSNumber)?.intValue, let name = attributes[.ownerAccountName] as? String, !name.isEmpty else {
            throw TestFailure("could not read the owner of /dev/console")
        }
        return BrowserFiles(root: root, consoleUser: uid == 0 ? nil : name)
    }
}

// Compares two property list values including their kind: boolean, whole number and decimal number are all different, and dictionaries and lists are compared entry by entry. Foundation's own equality treats true, 1 and 1.0 as equal, but a browser ignores a policy of the wrong type, so the tests must not. Written here independently of the daemon's own comparison.
func sameKinds(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (nil, _), (_, nil): return false
    default: break
    }
    guard let a, let b else { return false }
    if let x = a as? NSNumber, let y = b as? NSNumber {
        let xKind = CFGetTypeID(x) == CFBooleanGetTypeID() ? "bool" : (CFNumberIsFloatType(x as CFNumber) ? "real" : "int")
        let yKind = CFGetTypeID(y) == CFBooleanGetTypeID() ? "bool" : (CFNumberIsFloatType(y as CFNumber) ? "real" : "int")
        return xKind == yKind && x == y
    }
    if let x = a as? String, let y = b as? String { return x == y }
    if let x = a as? [Any], let y = b as? [Any] { return x.count == y.count && zip(x, y).allSatisfy { sameKinds($0, $1) } }
    if let x = a as? [String: Any], let y = b as? [String: Any] { return Set(x.keys) == Set(y.keys) && x.allSatisfy { sameKinds($0.value, y[$0.key]) } }
    return false
}

// True when the file at the path holds exactly the dictionary, value for value and kind for kind, is an XML property list, and has the mode 0644 the design gives the files.
func fileIsRight(_ path: String, _ expected: [String: Any]) -> Bool {
    guard let plist = readPlist(path) else { return false }
    return sameKinds(plist, expected) && plistFormat(path) == .xml && permissions(of: path) == 0o644
}

// The design's covering rule, written independently of the library: lowercase, remove duplicates, drop every host that ends in "." plus another host of the set (a parent domain, whole labels only), sort.
func shortestCover(_ hosts: [String]) -> [String] {
    let all = Set(hosts.map { $0.lowercased() })
    return all.filter { host in !all.contains(where: { $0 != host && host.hasSuffix("." + $0) }) }.sorted()
}

// The lists the design gives for whole-site blocks of some domains and path rules (domain and path pairs): the covering host list plus one `domain/path` entry per rule whose domain no whole-site entry covers, sorted, for Chrome, Edge and Brave; and `*://*.<host>/*` per covering host plus `*://*.<domain><path>*` per such rule for Firefox. Typed from 02-core-components.md § Engine, "Browser block list".
func designLists(sites: [String], rules: [(domain: String, path: String)] = []) -> (chrome: [String], firefox: [String]) {
    let cover = shortestCover(ExpectedHosts.expand(all: sites))
    let open = rules.filter { rule in !cover.contains(where: { rule.domain == $0 || rule.domain.hasSuffix("." + $0) }) }
    let chrome = (cover + open.map { $0.domain + $0.path }).sorted()
    let firefox = (cover.map { "*://*.\($0)/*" } + open.map { "*://*.\($0.domain)\($0.path)*" }).sorted()
    return (chrome, firefox)
}

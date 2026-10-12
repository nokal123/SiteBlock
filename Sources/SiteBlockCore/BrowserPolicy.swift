import Foundation

/// The block lists the browsers get: for Chrome, Edge and Brave a `URLBlocklist`, and for Firefox a `WebsiteFilter`. Each list is kept as two parts, the whole-site entries and the path-rule entries, so a list that is too long can be cut with the whole-site entries kept first.
public struct BrowserBlockLists: Equatable, Sendable {
    /// Chrome-format entries for whole sites, for example `youtube.com`.
    public var chromeSites: [String]
    /// Chrome-format entries for path rules, for example `youtube.com/shorts`.
    public var chromePaths: [String]
    /// Firefox match patterns for whole sites, for example `*://*.youtube.com/*`.
    public var firefoxSites: [String]
    /// Firefox match patterns for path rules, for example `*://*.youtube.com/shorts*`.
    public var firefoxPaths: [String]

    /// Creates the lists from their four parts; each defaults to empty.
    public init(chromeSites: [String] = [], chromePaths: [String] = [], firefoxSites: [String] = [], firefoxPaths: [String] = []) {
        self.chromeSites = chromeSites
        self.chromePaths = chromePaths
        self.firefoxSites = firefoxSites
        self.firefoxPaths = firefoxPaths
    }

    /// No entries at all; what the uninstaller passes so every list key is taken out of the browser files.
    public static let empty = BrowserBlockLists()

    /// The whole Chrome-format list: whole-site and path entries together, sorted.
    public var chrome: [String] { (chromeSites + chromePaths).sorted() }

    /// The whole Firefox list: whole-site and path patterns together, sorted.
    public var firefox: [String] { (firefoxSites + firefoxPaths).sorted() }
}

/// The browsers SiteBlock writes a protected policy for. Each one reads mandatory settings from its own preference domain (the name of its settings file), so each has its own keys.
public enum BrowserTarget: CaseIterable, Sendable {
    case chrome
    case edge
    case brave
    case firefox

    /// The name used in log lines, for example "Chrome".
    public var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        }
    }

    /// The browser's preference domain, which is also the name of its settings file without ".plist".
    public var bundleID: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.Edge"
        case .brave: return "com.brave.Browser"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    /// True for Firefox, which also reads `/Library/Preferences/org.mozilla.firefox.plist`, so that third file is written too.
    public var alsoUsesLibraryPreferencesFile: Bool { self == .firefox }

    /// Every key SiteBlock owns in this browser's policy file. `BrowserPolicy.merged` removes all of them before it adds the wanted values, so a stale value can never survive, and the uninstaller removes exactly these.
    public var managedKeys: Set<String> {
        switch self {
        case .chrome: return ChromePolicy.managedKeys
        case .edge: return [ChromePolicy.blocklistKey, ChromePolicy.dnsOverHTTPSKey, ChromePolicy.safeSearchKey, BrowserPolicy.bingSafeSearchKey]
        case .brave: return [ChromePolicy.blocklistKey, ChromePolicy.dnsOverHTTPSKey, ChromePolicy.safeSitesKey, ChromePolicy.safeSearchKey]
        case .firefox: return [BrowserPolicy.firefoxEnabledKey, BrowserPolicy.firefoxDNSOverHTTPSKey, BrowserPolicy.firefoxWebsiteFilterKey]
        }
    }

    /// The keys SiteBlock wants in this browser's policy file and their values. The block list key (`URLBlocklist`, or `WebsiteFilter` for Firefox) is included only when the list is not empty. The other keys are included only while `adultFilter` is true, which is always except during an uninstall. Types matter, because a browser ignores a policy of the wrong type: the Chrome-family keys use a whole number, a boolean and a string where each browser expects them, and Firefox's `DNSOverHTTPS` and `WebsiteFilter` are nested dictionaries.
    public func managedValues(blockList: [String], adultFilter: Bool) -> [String: Any] {
        var values: [String: Any] = [:]
        switch self {
        case .chrome, .edge, .brave:
            if !blockList.isEmpty { values[ChromePolicy.blocklistKey] = blockList }
            guard adultFilter else { return values }
            // Secure DNS off makes the browser use the Mac's own name lookups, so the family DNS servers and the hosts file reach it.
            values[ChromePolicy.dnsOverHTTPSKey] = "off"
            values[ChromePolicy.safeSearchKey] = true
            if self != .edge { values[ChromePolicy.safeSitesKey] = 1 }
            // Edge's Bing SafeSearch policy takes 2 for strict.
            if self == .edge { values[BrowserPolicy.bingSafeSearchKey] = 2 }
        case .firefox:
            if !blockList.isEmpty { values[BrowserPolicy.firefoxWebsiteFilterKey] = ["Block": blockList] }
            guard adultFilter else { return values }
            values[BrowserPolicy.firefoxEnabledKey] = true
            // Firefox's own DNS-over-HTTPS skips the hosts file, so it is switched off and locked so the person cannot switch it back on in Firefox's settings.
            values[BrowserPolicy.firefoxDNSOverHTTPSKey] = ["Enabled": false, "Locked": true] as [String: Any]
        }
        return values
    }

    /// The part of the block lists this browser uses, in the order the engine built them.
    public func lists(from lists: BrowserBlockLists) -> (sites: [String], paths: [String]) {
        self == .firefox ? (lists.firefoxSites, lists.firefoxPaths) : (lists.chromeSites, lists.chromePaths)
    }
}

/// The pure rules shared by every browser's policy file: how SiteBlock's keys are merged into a file that may hold other settings, how a too-long block list is cut, and how two settings are compared. Nothing here reads or writes a file, so it can be tested without root access.
public enum BrowserPolicy {
    /// Chrome, Edge and Brave read at most this many entries of their block list, and Firefox reads at most this many of its `WebsiteFilter` patterns; the rest are ignored.
    public static let maxListEntries = 1000

    /// The key in Edge's policy file that makes Bing SafeSearch strict.
    public static let bingSafeSearchKey = "ForceBingSafeSearch"
    /// The key in Firefox's policy file that turns enterprise policies on.
    public static let firefoxEnabledKey = "EnterprisePoliciesEnabled"
    /// The key in Firefox's policy file that holds the DNS-over-HTTPS settings dictionary.
    public static let firefoxDNSOverHTTPSKey = "DNSOverHTTPS"
    /// The key in Firefox's policy file that holds the website block list dictionary.
    public static let firefoxWebsiteFilterKey = "WebsiteFilter"

    /// Returns the contents a policy file should have: everything already in the file except SiteBlock's own keys, plus the wanted values for those keys. Every other key is kept, so a real company policy in the same file is never lost. When nothing is left the result is nil, which means the file should be deleted. A nil `existing` (no file, or a file that was not a property list dictionary) counts as an empty file.
    public static func merged(existing: [String: Any]?, managedKeys: Set<String>, managed: [String: Any]) -> [String: Any]? {
        var contents = existing ?? [:]
        for key in managedKeys { contents.removeValue(forKey: key) }
        for (key, value) in managed { contents[key] = value }
        return contents.isEmpty ? nil : contents
    }

    /// Cuts the block list to `limit` entries when it is too long, keeping the whole-site entries before the path entries so a long list of path rules can never push a whole-site block out. Returns the entries to write (sorted, so the file is the same on every pass) and how many were left out.
    public static func capped(sites: [String], paths: [String], limit: Int = maxListEntries) -> (list: [String], droppedCount: Int) {
        let all = sites.sorted() + paths.sorted()
        guard all.count > limit else { return (all.sorted(), 0) }
        return (Array(all.prefix(max(0, limit))).sorted(), all.count - max(0, limit))
    }

    /// True when the file's settings equal the wanted ones: the same set of keys, and for every key SiteBlock owns the same value of the same kind. The kind check is needed because Foundation treats the boolean true, the whole number 1 and the decimal number 1.0 as equal, but a browser ignores a policy whose type is wrong, so a hand edit that swaps one for another must not look correct. Nested dictionaries and lists are compared the same way, which matters for Firefox's `DNSOverHTTPS`.
    public static func sameSettings(_ current: [String: Any], _ wanted: [String: Any], managedKeys: Set<String>) -> Bool {
        guard Set(current.keys) == Set(wanted.keys) else { return false }
        // Keys SiteBlock does not own were copied from the file itself, so they only need to be equal in the ordinary sense; the owned keys below must match in kind too.
        let others: ([String: Any]) -> NSDictionary = { NSDictionary(dictionary: $0.filter { !managedKeys.contains($0.key) }) }
        guard others(current).isEqual(others(wanted)) else { return false }
        return managedKeys.allSatisfy { strictlyEqual(current[$0], wanted[$0]) }
    }

    /// Compares two property list values for equality including their kind: boolean, whole number, decimal number, text, list, dictionary, date and data are all different kinds, and lists and dictionaries are compared one entry at a time.
    public static func strictlyEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        default: break
        }
        guard let lhs, let rhs else { return false }
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber { return numberKind(a) == numberKind(b) && a.isEqual(to: b) }
        if let a = lhs as? String, let b = rhs as? String { return a == b }
        if let a = lhs as? [Any], let b = rhs as? [Any] { return a.count == b.count && zip(a, b).allSatisfy { strictlyEqual($0, $1) } }
        if let a = lhs as? [String: Any], let b = rhs as? [String: Any] { return Set(a.keys) == Set(b.keys) && a.allSatisfy { strictlyEqual($0.value, b[$0.key]) } }
        if let a = lhs as? Date, let b = rhs as? Date { return a == b }
        if let a = lhs as? Data, let b = rhs as? Data { return a == b }
        return false
    }

    /// The three kinds of property list number: 0 for a boolean, 1 for a whole number, 2 for a decimal number.
    private static func numberKind(_ number: NSNumber) -> Int {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return 0 }
        return CFNumberIsFloatType(number as CFNumber) ? 2 : 1
    }
}

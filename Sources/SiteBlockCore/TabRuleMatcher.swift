import Foundation

/// One thing the tab watcher looks for: a site plus the start of a path under it, such as youtube.com and /shorts. A whole blocked site is a rule whose path is `/`, which every address starts with. The tab watcher compares browser tab addresses against a list of these.
public struct WatchedPathRule: Hashable, Sendable {
    /// The path of a rule that stands for a whole blocked site. A real path rule never has it, because a path rule has no trailing `/`.
    public static let wholeSitePath = "/"

    /// The site name, already normalized the way the daemon stores it: lowercase, Punycode for non-ASCII letters, no leading `www.`, for example `youtube.com`.
    public let domain: String
    /// The start of the path, beginning with `/`, in its original case and without a trailing `/` or `*`, for example `/shorts`; or `/` alone for a whole site.
    public let path: String

    /// Creates a rule from its two parts.
    public init(domain: String, path: String) {
        self.domain = domain
        self.path = path
    }

    /// True when the rule stands for a whole blocked site rather than a part of one.
    public var isWholeSite: Bool { path == Self.wholeSitePath }

    /// The rule as people read it: the site name alone for a whole site (`x.com`), or the site and path joined (`youtube.com/shorts`).
    public var displayText: String { isWholeSite ? domain : PathRuleParser.display(domain: domain, path: path) }

    /// Seconds between tab checks while a path rule is watched. A site such as YouTube moves to a blocked part of itself without loading a page, and the content plays at once, so these checks stay frequent.
    public static let pathRuleCheckSeconds = 0.5
    /// Seconds between tab checks while only whole sites (or nothing) are watched. A tab on a blocked site has to be caught within about five seconds, and checking less often keeps the Apple Events sent to the browsers to a few a second.
    public static let wholeSiteCheckSeconds = 4.0

    /// How often the tab watcher looks at the tabs for this list of rules: every half second when it holds at least one path rule, otherwise every four seconds.
    public static func checkSeconds(for rules: [WatchedPathRule]) -> Double {
        rules.contains { !$0.isWholeSite } ? pathRuleCheckSeconds : wholeSiteCheckSeconds
    }
}

/// Decides whether the address of an open browser tab falls under a rule (a whole site or a part of one). The steps mirror what Chrome's `youtube.com/shorts` entry and Firefox's `*://*.youtube.com/shorts*` pattern match, so the tab watcher acts on exactly the tabs the browsers' own block lists cover.
public enum TabRuleMatcher {
    /// The two parts of a tab address that a rule is compared with.
    private struct Address {
        /// The host name, normalized with DomainNormalizer (lowercase, Punycode, no trailing dot, no leading `www.`).
        let host: String
        /// The percent-encoded path, or `/` when the address has none.
        let path: String
    }

    /// Returns the first rule, in list order, that the address falls under, or nil when it falls under none (or is not an ordinary web address).
    public static func matchingRule(url: String, rules: [WatchedPathRule]) -> WatchedPathRule? {
        // The address is read once and then compared with every rule, because reading it is the costly part.
        guard let address = address(from: url) else { return nil }
        return rules.first { matches(address, rule: $0) }
    }

    /// True when the address is an http or https address on the rule's site (or one of its subdomains) whose path starts with the rule's path.
    public static func matches(url: String, rule: WatchedPathRule) -> Bool {
        guard let address = address(from: url) else { return false }
        return matches(address, rule: rule)
    }

    /// Compares an already-read address with one rule.
    private static func matches(_ address: Address, rule: WatchedPathRule) -> Bool {
        // The host must be the rule's site or a subdomain of it. The dot in front of the rule's name makes "notyoutube.com" fail while "m.youtube.com" passes.
        guard address.host == rule.domain || address.host.hasSuffix("." + rule.domain) else { return false }
        // A plain, case-sensitive prefix test on the raw bytes, which is what the browsers do: "/shorts", "/shorts/abc" and "/shortsXYZ" all start with "/shorts", but "/Shorts" does not. Bytes are compared instead of characters so a combining mark after the last letter cannot hide the match.
        return address.path.utf8.starts(with: rule.path.utf8)
    }

    /// Reads the host and path out of a tab address, or returns nil when the address cannot be a blockable web page: it does not parse, its scheme is not http or https, or its host is missing, odd, or not a valid site name (an IP address, for example). Port, user info, query and fragment are ignored.
    private static func address(from url: String) -> Address? {
        guard let components = URLComponents(string: url) else { return nil }
        // Only web pages can be blocked by the browser's block list; chrome:, about:, file:, data: and javascript: addresses are left alone.
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let rawHost = components.host, !rawHost.isEmpty, !hasUnsafeHostCharacter(rawHost) else { return nil }
        // The same normalizer the rules went through, so both sides use one spelling. A host it refuses (an IP address, a bad label) cannot match any rule.
        guard let host = try? DomainNormalizer.normalize(rawHost) else { return nil }
        let path = components.percentEncodedPath
        return Address(host: host, path: path.isEmpty ? "/" : path)
    }

    /// True when the host holds a character that cannot be in a real host name. `URLComponents.host` turns percent-escapes back into characters, so "youtube.com%2Fx.evil.com" arrives as "youtube.com/x.evil.com" and "youtube.com%20" as "youtube.com ", and DomainNormalizer would then cut or trim them down to plain "youtube.com". Refusing these hosts keeps such an address from matching a site it does not belong to.
    private static func hasUnsafeHostCharacter(_ host: String) -> Bool {
        host.unicodeScalars.contains { scalar in
            switch scalar {
            case "/", "?", "#", "@", ":", "\\", "[", "]": return true
            default: return CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            }
        }
    }
}

/// What the tab watcher is given from each status snapshot.
public extension StatusSnapshot {
    /// The path rules the tab watcher looks for: every rule in the snapshot except those a temporary unblock currently has open, because an open rule is allowed for now and its tabs must be left alone. Rules waiting to open, or waiting to unblock for good, are still blocked, so they stay in. An older daemon that reports no path rules gives an empty list.
    var watchedPathRules: [WatchedPathRule] {
        (blockedPaths ?? []).filter { $0.temporaryUnblock?.isOpen != true }.map { WatchedPathRule(domain: $0.domain, path: $0.path) }
    }

    /// Everything the tab watcher looks for: one whole-site rule for each host the browsers' block list holds, followed by `watchedPathRules`. The hosts are those of every site whose temporary unblock is not open, shortened the way the browsers' list is (a host is left out when a parent domain of it is in the list) and normalized the way tab hosts are, so a listed `www.` name still matches. Whole-site rules come first, so a tab on a blocked site is reported under its site even when a path rule on that site also matches.
    var watchedTabRules: [WatchedPathRule] {
        let stillBlocked = blocked.filter { $0.temporaryUnblock?.isOpen != true }.map { BlockedSite(domain: $0.domain, hosts: $0.hosts) }
        // A host the normalizer refuses could never equal a normalized tab host, so it is dropped; normalizing can also turn two hosts into one, which the set removes.
        let hosts = Set(ChromePolicy.urlBlocklist(for: stillBlocked).compactMap { try? DomainNormalizer.normalize($0) }).sorted()
        return hosts.map { WatchedPathRule(domain: $0, path: WatchedPathRule.wholeSitePath) } + watchedPathRules
    }

    /// Seconds until the earliest countdown that changes `watchedTabRules` ends, or nil when none is running: a temporary unblock that opens (its start wait) or closes (its window), or an unblock for good that removes a site or rule. The status model polls again at that moment while the panel is closed, so the tab watcher does not keep sending tabs of a site that has just opened to the blocked page, or miss a site whose window has just closed, for the rest of a 30-second wait.
    var secondsUntilWatchedRulesChange: Int? {
        let temporary = blocked.compactMap(\.temporaryUnblock) + (blockedPaths ?? []).compactMap(\.temporaryUnblock)
        // A waiting unblock changes the list when it opens; an open one changes it when its window ends.
        let temporaryEnds = temporary.map { $0.isOpen ? $0.secondsRemaining : ($0.opensInSeconds ?? $0.secondsRemaining) }
        let unblockEnds = blocked.compactMap(\.unblockSecondsRemaining) + (blockedPaths ?? []).compactMap(\.unblockSecondsRemaining)
        return (temporaryEnds + unblockEnds).min()
    }
}

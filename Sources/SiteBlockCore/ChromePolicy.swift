import Foundation

/// The pure rules for the Chrome policy file SiteBlock writes: which site names go into Chrome's `URLBlocklist` list, which adult-filter settings sit beside it, and how they are put into a policy file that may already hold other settings. Nothing here reads or writes a file, so it can be tested without root access.
public enum ChromePolicy {
    /// The key in Chrome's policy file that holds the list of sites Chrome must refuse.
    public static let blocklistKey = "URLBlocklist"

    /// Returns the shortest list of host names that covers every host of every blocked site, lowercased and sorted. A Chrome `URLBlocklist` entry such as "youtube.com" also blocks every subdomain of it, so a host is left out when another host in the list is one of its parent domains ("www.youtube.com" is covered by "youtube.com"). Chrome reads at most 1,000 entries of this policy and ignores the rest, so keeping the list short keeps every site blocked. A site whose unblock countdown is still running is included, because it stays blocked until the countdown ends.
    public static func urlBlocklist(for sites: [BlockedSite]) -> [String] {
        // A Set drops the names that two sites share, and the final sort makes the list the same on every pass so it can be compared with the file.
        let all = Set(sites.flatMap(\.hosts).map { $0.lowercased() })
        return all.filter { !isCovered($0, by: all) }.sorted()
    }

    /// True when some other name in the set is a parent domain of the host, for example "youtube.com" for "m.youtube.com". Only whole labels count, so "notyoutube.com" is not covered by "youtube.com".
    private static func isCovered(_ host: String, by all: Set<String>) -> Bool {
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if all.contains(String(rest)) { return true }
        }
        return false
    }

    /// The key that makes Chrome check each top-level page against Google's adult-content classification and refuse flagged ones. The value 1 means "filter sites".
    public static let safeSitesKey = "SafeSitesFilterBehavior"
    /// The key that makes Google Search always use SafeSearch.
    public static let safeSearchKey = "ForceGoogleSafeSearch"
    /// The key that sets Chrome's Secure DNS mode. "off" makes Chrome use the Mac's own name lookups, so the family DNS servers reach Chrome too.
    public static let dnsOverHTTPSKey = "DnsOverHttpsMode"

    /// Every key SiteBlock owns in the policy file. `merged` removes all of them from the existing file before it adds the wanted values, so a stale value can never survive; every other key in the file is left alone.
    public static let managedKeys: Set<String> = [blocklistKey, safeSitesKey, safeSearchKey, dnsOverHTTPSKey]

    /// The keys SiteBlock wants in the policy file and their values. `URLBlocklist` is included only when the list is not empty (Chrome has nothing to refuse otherwise). The three adult-filter keys are included only when `adultFilter` is true: `SafeSitesFilterBehavior` as the whole number 1, `ForceGoogleSafeSearch` as the boolean true, and `DnsOverHttpsMode` as the text "off". The types matter, because Chrome ignores a policy whose type is wrong.
    public static func managedValues(blocklist: [String], adultFilter: Bool) -> [String: Any] {
        var values: [String: Any] = [:]
        if !blocklist.isEmpty { values[blocklistKey] = blocklist }
        if adultFilter {
            values[safeSitesKey] = 1
            values[safeSearchKey] = true
            values[dnsOverHTTPSKey] = "off"
        }
        return values
    }

    /// Returns the contents the policy file should have: everything already in the file except SiteBlock's own keys, plus the wanted values for those keys. Every other key is kept, so a real company policy in the same file is never lost. A key SiteBlock owns that is not in `managed` is removed (for example `URLBlocklist` once nothing is blocked). When nothing is left the result is nil, which means the file should be deleted. A nil `existing` (no file, or a file that was not a property list dictionary) counts as an empty file.
    public static func merged(existing: [String: Any]?, managed: [String: Any]) -> [String: Any]? {
        var contents = existing ?? [:]
        for key in managedKeys { contents.removeValue(forKey: key) }
        for (key, value) in managed { contents[key] = value }
        return contents.isEmpty ? nil : contents
    }
}

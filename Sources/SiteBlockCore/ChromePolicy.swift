import Foundation

/// The pure rules for the Chrome policy file SiteBlock writes: which site names go into Chrome's `URLBlocklist` list, and how that list is put into a policy file that may already hold other settings. Nothing here reads or writes a file, so it can be tested without root access.
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

    /// Returns the contents the policy file should have: everything already in the file, with `URLBlocklist` set to the given list. Every other key is kept, so a real company policy in the same file is never lost. An empty list removes the `URLBlocklist` key instead, and when nothing else is left the result is nil, which means the file should be deleted. A nil `existing` (no file, or a file that was not a property list dictionary) counts as an empty file.
    public static func merged(existing: [String: Any]?, blocklist: [String]) -> [String: Any]? {
        var contents = existing ?? [:]
        if blocklist.isEmpty {
            contents.removeValue(forKey: blocklistKey)
            return contents.isEmpty ? nil : contents
        }
        contents[blocklistKey] = blocklist
        return contents
    }
}

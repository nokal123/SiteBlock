import Foundation

// What the sandbox hosts file must contain, written out from the design (02-core-components.md § DomainExpander and § HostsFileEditor), not read off the implementation.

// The standard macOS hosts file the sandbox starts with: comment header, then the loopback and broadcast lines. It ends with exactly one newline.
enum StandardHosts {
    static let text = "##\n# Host Database\n#\n# localhost is used to configure the loopback interface\n# when the system is booting.  Do not change this entry.\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"
}

// Builders for the exact hosts text the design promises.
enum ExpectedHosts {
    // The first and last line of the managed section, exactly as written in the design.
    static let beginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted"
    static let endMarker = "# END SiteBlock"

    // The common prefixes every domain gets, from the design.
    static let commonPrefixes = ["www", "m", "mobile", "old", "new", "amp", "app", "web"]

    // The related-names table from the design, for the sites these tests block.
    static let relatedDomains: [String: [String]] = [
        "reddit.com": ["np.reddit.com", "i.reddit.com", "oauth.reddit.com", "gateway.reddit.com", "gql.reddit.com", "sh.reddit.com", "redd.it", "i.redd.it", "v.redd.it", "preview.redd.it", "external-preview.redd.it", "redditstatic.com", "www.redditstatic.com", "redditmedia.com"],
        "youtube.com": ["music.youtube.com", "tv.youtube.com", "studio.youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com", "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com"],
        "x.com": xAndTwitter,
        "twitter.com": xAndTwitter,
    ]
    private static let xAndTwitter = ["x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "api.x.com", "api.twitter.com", "pbs.twimg.com", "abs.twimg.com", "video.twimg.com"]

    // Every host name a domain expands to: the base, its prefixes, the related names, and www. and m. in front of each two-label related name. Sorted, no duplicates.
    static func expand(_ domain: String) -> [String] {
        var hosts: Set<String> = [domain]
        for prefix in commonPrefixes { hosts.insert("\(prefix).\(domain)") }
        for related in relatedDomains[domain] ?? [] {
            hosts.insert(related)
            if related.split(separator: ".").count == 2 {
                hosts.insert("www.\(related)")
                hosts.insert("m.\(related)")
            }
        }
        return hosts.sorted()
    }

    // The union of several domains' expansions, sorted, with no duplicates (what the hosts file holds when all of them are blocked).
    static func expand(all domains: [String]) -> [String] {
        Array(Set(domains.flatMap { expand($0) })).sorted()
    }

    // The two names Apple documents as the signal that turns iCloud Private Relay off. 01-overview-and-data.md § How Blocking Works (the Adult content filter paragraph) and 02-core-components.md § Engine (`privateRelayHosts`, `hostsToWrite`): the adult content filter is always on, so the daemon always writes these two names into its hosts section, even with no site blocked. They are written out here from the design, not read from the code.
    static let privateRelayHosts = ["mask-h2.icloud.com", "mask.icloud.com"]

    // The four hostnames Firefox and other browsers use for their own DNS-over-HTTPS by default, typed from 01-overview-and-data.md § How Blocking Works ("Other browsers") and 02-core-components.md § Engine (`dohBypassHosts`). The adult content filter is always on, so the daemon always writes these into the hosts section too: a browser that tries them falls back to the Mac's own lookups.
    static let dohBypassHosts = ["doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"]

    // Everything the daemon writes into the section for a set of blocked hosts: the blocked hosts plus the two Private Relay names and the four DNS-over-HTTPS names, sorted, without duplicates. Design change (02 § Engine, `hostsToWrite`): with nothing blocked the result is those six names, not an empty list, because the family DNS layer of the adult content filter is always on. The DNS-over-HTTPS names were added by the design that protects Firefox, Edge and Brave (01 § How Blocking Works, "Other browsers").
    static func hostsToWrite(blocking hosts: [String]) -> [String] {
        Array(Set(hosts + privateRelayHosts + dohBypassHosts)).sorted()
    }

    // The two lines written for one host name.
    static func lines(for host: String) -> [String] {
        ["0.0.0.0 \(host)", ":: \(host)"]
    }

    // The managed section for the blocked hosts: BEGIN line, then for each host to write (the blocked hosts plus the Private Relay names, sorted) the IPv4 line and the IPv6 line, then END line, ending with a newline.
    static func section(for hosts: [String]) -> String {
        var text = beginMarker + "\n"
        for host in hostsToWrite(blocking: hosts) { text += lines(for: host).joined(separator: "\n") + "\n" }
        return text + endMarker + "\n"
    }

    // The whole file: the user's own text (ending in one newline), one empty line, then the managed section. Design change (01 § How Blocking Works, Adult content filter): the section always exists, because the Private Relay names are always written; with nothing blocked it holds only those two names.
    static func text(original: String = StandardHosts.text, blocking hosts: [String]) -> String {
        original + "\n" + section(for: hosts)
    }

    // The file a running daemon keeps when nothing is blocked: the macOS lines plus a section of only the always-written names (Private Relay and DNS-over-HTTPS).
    static let idleText = text(blocking: [])
}

// A hosts file split into lines so tests can ask which names are blocked and which lines sit inside the managed section.
struct HostsView {
    let text: String

    // Creates a view of the given text; a missing file is treated as empty text.
    init(_ text: String?) { self.text = text ?? "" }

    // Every line, without the newline characters.
    var lines: [String] { text.components(separatedBy: "\n") }

    // How many BEGIN marker lines the file has.
    var beginCount: Int { lines.filter { $0.hasPrefix("# BEGIN SiteBlock") }.count }

    // How many END marker lines the file has.
    var endCount: Int { lines.filter { $0 == ExpectedHosts.endMarker }.count }

    // The lines between the first BEGIN and the first END marker (empty when there is no complete section).
    var managedLines: [String] {
        let all = lines
        guard let begin = all.firstIndex(where: { $0.hasPrefix("# BEGIN SiteBlock") }), let end = all[begin...].firstIndex(of: ExpectedHosts.endMarker) else { return [] }
        return Array(all[(begin + 1)..<end])
    }

    // True when the file has both the IPv4 line and the IPv6 line for the host.
    func blocks(_ host: String) -> Bool {
        let present = Set(lines)
        return ExpectedHosts.lines(for: host).allSatisfy { present.contains($0) }
    }

    // How many times a given exact line appears.
    func count(of line: String) -> Int { lines.filter { $0 == line }.count }
}

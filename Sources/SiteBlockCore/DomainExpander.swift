import Foundation

/// Turns one base domain into every host name that must go into the hosts file, because the hosts file has no wildcards.
public enum DomainExpander {
    /// Prefixes tried in front of every blocked domain.
    public static let commonPrefixes: [String] = ["www", "m", "mobile", "old", "new", "amp", "app", "web"]

    // Twitter and X are the same service under two names, so both domains share this one list.
    private static let twitterNames: [String] = [
        "x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "api.x.com", "api.twitter.com",
        "pbs.twimg.com", "abs.twimg.com", "video.twimg.com",
    ]

    /// Extra names for well-known sites, keyed by base domain. Shared infrastructure such as t.co, fbcdn.net and googlevideo.com is left out on purpose, because each serves more than one product.
    public static let relatedDomains: [String: [String]] = [
        "reddit.com": [
            "np.reddit.com", "i.reddit.com", "oauth.reddit.com", "gateway.reddit.com", "gql.reddit.com", "sh.reddit.com",
            "redd.it", "i.redd.it", "v.redd.it", "preview.redd.it", "external-preview.redd.it",
            "redditstatic.com", "www.redditstatic.com", "redditmedia.com",
        ],
        // ytimg.com and youtube.googleapis.com serve only YouTube (thumbnails, page files, its API), so blocking them breaks nothing else.
        "youtube.com": [
            "music.youtube.com", "tv.youtube.com", "studio.youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com",
            "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com",
        ],
        "x.com": twitterNames,
        "twitter.com": twitterNames,
        "facebook.com": ["web.facebook.com", "mbasic.facebook.com", "touch.facebook.com", "fb.com", "fb.me"],
        "instagram.com": ["i.instagram.com", "help.instagram.com", "instagr.am"],
        "tiktok.com": ["vm.tiktok.com", "vt.tiktok.com"],
        "netflix.com": ["help.netflix.com"],
        "twitch.tv": ["clips.twitch.tv", "player.twitch.tv", "gql.twitch.tv"],
        "linkedin.com": ["lnkd.in"],
    ]

    /// Returns the sorted, duplicate-free list of host names to block for a normalized base domain: the domain, the common prefixes, the related names, and www./m. forms of related two-label names.
    public static func expand(_ domain: String) -> [String] {
        let base = domain.lowercased()
        var hosts: Set<String> = [base]
        for prefix in commonPrefixes { hosts.insert("\(prefix).\(base)") }
        for related in relatedDomains[base] ?? [] {
            hosts.insert(related)
            // A related name with exactly two labels (like redd.it) is a site of its own, so its www. and m. forms need blocking too.
            if related.components(separatedBy: ".").count == 2 {
                hosts.insert("www.\(related)")
                hosts.insert("m.\(related)")
            }
        }
        return hosts.sorted()
    }
}

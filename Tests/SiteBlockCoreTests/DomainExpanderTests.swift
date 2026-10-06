import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § DomainExpander. The related-domains table below is a
// separate copy typed from the design, so a typo or missing entry in the source is caught by comparison.

private let designPrefixes = ["www", "m", "mobile", "old", "new", "amp", "app", "web"]

private let twitterFamily = ["x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "api.x.com", "api.twitter.com", "pbs.twimg.com", "abs.twimg.com", "video.twimg.com"]

private let designRelated: [String: [String]] = [
    "reddit.com": ["np.reddit.com", "i.reddit.com", "oauth.reddit.com", "gateway.reddit.com", "gql.reddit.com", "sh.reddit.com", "redd.it", "i.redd.it", "v.redd.it", "preview.redd.it", "external-preview.redd.it", "redditstatic.com", "www.redditstatic.com", "redditmedia.com"],
    "youtube.com": ["music.youtube.com", "tv.youtube.com", "studio.youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com", "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com"],
    "x.com": twitterFamily,
    "twitter.com": twitterFamily,
    "facebook.com": ["web.facebook.com", "mbasic.facebook.com", "touch.facebook.com", "fb.com", "fb.me"],
    "instagram.com": ["i.instagram.com", "help.instagram.com", "instagr.am"],
    "tiktok.com": ["vm.tiktok.com", "vt.tiktok.com"],
    "netflix.com": ["help.netflix.com"],
    "twitch.tv": ["clips.twitch.tv", "player.twitch.tv", "gql.twitch.tv"],
    "linkedin.com": ["lnkd.in"],
]

// Applies the design's expansion rule to the design's table: base, prefix.base for each prefix, every related name,
// and www./m. in front of each related name that has exactly two labels; then sort and remove duplicates.
private func referenceExpand(_ base: String) -> [String] {
    var hosts: Set<String> = [base]
    for prefix in designPrefixes { hosts.insert("\(prefix).\(base)") }
    for related in designRelated[base] ?? [] {
        hosts.insert(related)
        if related.split(separator: ".").count == 2 {
            hosts.insert("www.\(related)")
            hosts.insert("m.\(related)")
        }
    }
    return hosts.sorted()
}

@Suite struct DomainExpanderTests {
    @Test func commonPrefixesAreTheEightFromTheDesignInOrder() {
        #expect(DomainExpander.commonPrefixes == designPrefixes)
    }

    @Test func relatedDomainsTableHasExactlyTheDesignKeysAndLists() {
        #expect(Set(DomainExpander.relatedDomains.keys) == Set(designRelated.keys))
        for (key, expected) in designRelated {
            #expect(Set(DomainExpander.relatedDomains[key] ?? []) == Set(expected), "related list for \(key)")
        }
    }

    // 05-testing-and-operations.md: a plain domain gets exactly the base plus the eight prefixes.
    @Test func expandOfAPlainDomainIsExactlyTheBasePlusTheEightPrefixes() {
        let expected = ["amp.example.com", "app.example.com", "example.com", "m.example.com", "mobile.example.com", "new.example.com", "old.example.com", "web.example.com", "www.example.com"]
        #expect(DomainExpander.expand("example.com") == expected)
    }

    @Test(arguments: ["old.reddit.com", "xn--bcher-kva.de", "a.b.c.example.org", "example.co.uk", "x.io", "notreddit.com", "reddit.com.au", "www.reddit.com"])
    func expandOfADomainNotInTheTableIsExactlyNinePrefixedNames(domain: String) {
        let expected = ([domain] + designPrefixes.map { "\($0).\(domain)" }).sorted()
        #expect(DomainExpander.expand(domain) == expected)
        #expect(expected.count == 9)
    }

    @Test(arguments: ["reddit.com", "youtube.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "tiktok.com", "netflix.com", "twitch.tv", "linkedin.com"])
    func expandOfEachTableDomainMatchesTheDesignRule(domain: String) {
        #expect(DomainExpander.expand(domain) == referenceExpand(domain))
    }

    // Literal, hand-sorted expected lists for four table domains, so the comparison does not depend on re-running the rule.
    @Test func expandOfTwitchTvIsTheExactSortedList() {
        let expected = ["amp.twitch.tv", "app.twitch.tv", "clips.twitch.tv", "gql.twitch.tv", "m.twitch.tv", "mobile.twitch.tv", "new.twitch.tv", "old.twitch.tv", "player.twitch.tv", "twitch.tv", "web.twitch.tv", "www.twitch.tv"]
        #expect(DomainExpander.expand("twitch.tv") == expected)
    }

    @Test func expandOfNetflixComIsTheExactSortedList() {
        let expected = ["amp.netflix.com", "app.netflix.com", "help.netflix.com", "m.netflix.com", "mobile.netflix.com", "netflix.com", "new.netflix.com", "old.netflix.com", "web.netflix.com", "www.netflix.com"]
        #expect(DomainExpander.expand("netflix.com") == expected)
    }

    @Test func expandOfTiktokComIsTheExactSortedList() {
        let expected = ["amp.tiktok.com", "app.tiktok.com", "m.tiktok.com", "mobile.tiktok.com", "new.tiktok.com", "old.tiktok.com", "tiktok.com", "vm.tiktok.com", "vt.tiktok.com", "web.tiktok.com", "www.tiktok.com"]
        #expect(DomainExpander.expand("tiktok.com") == expected)
    }

    // lnkd.in has exactly two labels, so it also gets www. and m. in front.
    @Test func expandOfLinkedinComIsTheExactSortedListIncludingTheShortLinkDomainForms() {
        let expected = ["amp.linkedin.com", "app.linkedin.com", "linkedin.com", "lnkd.in", "m.linkedin.com", "m.lnkd.in", "mobile.linkedin.com", "new.linkedin.com", "old.linkedin.com", "web.linkedin.com", "www.linkedin.com", "www.lnkd.in"]
        #expect(DomainExpander.expand("linkedin.com") == expected)
    }

    @Test func expandOfInstagramComIsTheExactSortedList() {
        let expected = ["amp.instagram.com", "app.instagram.com", "help.instagram.com", "i.instagram.com", "instagr.am", "instagram.com", "m.instagr.am", "m.instagram.com", "mobile.instagram.com", "new.instagram.com", "old.instagram.com", "web.instagram.com", "www.instagr.am", "www.instagram.com"]
        #expect(DomainExpander.expand("instagram.com") == expected)
    }

    @Test func expandOfRedditComIncludesTheShortLinkAndMediaHostsAndTheirWwwAndMForms() {
        let hosts = Set(DomainExpander.expand("reddit.com"))
        for host in ["reddit.com", "www.reddit.com", "m.reddit.com", "redd.it", "www.redd.it", "m.redd.it", "i.redd.it", "v.redd.it", "preview.redd.it", "external-preview.redd.it", "np.reddit.com", "oauth.reddit.com", "gateway.reddit.com", "gql.reddit.com", "sh.reddit.com", "i.reddit.com", "redditstatic.com", "www.redditstatic.com", "m.redditstatic.com", "redditmedia.com", "www.redditmedia.com", "m.redditmedia.com"] {
            #expect(hosts.contains(host), "missing \(host)")
        }
        // Three-label related names do not get www. or m. in front.
        for host in ["www.np.reddit.com", "m.i.redd.it", "www.i.redd.it", "www.oauth.reddit.com", "m.preview.redd.it"] {
            #expect(!hosts.contains(host), "unexpected \(host)")
        }
    }

    // youtube.com is the site the user most wants blocked, so its full expansion is written out by hand from the design's rule:
    // the base, the 8 prefixes, the 11 related names, and www./m. in front of the three two-label related names
    // (youtu.be, youtube-nocookie.com, youtubekids.com). 1 + 8 + 11 + 6 = 26 names.
    @Test func expandOfYoutubeComIsTheExactSortedListOfTwentySixNames() {
        let expected = [
            "amp.youtube.com", "app.youtube.com", "i.ytimg.com", "m.youtu.be", "m.youtube-nocookie.com", "m.youtube.com", "m.youtubekids.com",
            "mobile.youtube.com", "music.youtube.com", "new.youtube.com", "old.youtube.com", "s.ytimg.com", "studio.youtube.com", "tv.youtube.com",
            "web.youtube.com", "www.youtu.be", "www.youtube-nocookie.com", "www.youtube.com", "www.youtubekids.com", "youtu.be",
            "youtube-nocookie.com", "youtube.com", "youtube.googleapis.com", "youtubei.googleapis.com", "youtubekids.com", "yt3.ggpht.com",
        ]
        #expect(expected.count == 26)
        #expect(DomainExpander.expand("youtube.com") == expected)
    }

    @Test func expandOfYoutubeComIncludesTheMainSiteShortLinkKidsStudioAndImageHosts() {
        let hosts = Set(DomainExpander.expand("youtube.com"))
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "tv.youtube.com", "studio.youtube.com", "youtu.be", "www.youtu.be", "m.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com", "m.youtube-nocookie.com", "youtubekids.com", "www.youtubekids.com", "m.youtubekids.com", "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com"] {
            #expect(hosts.contains(host), "missing \(host)")
        }
        // Three-label related names do not get www. or m. in front, and the bare shared parents are not listed.
        for host in ["www.studio.youtube.com", "m.studio.youtube.com", "www.i.ytimg.com", "m.s.ytimg.com", "ytimg.com", "googleapis.com", "ggpht.com", "googlevideo.com", "www.youtube.googleapis.com"] {
            #expect(!hosts.contains(host), "unexpected \(host)")
        }
    }

    // 05-testing-and-operations.md: x.com and twitter.com both cover each other.
    @Test(arguments: [("x.com", "twitter.com"), ("twitter.com", "x.com")])
    func expandOfXAndTwitterEachCoverTheOtherSite(domain: String, other: String) {
        let hosts = Set(DomainExpander.expand(domain))
        for host in [domain, "www.\(domain)", "m.\(domain)", "mobile.\(domain)", other, "www.\(other)", "m.\(other)", "mobile.\(other)", "api.\(other)", "api.\(domain)", "pbs.twimg.com", "abs.twimg.com", "video.twimg.com"] {
            #expect(hosts.contains(host), "expand(\(domain)) is missing \(host)")
        }
    }

    // The design leaves shared infrastructure out on purpose, because blocking it would break sites the user did not choose.
    @Test(arguments: ["reddit.com", "youtube.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "tiktok.com", "netflix.com", "twitch.tv", "linkedin.com"])
    func expandNeverIncludesSharedInfrastructureNames(domain: String) {
        let hosts = Set(DomainExpander.expand(domain))
        for shared in ["t.co", "fbcdn.net", "googlevideo.com", "www.t.co", "cdninstagram.com", "akamaihd.net", "cloudfront.net", "googleapis.com", "ggpht.com"] {
            #expect(!hosts.contains(shared), "\(domain) must not expand to the shared name \(shared)")
        }
    }

    @Test(arguments: ["example.com", "reddit.com", "youtube.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "tiktok.com", "netflix.com", "twitch.tv", "linkedin.com", "bücher.de", "a.b.c.d.example.org"])
    func expandOutputIsSortedHasNoDuplicatesAndContainsTheBase(domain: String) {
        let result = DomainExpander.expand(domain)
        #expect(result == result.sorted())
        #expect(Set(result).count == result.count)
        #expect(result.contains(domain))
        #expect(DomainExpander.expand(domain) == result)
    }

    // Every name goes into /etc/hosts, so none may contain whitespace, uppercase, a comment character, or an empty label.
    @Test(arguments: ["reddit.com", "youtube.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "tiktok.com", "netflix.com", "twitch.tv", "linkedin.com", "xn--bcher-kva.de"])
    func expandOutputContainsOnlyHostsFileSafeNames(domain: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        for host in DomainExpander.expand(domain) {
            #expect(host.allSatisfy { allowed.contains($0) }, "unsafe characters in \(host)")
            #expect(!host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains(".."), "malformed \(host)")
            #expect(host.split(separator: ".").count >= 2, "single-label name \(host) would block a top-level domain")
        }
    }
}

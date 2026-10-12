import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § 3b TabRuleMatcher (the six matching steps and the behavioral notes), with the rule shapes
// from § DomainNormalizer and § 3a PathRuleParser, and from 05-testing-and-operations.md § Unit Tests (TabRuleMatcherTests). The sample rule is the one
// the design uses: domain youtube.com with path /shorts. Step 3 names the unsafe-host-character check (a host holding / ? # @ : \ [ ], whitespace or a control
// character gives no match, which is what keeps youtube.com%2Fx.evil.com from matching), step 5 says a raw space or control character in the path is
// percent-encoded by URLComponents and compared in that encoded form, and the behavioral notes say a subdomain the normalizer refuses (an underscore, a label
// over 63 characters) gives no match. Where the design is silent the test only asserts what the design does say.

private let shorts = WatchedPathRule(domain: "youtube.com", path: "/shorts")

// Asks both public entry points about one address and one rule. Records an issue when they disagree, so every table below checks both at once.
private func verdict(_ url: String, _ rule: WatchedPathRule = shorts) -> Bool {
    let single = TabRuleMatcher.matches(url: url, rule: rule)
    let listed = TabRuleMatcher.matchingRule(url: url, rules: [rule]) == rule
    #expect(single == listed, "matches(url:rule:) and matchingRule(url:rules:) disagree for \(url.debugDescription)")
    return single
}

// A small seeded random generator (SplitMix64) so the generated cases are repeatable.
private struct MatcherGenerator: RandomNumberGenerator {
    var state: UInt64
    // Produces the next 64 random bits.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - the rule type

@Suite struct WatchedPathRuleTests {
    // The type is Hashable: equal when both parts are equal, and usable in a Set.
    @Test func rulesWithTheSamePartsAreEqualAndHashTogether() {
        let a = WatchedPathRule(domain: "youtube.com", path: "/shorts")
        let b = WatchedPathRule(domain: "youtube.com", path: "/shorts")
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a.domain == "youtube.com")
        #expect(a.path == "/shorts")
    }

    // A different domain or a different path (the path keeps its case) is a different rule.
    @Test func rulesThatDifferInEitherPartAreDifferent() {
        let base = WatchedPathRule(domain: "youtube.com", path: "/shorts")
        #expect(base != WatchedPathRule(domain: "youtube.org", path: "/shorts"))
        #expect(base != WatchedPathRule(domain: "youtube.com", path: "/Shorts"))
        #expect(base != WatchedPathRule(domain: "youtube.com", path: "/shorts/a"))
        #expect(Set([base, WatchedPathRule(domain: "youtube.com", path: "/Shorts")]).count == 2)
    }
}

// MARK: - schemes (step 2)

@Suite struct TabRuleMatcherSchemeTests {
    // "The scheme, compared without regard to case, must be http or https."
    @Test(arguments: ["http", "https", "HTTP", "HTTPS", "Http", "hTTpS", "hTtP", "HttpS"])
    func httpAndHttpsMatchInAnyLetterCase(scheme: String) {
        #expect(verdict("\(scheme)://youtube.com/shorts"), "\(scheme) must be accepted")
        #expect(verdict("\(scheme)://www.youtube.com/shorts/abc?x=1#t"), "\(scheme) must be accepted with a full address")
    }

    // "Any other scheme (chrome:, about:, file:, data:, javascript:) and a missing scheme give no match", and the design's test list adds ftp:.
    // Every address here names youtube.com/shorts somewhere, so only the scheme rule keeps it from matching.
    @Test(arguments: [
        "chrome://youtube.com/shorts",
        "chrome://newtab/",
        "about:blank#youtube.com/shorts",
        "about:youtube.com/shorts",
        "file://youtube.com/shorts",
        "file:///Users/me/youtube.com/shorts",
        "data:text/html,https://youtube.com/shorts",
        "javascript:window.location='https://youtube.com/shorts'",
        "ftp://youtube.com/shorts",
        "ws://youtube.com/shorts",
        "wss://youtube.com/shorts",
        "blob:https://youtube.com/3b1c-aa",
        "view-source:https://youtube.com/shorts",
        "chrome-extension://abcdefghijklmnop/youtube.com/shorts",
        "mailto:youtube.com/shorts",
        "FTP://youtube.com/shorts",
        "CHROME://youtube.com/shorts",
    ])
    func everyOtherSchemeIsLeftAlone(url: String) {
        #expect(!verdict(url), "\(url) is not an http or https address")
    }

    // A scheme that only contains or resembles http/https is not http/https: the comparison is on the whole scheme.
    @Test(arguments: [
        "httpss://youtube.com/shorts",
        "xhttp://youtube.com/shorts",
        "xhttps://youtube.com/shorts",
        "http+x://youtube.com/shorts",
        "https-://youtube.com/shorts",
        "https.://youtube.com/shorts",
        "htt://youtube.com/shorts",
        "ttps://youtube.com/shorts",
        "httpx://youtube.com/shorts",
        "h://youtube.com/shorts",
    ])
    func aSchemeThatOnlyResemblesHttpIsLeftAlone(url: String) {
        #expect(!verdict(url), "\(url) does not have the scheme http or https")
    }

    // "a missing scheme give no match": a bare host, a path, a scheme-relative address, and a colon with nothing before it.
    @Test(arguments: [
        "youtube.com/shorts",
        "www.youtube.com/shorts",
        "//youtube.com/shorts",
        "//www.youtube.com/shorts/abc",
        "://youtube.com/shorts",
        "/shorts",
        "shorts",
        "youtube.com",
        "youtube.com:443/shorts",
        "www.youtube.com:8080/shorts",
    ])
    func anAddressWithNoSchemeIsLeftAlone(url: String) {
        #expect(!verdict(url), "\(url) has no http or https scheme")
    }

    // An http or https scheme without a host (step 3: "When it is nil or empty, there is no match").
    @Test(arguments: [
        "https:youtube.com/shorts",
        "https:/youtube.com/shorts",
        "http:/youtube.com/shorts",
        "https:///shorts",
        "https:///youtube.com/shorts",
        "http:///youtube.com/shorts",
        "https://",
        "http://",
        "https:",
        "http:",
        "https://:443/shorts",
        "https://@/shorts",
        "https://user@/shorts",
        "https://./shorts",
        "https://.../shorts",
    ])
    func aWebSchemeWithoutAUsableHostIsLeftAlone(url: String) {
        #expect(!verdict(url), "\(url) has no host to compare")
    }
}

// MARK: - hosts (steps 3 and 4)

@Suite struct TabRuleMatcherHostTests {
    // Step 4: "The host matches when it equals the rule's domain or ends with "." + domain", after step 3 lowercases it, strips one trailing dot and one leading www.
    @Test(arguments: [
        "https://youtube.com/shorts",
        "https://www.youtube.com/shorts",
        "https://m.youtube.com/shorts",
        "https://www.m.youtube.com/shorts",
        "https://music.youtube.com/shorts",
        "https://a.b.c.d.youtube.com/shorts",
        "https://www.www.youtube.com/shorts",
        "https://wwww.youtube.com/shorts",
        "https://m.www.youtube.com/shorts",
        "https://xn--bcher-kva.youtube.com/shorts",
        "https://a-b.youtube.com/shorts",
        "https://1.youtube.com/shorts",
        "https://127.0.0.1.youtube.com/shorts",
    ])
    func theRulesSiteAndEverySubdomainOfItMatch(url: String) {
        #expect(verdict(url), "\(url) is on youtube.com")
    }

    // Look-alike hosts that merely contain or end like the rule's name. The dot in front of the name is what keeps notyoutube.com out.
    @Test(arguments: [
        "https://notyoutube.com/shorts",
        "https://xyoutube.com/shorts",
        "https://wwwyoutube.com/shorts",
        "https://my-youtube.com/shorts",
        "https://evil-youtube.com/shorts",
        "https://youtube.com.evil.com/shorts",
        "https://www.youtube.com.evil.com/shorts",
        "https://youtube.com-evil.com/shorts",
        "https://youtube.co/shorts",
        "https://youtube.org/shorts",
        "https://youtube.comm/shorts",
        "https://youtube.community/shorts",
        "https://youtubecom/shorts",
        "https://youtube/shorts",
        "https://com/shorts",
        "https://evil.com/youtube.com/shorts",
        "https://evil.com/shorts/youtube.com",
        "https://evil.com?youtube.com/shorts",
        "https://evil.com#youtube.com/shorts",
        "https://evil.com/shorts?host=youtube.com",
        "https://evil.com:443/shorts",
        "https://localhost/shorts",
        "https://youtube.com.localhost/shorts",
        "https://youtube.com.local/shorts",
    ])
    func lookAlikeHostsDoNotMatch(url: String) {
        #expect(!verdict(url), "\(url) is not on youtube.com")
    }

    // "a trailing dot and capital letters are accepted": the host is lowercased and one trailing dot is removed before the comparison.
    @Test(arguments: [
        "https://youtube.com./shorts",
        "https://www.youtube.com./shorts",
        "https://m.youtube.com./shorts",
        "https://YOUTUBE.COM/shorts",
        "https://YouTube.Com/shorts",
        "https://WWW.YOUTUBE.COM/shorts",
        "https://M.YouTube.com./shorts",
        "HTTPS://WWW.YOUTUBE.COM:443/shorts",
    ])
    func aTrailingDotAndCapitalLettersAreAccepted(url: String) {
        #expect(verdict(url), "\(url) is on youtube.com")
    }

    // Capital letters apply to the host only: the path keeps its case, so an upper-case path still fails against /shorts.
    @Test func upperCaseInTheHostDoesNotRelaxThePathComparison() {
        #expect(!verdict("https://YOUTUBE.COM/SHORTS"))
        #expect(!verdict("https://YOUTUBE.COM/Shorts"))
        #expect(verdict("https://YOUTUBE.COM/shorts"))
    }

    // DomainNormalizer removes ONE trailing dot; a second dot leaves an empty label, which the normalizer refuses, so there is no match.
    @Test(arguments: ["https://youtube.com../shorts", "https://www.youtube.com../shorts", "https://.youtube.com/shorts", "https://www..youtube.com/shorts", "https://a..youtube.com/shorts"])
    func anEmptyLabelInTheHostGivesNoMatch(url: String) {
        #expect(!verdict(url), "\(url) has an empty label in its host")
    }

    // DomainNormalizer removes only ONE leading www. (02 § DomainNormalizer step 8), and the address host goes through the same normalizer. So a rule typed as
    // www.www.youtube.com/shorts is stored with the domain www.youtube.com. The address with two www. labels normalizes to the same name and matches; the one with
    // a single www. normalizes to youtube.com, which is the parent of the rule's name and does not match. A matcher that strips every leading www. fails the first.
    @Test func onlyOneLeadingWwwIsStrippedSoTheTwoWwwRuleNeedsTheTwoWwwAddress() throws {
        let parts = try PathRuleParser.parse("www.www.youtube.com/shorts")
        #expect(parts.domain == "www.youtube.com", "the rule keeps one www. (DomainNormalizer step 8)")
        let rule = WatchedPathRule(domain: parts.domain, path: parts.path)
        #expect(verdict("https://www.www.youtube.com/shorts", rule))
        #expect(verdict("https://WWW.www.YouTube.com/shorts/abc", rule))
        #expect(verdict("https://a.www.youtube.com/shorts", rule), "a.www.youtube.com is a subdomain of www.youtube.com")
        #expect(verdict("https://www.www.www.youtube.com/shorts", rule), "after one www. is stripped, www.www.youtube.com is under www.youtube.com")
        #expect(!verdict("https://www.youtube.com/shorts", rule), "one www. is stripped, leaving youtube.com, the parent of the rule's name")
        #expect(!verdict("https://youtube.com/shorts", rule))
        #expect(!verdict("https://m.youtube.com/shorts", rule))
    }

    // A rule on a subdomain does not cover its parent site or a sibling, and a name that only ends in the subdomain's text does not match.
    @Test(arguments: [
        "https://youtube.com/shorts",
        "https://www.youtube.com/shorts",
        "https://m.youtube.com/shorts",
        "https://studio.youtube.com/shorts",
        "https://notmusic.youtube.com/shorts",
        "https://music.youtube.com.evil.com/shorts",
        "https://xmusic.youtube.com/shorts",
        "https://music-youtube.com/shorts",
    ])
    func aRuleOnASubdomainDoesNotCoverTheParentOrASibling(url: String) {
        let music = WatchedPathRule(domain: "music.youtube.com", path: "/shorts")
        #expect(!verdict(url, music), "\(url) is not under music.youtube.com")
    }

    // A Unicode host is converted to Punycode (step 3) and compared with a rule stored in Punycode form; the labels' letters are compared after lowercasing.
    // xn--bcher-kva is the RFC 3492 encoding of "bücher" (from Python's punycode codec), so the rule below is what the daemon would store for bücher.de.
    @Test(arguments: [
        ("https://bücher.de/x", true),
        ("https://BÜCHER.DE/x", true),
        ("https://BüCHer.de/x", true),
        ("https://www.bücher.de/x", true),
        ("https://shop.bücher.de/x", true),
        ("https://www.shop.bücher.de/x/y", true),
        ("https://bücher.de./x", true),
        ("https://bücher.de:8443/x/y", true),
        ("https://xn--bcher-kva.de/x", true),
        ("https://XN--BCHER-KVA.DE/x", true),
        ("https://www.xn--bcher-kva.de/x", true),
        ("https://bücher.com/x", false),
        ("https://not-bücher.de/x", false),
        ("https://bücher.de.evil.com/x", false),
        ("https://bucher.de/x", false),
        ("https://xn--bcher-kva.de.evil.com/x", false),
        ("https://xn--mnchen-3ya.de/x", false),
        ("https://münchen.de/x", false),
        ("https://bücher.de/y", false),
        ("https://bücher.de/X", false),
    ])
    func aUnicodeHostIsComparedThroughItsPunycodeForm(url: String, expected: Bool) {
        let rule = WatchedPathRule(domain: "xn--bcher-kva.de", path: "/x")
        #expect(verdict(url, rule) == expected, "\(url) expected \(expected)")
    }

    // More names in other scripts. Each row is a Unicode host and the Punycode domain a rule would hold for it (the Punycode part comes from Python's RFC 3492
    // codec: "straße" -> strae-oqa, "βόλος" -> nxasmm1c, "日本語" -> wgv71a119e, "한국" -> 3e0b707e). The address matches in its Unicode form, with www. or a
    // subdomain in front, and in its Punycode form; the same name under another top-level domain does not.
    @Test(arguments: [
        ("straße.de", "xn--strae-oqa.de", "straße.com"),
        ("βόλος.com", "xn--nxasmm1c.com", "βόλος.org"),
        ("日本語.jp", "xn--wgv71a119e.jp", "日本語.kr"),
        ("한국.kr", "xn--3e0b707e.kr", "한국.jp"),
        ("münchen.de", "xn--mnchen-3ya.de", "münchen.at"),
    ])
    func namesInOtherScriptsMatchThroughTheirPunycodeRule(host: String, punycode: String, otherTld: String) {
        let rule = WatchedPathRule(domain: punycode, path: "/x")
        for url in ["https://\(host)/x", "https://www.\(host)/x/y", "https://sub.\(host):8443/x?q=1", "http://\(punycode)/x", "https://www.\(punycode)./x"] {
            #expect(verdict(url, rule), "\(url) is on \(punycode)")
        }
        for url in ["https://\(otherTld)/x", "https://\(host).evil.com/x", "https://\(host)/y", "https://\(host)/X", "https://x\(punycode)/x"] {
            #expect(!verdict(url, rule), "\(url) is not an /x address on \(punycode)")
        }
    }

    // "ß" is a letter of its own: the Punycode form of "straße" is not the form of "strasse", so the spelled-out name is a different site.
    @Test func eszettAndDoubleSAreDifferentNames() {
        let rule = WatchedPathRule(domain: "xn--strae-oqa.de", path: "/x")
        #expect(verdict("https://straße.de/x", rule))
        #expect(!verdict("https://strasse.de/x", rule))
        #expect(!verdict("https://STRASSE.de/x", rule))
    }

    // Same idea with a second Punycode value (xn--mnchen-3ya for "münchen") and a rule on the Unicode name itself, as PathRuleParser would produce it.
    @Test func aSecondUnicodeNameMatchesThroughItsPunycodeRule() {
        let rule = WatchedPathRule(domain: "xn--mnchen-3ya.de", path: "/a")
        #expect(verdict("https://münchen.de/a", rule))
        #expect(verdict("https://MÜNCHEN.de/a/b", rule))
        #expect(!verdict("https://muenchen.de/a", rule))
        #expect(!verdict("https://bücher.de/a", rule))
    }

    // "an IPv4 address, an IPv6 literal and an empty host do not match." The rule's name never equals an address, so the second block uses rules whose
    // text is the tail of the address (not a shape the daemon stores, but step 3 must still refuse the address because the normalizer refuses it).
    @Test(arguments: [
        "http://1.2.3.4/shorts",
        "http://127.0.0.1/shorts",
        "http://0.0.0.0/shorts",
        "http://1.2.3.4./shorts",
        "http://1.2.3.4:8080/shorts",
        "http://user@1.2.3.4/shorts",
        "http://2130706433/shorts",
        "http://[::1]/shorts",
        "http://[::1]:8080/shorts",
        "http://[2001:db8::1]/shorts",
        "http://[::ffff:1.2.3.4]/shorts",
        "https://[2001:db8::1]:8080/shorts",
    ])
    func ipAddressesNeverMatch(url: String) {
        #expect(!verdict(url), "\(url) is an IP address")
        #expect(!verdict(url, WatchedPathRule(domain: "2.3.4", path: "/shorts")), "\(url) must not match even a rule that ends like the address")
        #expect(!verdict(url, WatchedPathRule(domain: "1.2.3.4", path: "/shorts")), "\(url) must not match a rule written as an address")
        #expect(!verdict(url, WatchedPathRule(domain: "4", path: "/shorts")), "\(url) must not match a one-label rule")
    }

    // These limit rows (here and in the next three tests) duplicate DomainNormalizerTests: the limits are decided by the normalizer and Foundation, not by the
    // matcher. They are kept only as checks that the matcher gives no match for such a host and does not crash.
    // Step 3 sends the host through the same normalizer as the rules, so a host that normalizer refuses (a label with a character outside a-z, 0-9 and -, a
    // label of 64 characters, a whole name over 253 characters) gives no match even when it ends with the rule's site.
    @Test func aHostTheNormalizerRefusesGivesNoMatchEvenUnderTheRulesSite() {
        let label63 = String(repeating: "a", count: 63)
        let label64 = String(repeating: "a", count: 64)
        #expect(verdict("https://\(label63).youtube.com/shorts"), "a 63-character label is allowed")
        #expect(!verdict("https://\(label64).youtube.com/shorts"), "a 64-character label is refused")
        #expect(!verdict("https://a_b.youtube.com/shorts"), "an underscore is outside a-z, 0-9 and -")
        #expect(!verdict("https://-a.youtube.com/shorts"), "a label may not start with a hyphen")
        #expect(!verdict("https://a-.youtube.com/shorts"), "a label may not end with a hyphen")
        #expect(!verdict("https://a*b.youtube.com/shorts"), "an asterisk is outside a-z, 0-9 and -")
        #expect(!verdict("https://a!b.youtube.com/shorts"), "an exclamation mark is outside a-z, 0-9 and -")
    }

    // The whole-name limit of step 9 (1 to 253 characters) applies to the address host: 253 characters (the longest allowed) match, 254 do not.
    // 63 + 1 + 63 + 1 + 63 + 1 + N + ".youtube.com" (12 characters): N = 49 gives 253, N = 50 gives 254.
    @Test func theTwoHundredFiftyThreeCharacterLimitAppliesToTheAddressHost() {
        let l = String(repeating: "a", count: 63)
        let at253 = "\(l).\(l).\(l).\(String(repeating: "b", count: 49)).youtube.com"
        let at254 = "\(l).\(l).\(l).\(String(repeating: "b", count: 50)).youtube.com"
        #expect(at253.count == 253)
        #expect(at254.count == 254)
        #expect(verdict("https://\(at253)/shorts"))
        #expect(!verdict("https://\(at254)/shorts"))
    }

    // The 63-character label limit is measured on the Punycode form ("xn--" plus the encoding), not on the typed letters. Python's RFC 3492 codec gives
    // 4 + 59 = 63 characters for 57 copies of "ü" and 64 for 58 copies, so the first host is allowed and the second is refused.
    @Test func theLabelLimitIsMeasuredOnThePunycodeForm() {
        #expect(verdict("https://\(String(repeating: "ü", count: 57)).youtube.com/shorts"))
        #expect(verdict("https://www.\(String(repeating: "ü", count: 57)).youtube.com/shorts"))
        #expect(!verdict("https://\(String(repeating: "ü", count: 58)).youtube.com/shorts"))
        #expect(!verdict("https://\(String(repeating: "ü", count: 64)).youtube.com/shorts"))
    }

    // A host far over every limit gives no match and does not crash (a no-crash check; the decision belongs to Foundation and the normalizer, see above).
    @Test func aVeryLongHostGivesNoMatch() {
        #expect(!verdict("https://\(String(repeating: "ü", count: 5_000)).youtube.com/shorts"))
        #expect(!verdict("https://\(String(repeating: "ü", count: 200_000))/shorts"))
        #expect(!verdict("https://\(String(repeating: "a", count: 100_000)).youtube.com/shorts"))
        #expect(!verdict("https://\(String(repeating: "a.", count: 50_000))youtube.com/shorts"))
    }

    // Percent-escapes in the host that turn into a character that ends or reshapes a host name must not let the address pass as a different site. Each address
    // below decodes (in URLComponents.host) to text that DomainNormalizer alone would cut down to `rule` ("youtube.com%2Fx.evil.com" -> "youtube.com/x.evil.com"
    // -> "youtube.com"), so a naive matcher would match. The last column is the rule whose name the cut-down text would equal.
    @Test(arguments: [
        ("https://youtube.com%2Fx.evil.com/shorts", "youtube.com"),
        ("https://youtube.com%2fx.evil.com/shorts", "youtube.com"),
        ("https://youtube.com%2F/shorts", "youtube.com"),
        ("https://youtube.com%3Fx.evil.com/shorts", "youtube.com"),
        ("https://youtube.com%3fx=1/shorts", "youtube.com"),
        ("https://youtube.com%23x.evil.com/shorts", "youtube.com"),
        ("https://youtube.com%23/shorts", "youtube.com"),
        ("https://youtube.com%40evil.com/shorts", "evil.com"),
        ("https://evil.com%40youtube.com/shorts", "youtube.com"),
        ("https://user%40youtube.com/shorts", "youtube.com"),
        ("https://youtube.com%3A80/shorts", "youtube.com"),
        ("https://youtube.com%3a443/shorts", "youtube.com"),
        ("https://youtube.com%3A/shorts", "youtube.com"),
        ("https://youtube.com%20/shorts", "youtube.com"),
        ("https://youtube.com%20x.evil.com/shorts", "youtube.com"),
        ("https://%20youtube.com/shorts", "youtube.com"),
        ("https://youtube.com%09/shorts", "youtube.com"),
        ("https://youtube.com%0A/shorts", "youtube.com"),
        ("https://youtube.com%0D%0A/shorts", "youtube.com"),
        ("https://youtube.com%00/shorts", "youtube.com"),
        ("https://youtube.com%5C/shorts", "youtube.com"),
        ("https://evil.com%2Fyoutube.com/shorts", "evil.com"),
        ("https://evil.com%3Fyoutube.com/shorts", "evil.com"),
        ("https://evil.com%23youtube.com/shorts", "evil.com"),
        ("https://evil.com%20youtube.com/shorts", "evil.com"),
    ])
    func aPercentEscapedSeparatorInTheHostNeverMatchesTheSiteBeforeIt(url: String, ruleDomain: String) {
        let rule = WatchedPathRule(domain: ruleDomain, path: "/shorts")
        #expect(!verdict(url, rule), "\(url) must not be judged as \(ruleDomain)")
        #expect(!verdict(url, shorts), "\(url) must not be judged as youtube.com")
        // Control: the plain address of that site does match, so the line above is not true for every input.
        #expect(verdict("https://\(ruleDomain)/shorts", rule))
    }

    // Invisible and non-breaking spaces escaped into the host: the design's DomainNormalizer says whitespace, control and invisible characters (zero-width
    // included) are invalid in a name, so the address is refused rather than trimmed down to youtube.com.
    @Test(arguments: [
        "https://youtube.com%E2%80%8B/shorts",
        "https://%E2%80%8Byoutube.com/shorts",
        "https://you%E2%80%8Btube.com/shorts",
        "https://youtube.com%C2%A0/shorts",
        "https://%C2%A0youtube.com/shorts",
        "https://youtube.com%E3%80%80/shorts",
        "https://youtube.com%E2%80%A8/shorts",
        "https://youtube.com%C2%85/shorts",
        "https://youtube.com%EF%BB%BF/shorts",
    ])
    func invisibleAndNonBreakingCharactersInTheHostGiveNoMatch(url: String) {
        #expect(!verdict(url), "\(url) has an invisible or whitespace character in its host")
    }

}

// MARK: - port and user info (step 6)

@Suite struct TabRuleMatcherPortAndUserInfoTests {
    // "The port ... play no part in the decision."
    @Test(arguments: [
        "https://youtube.com:443/shorts",
        "http://youtube.com:80/shorts",
        "https://youtube.com:8443/shorts/abc",
        "https://www.youtube.com:8080/shorts",
        "https://m.youtube.com:65535/shorts",
        "https://youtube.com:1/shorts",
        "https://youtube.com:0/shorts",
        "https://youtube.com:/shorts",
        "https://YOUTUBE.com.:8443/shorts",
    ])
    func aPortNumberIsIgnored(url: String) {
        #expect(verdict(url), "\(url) is on youtube.com")
    }

    // A port does not rescue a wrong host or a wrong path, and a port with no path is the empty path.
    @Test(arguments: [
        "https://notyoutube.com:443/shorts",
        "https://youtube.com.evil.com:443/shorts",
        "https://youtube.co:8080/shorts",
        "https://youtube.com:443/watch",
        "https://youtube.com:443",
        "https://youtube.com:443/",
        "https://youtube.com:443?x=/shorts",
        "https://youtube.com:443#/shorts",
        "https://evil.com:443/youtube.com/shorts",
    ])
    func aPortDoesNotChangeTheOtherChecks(url: String) {
        #expect(!verdict(url), "\(url) is not a youtube.com/shorts address")
    }

    // "user info is ignored": an address with credentials in front of the host is judged by the host that follows them.
    @Test(arguments: [
        "https://user:pw@youtube.com/shorts",
        "https://user@youtube.com/shorts",
        "https://user:@youtube.com/shorts",
        "https://:pw@youtube.com/shorts",
        "https://evil.com@youtube.com/shorts",
        "https://evil.com:pw@youtube.com/shorts",
        "https://evil.com:443@youtube.com:8443/shorts",
        "https://user:pw@www.youtube.com:443/shorts/abc?x=1#t",
        "https://u%40v@youtube.com/shorts",
    ])
    func userInfoIsIgnoredWhenTheHostIsTheRulesSite(url: String) {
        #expect(verdict(url), "\(url) is on youtube.com")
    }

    // "https://youtube.com@other.com/shorts must be judged by other.com": with the rule on youtube.com it does not match, with a rule on other.com it does.
    @Test(arguments: [
        "https://youtube.com@other.com/shorts",
        "https://www.youtube.com@other.com/shorts",
        "https://youtube.com:pw@other.com/shorts",
        "https://youtube.com:443@other.com:8443/shorts",
        "https://youtube.com%40other.com@other.com/shorts",
        "https://a%40youtube.com@other.com/shorts",
    ])
    func anAddressWithTheRulesSiteAsUserInfoIsJudgedByItsRealHost(url: String) {
        #expect(!verdict(url, shorts), "\(url) is on other.com, not youtube.com")
        #expect(verdict(url, WatchedPathRule(domain: "other.com", path: "/shorts")), "\(url) is on other.com")
    }

    // NOT decided by the design: two unescaped @ signs in the authority. The expectation here is what Foundation's URLComponents does (it ends the user info at the
    // LAST @, which is also what browsers do), so the host is the text after the last @. Kept as a regression check on the parser, not as a design requirement.
    @Test func aSecondAtSignInTheUserInfoEndsTheUserInfoAtTheLastOne() {
        #expect(verdict("https://u@v@youtube.com/shorts"))
        #expect(!verdict("https://evil@youtube.com@other.com/shorts", shorts))
        #expect(verdict("https://evil@youtube.com@other.com/shorts", WatchedPathRule(domain: "other.com", path: "/shorts")))
    }
}

// MARK: - paths (step 5)

@Suite struct TabRuleMatcherPathTests {
    // "/shorts, /shorts/, /shorts/abc and /shortsXYZ match because the comparison is a plain prefix"; "/short, /watch, /a/shorts and / do not".
    @Test(arguments: [
        ("https://youtube.com/shorts", true),
        ("https://youtube.com/shorts/", true),
        ("https://youtube.com/shorts/abc", true),
        ("https://youtube.com/shorts/abc/def/ghi", true),
        ("https://youtube.com/shortsXYZ", true),
        ("https://youtube.com/shorts.html", true),
        ("https://youtube.com/shorts-and-more", true),
        ("https://youtube.com/shorts_1", true),
        ("https://youtube.com/shorts;jsessionid=1", true),
        ("https://youtube.com/shorts%20", true),
        ("https://youtube.com/shorts%2Fabc", true),
        ("https://youtube.com/shortss", true),
        ("https://youtube.com/short", false),
        ("https://youtube.com/shor", false),
        ("https://youtube.com/s", false),
        ("https://youtube.com/watch", false),
        ("https://youtube.com/watch/shorts", false),
        ("https://youtube.com/a/shorts", false),
        ("https://youtube.com/a/shorts/b", false),
        ("https://youtube.com/", false),
        ("https://youtube.com", false),
        ("https://youtube.com//shorts", false),
        ("https://youtube.com/%73horts", false),
        ("https://youtube.com/short%73", false),
        ("https://youtube.com/hshorts", false),
        ("https://youtube.com/-shorts", false),
        ("https://youtube.com/shirts", false),
    ])
    func thePathIsComparedAsAPlainPrefix(url: String, expected: Bool) {
        #expect(verdict(url) == expected, "\(url) expected \(expected)")
    }

    // "/Shorts does not because the comparison is case-sensitive."
    @Test(arguments: ["/Shorts", "/SHORTS", "/sHorts", "/shortS", "/Shorts/abc", "/SHORTS/"])
    func theCaseOfThePathMustMatchExactly(path: String) {
        #expect(!verdict("https://youtube.com\(path)"), "\(path) differs in case from /shorts")
    }

    // A rule path that has capitals matches only those capitals.
    @Test func aRulePathWithMixedCaseMatchesOnlyThatCase() {
        let rule = WatchedPathRule(domain: "youtube.com", path: "/Shorts")
        #expect(verdict("https://youtube.com/Shorts", rule))
        #expect(verdict("https://youtube.com/Shorts/abc", rule))
        #expect(verdict("https://youtube.com/ShortsXYZ", rule))
        #expect(!verdict("https://youtube.com/shorts", rule))
        #expect(!verdict("https://youtube.com/SHORTS", rule))
        #expect(!verdict("https://youtube.com/sHorts", rule))
        let handle = WatchedPathRule(domain: "youtube.com", path: "/@MrBeast")
        #expect(verdict("https://www.youtube.com/@MrBeast", handle))
        #expect(verdict("https://www.youtube.com/@MrBeast/videos", handle))
        #expect(!verdict("https://www.youtube.com/@mrbeast", handle))
        #expect(!verdict("https://www.youtube.com/@MRBEAST", handle))
    }

    // A rule with several segments: the address must start with all of them, in order, with the same separators.
    @Test(arguments: [
        ("https://reddit.com/r/Python", true),
        ("https://reddit.com/r/Python/", true),
        ("https://reddit.com/r/Python/comments/x", true),
        ("https://reddit.com/r/PythonDev", true),
        ("https://old.reddit.com/r/Python/top", true),
        ("https://reddit.com/r/python", false),
        ("https://reddit.com/r/Pytho", false),
        ("https://reddit.com/r/", false),
        ("https://reddit.com/r", false),
        ("https://reddit.com/R/Python", false),
        ("https://reddit.com/x/r/Python", false),
        ("https://reddit.com//r/Python", false),
        ("https://reddit.com/r//Python", false),
        ("https://reddit.com/r%2FPython", false),
        ("https://reddit.com/user/r/Python", false),
    ])
    func aRuleWithSeveralSegmentsNeedsAllOfThem(url: String, expected: Bool) {
        let rule = WatchedPathRule(domain: "reddit.com", path: "/r/Python")
        #expect(verdict(url, rule) == expected, "\(url) expected \(expected)")
    }

    // "a percent-encoded path is compared in its encoded form": the rule's text and the address's text are compared as written, escapes included.
    @Test(arguments: [
        ("https://youtube.com/a%20b", true),
        ("https://youtube.com/a%20b/c", true),
        ("https://youtube.com/a%20bc", true),
        ("https://youtube.com/a%20", false),
        ("https://youtube.com/a%20B", false),
        ("https://youtube.com/a+b", false),
        ("https://youtube.com/a%2520b", false),
        ("https://youtube.com/a-b", false),
        ("https://youtube.com/a", false),
        ("https://youtube.com/ab", false),
    ])
    func anEncodedRulePathIsComparedInEncodedForm(url: String, expected: Bool) {
        let rule = WatchedPathRule(domain: "youtube.com", path: "/a%20b")
        #expect(verdict(url, rule) == expected, "\(url) expected \(expected)")
    }

    // An encoded slash is not a slash: a rule written with a real slash does not match an address that has %2F, and a rule written with %2F matches only %2F.
    @Test func anEncodedSlashIsNotASlash() {
        let plain = WatchedPathRule(domain: "youtube.com", path: "/a/b")
        let encoded = WatchedPathRule(domain: "youtube.com", path: "/a%2Fb")
        #expect(verdict("https://youtube.com/a/b", plain))
        #expect(verdict("https://youtube.com/a/b/c", plain))
        #expect(!verdict("https://youtube.com/a%2Fb", plain))
        #expect(verdict("https://youtube.com/a%2Fb", encoded))
        #expect(verdict("https://youtube.com/a%2Fb/c", encoded))
        #expect(!verdict("https://youtube.com/a/b", encoded))
    }

    // Letters written as escapes are not decoded for the comparison: the rule /shorts does not match /%73horts, and a rule written with the escape matches only that.
    @Test func aLetterWrittenAsAnEscapeIsNotTheLetter() {
        let escaped = WatchedPathRule(domain: "youtube.com", path: "/%73horts")
        #expect(verdict("https://youtube.com/%73horts", escaped))
        #expect(verdict("https://youtube.com/%73horts/x", escaped))
        #expect(!verdict("https://youtube.com/shorts", escaped))
    }

    // Non-ASCII letters reach the matcher as escapes; a rule written with the same escapes matches an address written with them and extended further.
    @Test func escapedNonAsciiBytesInThePathAreComparedAsWritten() {
        let rule = WatchedPathRule(domain: "youtube.com", path: "/%E6%97%A5")
        #expect(verdict("https://youtube.com/%E6%97%A5%E6%9C%AC", rule))
        #expect(verdict("https://youtube.com/%E6%97%A5", rule))
        #expect(!verdict("https://youtube.com/%E6%97", rule))
        #expect(!verdict("https://youtube.com/%E6%9C%AC", rule))
    }

    // Every punctuation character a rule path may contain (PathRuleParser allows - . _ ~ / % ! $ & ' ( ) + , ; = : @) is compared literally.
    @Test func everyAllowedPunctuationCharacterIsComparedLiterally() {
        let path = "/a-b.c_d~e!f$g&h'i(j)k+l,m;n=o:p@q"
        let rule = WatchedPathRule(domain: "youtube.com", path: path)
        #expect(verdict("https://youtube.com\(path)", rule))
        #expect(verdict("https://youtube.com\(path)/more?x=1", rule))
        #expect(!verdict("https://youtube.com/a-b.c_d~e!f$g&h'i(j)k+l,m;n=o:p@", rule))
        #expect(!verdict("https://youtube.com/a-b.c_d~e!f$g&h'i(j)k+l,m;n=o:p", rule))
        #expect(!verdict("https://youtube.com/a-b.c_d~e!f$g&h'i(j)k+l,m;n=o:p@Q", rule))
    }

    // A rule path of one character after the slash and one that is a prefix of a longer segment behave like any other prefix.
    @Test func shortRulePathsArePlainPrefixesToo() {
        let one = WatchedPathRule(domain: "youtube.com", path: "/s")
        #expect(verdict("https://youtube.com/s", one))
        #expect(verdict("https://youtube.com/shorts", one))
        #expect(verdict("https://youtube.com/s/x", one))
        #expect(!verdict("https://youtube.com/", one))
        #expect(!verdict("https://youtube.com/a", one))
        #expect(!verdict("https://youtube.com/S", one))
    }

    // NOT decided by the design: whether a combining mark parses depends on Foundation's URLComponents (on this macOS it escapes the mark as %CC%81), so the first
    // expectation follows the parser; only the escaped form is a design-level fact (a plain prefix of an encoded path).
    // A combining mark right after the last letter of the rule's path does not hide the match: the comparison is on the text as written (plain prefix), not on
    // grapheme clusters (where "s" + U+0301 is one character different from "s"). The mark is escaped by URLComponents or kept; either way "/shorts" is a prefix,
    // as long as the text parses at all (step 1), so the expectation follows what URLComponents does with the text and nothing else.
    @Test func aCombiningMarkAfterTheLastLetterDoesNotHideThePrefix() {
        for url in ["https://youtube.com/shorts\u{301}", "https://youtube.com/shorts\u{301}/abc", "https://youtube.com/shorts%CC%81"] {
            let parses = URLComponents(string: url) != nil
            #expect(verdict(url) == parses, "\(url.debugDescription) parses=\(parses)")
        }
        #expect(verdict("https://youtube.com/shorts%CC%81"), "the escaped form always parses and starts with /shorts")
    }
}

// MARK: - query and fragment (step 6)

@Suite struct TabRuleMatcherQueryAndFragmentTests {
    // "/shorts?x=1#t matches; /?next=/shorts and /#/shorts do not": only the path is looked at, so text after ? or # is never part of it.
    @Test(arguments: [
        ("https://youtube.com/shorts?x=1#t", true),
        ("https://youtube.com/shorts?x=1", true),
        ("https://youtube.com/shorts#t", true),
        ("https://youtube.com/shorts?", true),
        ("https://youtube.com/shorts#", true),
        ("https://youtube.com/shorts?#", true),
        ("https://youtube.com/shorts/?x=/a", true),
        ("https://youtube.com/shorts?x=1&y=/watch", true),
        ("https://youtube.com/shorts/abc?feature=share#t=10", true),
        ("https://youtube.com/?next=/shorts", false),
        ("https://youtube.com/#/shorts", false),
        ("https://youtube.com?x=/shorts", false),
        ("https://youtube.com#/shorts", false),
        ("https://youtube.com/?x=/shorts#/shorts", false),
        ("https://youtube.com/watch?v=/shorts", false),
        ("https://youtube.com/watch?next=https://youtube.com/shorts", false),
        ("https://youtube.com/watch?u=https%3A%2F%2Fyoutube.com%2Fshorts", false),
        ("https://youtube.com/watch#shorts", false),
        ("https://youtube.com/watch#/shorts/abc", false),
        ("https://youtube.com/watch?v=1#/shorts/x", false),
        ("https://youtube.com/a?b=c#/shorts", false),
        ("https://youtube.com/short?s", false),
        ("https://youtube.com/short#s", false),
        ("https://youtube.com/short?s=horts", false),
        ("https://youtube.com/short/?shorts", false),
        ("https://www.youtube.com/results?search_query=youtube.com/shorts", false),
    ])
    func onlyThePathDecidesAndQueryAndFragmentAreIgnored(url: String, expected: Bool) {
        #expect(verdict(url) == expected, "\(url) expected \(expected)")
    }

    // A question mark or hash in the host part also ends the host: the text after it is query or fragment, never host or path.
    @Test(arguments: [
        "https://evil.com?.youtube.com/shorts",
        "https://evil.com#.youtube.com/shorts",
        "https://evil.com?youtube.com",
        "https://evil.com/?youtube.com/shorts",
    ])
    func textAfterAQuestionMarkOrHashIsNeverTheHost(url: String) {
        #expect(!verdict(url), "\(url) is on evil.com")
    }
}

// MARK: - unparseable text (step 1)

@Suite struct TabRuleMatcherUnparseableTextTests {
    // "an empty string, text with spaces and a malformed address give no match and do not crash."
    @Test(arguments: [
        "",
        " ",
        "   ",
        "\n",
        "\t",
        " \n\t ",
        "not a url",
        "hello world",
        "youtube.com/shorts with spaces",
        "https youtube.com shorts",
        " https://youtube.com/shorts",
        "\nhttps://youtube.com/shorts",
        "\thttps://youtube.com/shorts",
        "https://you tube.com/shorts",
        "https://youtube.com /shorts",
        "https:// youtube.com/shorts",
        "https://youtube.com\\shorts",
        "https:\\\\youtube.com\\shorts",
        "https//youtube.com/shorts",
        "https:/",
        "://",
        "?",
        "#",
        "/",
        "%",
        "%%%",
        "::::",
        "[[[",
        "https://[",
        "https://]",
        "https://[youtube.com]/shorts",
        "\0",
        "https://youtube.com/\0shorts",
        "😀",
        "https://😀/shorts",
    ])
    func textThatIsNotAnAddressGivesNoMatch(url: String) {
        #expect(!verdict(url), "\(url.debugDescription) is not an address on youtube.com/shorts")
    }

    // 02 § 3b step 5 and 05 (Unparseable text): URLComponents percent-encodes a raw space or control character in the PATH, so the address is compared as
    // /shorts%20abc (a prefix match) and matches; browsers always report such an address already encoded. Only the part after the rule's path is encoded here,
    // so each of these starts with /shorts once encoded.
    @Test(arguments: [
        "https://youtube.com/shorts abc",
        "https://youtube.com/shorts ",
        "https://youtube.com/shorts  two",
        "https://youtube.com/shorts\n",
        "https://youtube.com/shorts\r\n",
        "https://youtube.com/shorts\tx",
        "https://youtube.com/shorts\u{1}",
        "https://youtube.com/shorts\u{0}",
        "https://youtube.com/shorts\u{7F}",
        "https://youtube.com/shorts/ab c?x=1",
        "https://www.youtube.com:8443/shorts a#frag",
        "https://user@m.youtube.com/shorts a b c",
    ])
    func aRawSpaceOrControlCharacterAfterTheRulePathIsEncodedAndStillMatches(url: String) {
        #expect(verdict(url), "\(url.debugDescription) is compared as /shorts%.. and starts with /shorts")
    }

    // The same encoding applies before the end of the rule's path: a raw space inside the part that must match is compared as %20, so it can equal a rule written
    // with %20 and can never equal a rule written with the space (rule paths cannot hold one) or the plus sign.
    @Test func aRawSpaceInsideTheRulePathIsComparedInItsEncodedForm() {
        let encoded = WatchedPathRule(domain: "youtube.com", path: "/a%20b")
        #expect(verdict("https://youtube.com/a b", encoded))
        #expect(verdict("https://youtube.com/a b/c", encoded))
        #expect(verdict("https://youtube.com/a%20b", encoded))
        #expect(!verdict("https://youtube.com/a  b", encoded), "two spaces are %20%20")
        #expect(!verdict("https://youtube.com/a+b", encoded))
        #expect(!verdict("https://youtube.com/a%2520b", encoded))
        // A raw space that cuts the rule's path short leaves a path that is not a prefix match.
        #expect(!verdict("https://youtube.com/short s"))
        #expect(!verdict("https://youtube.com/sh orts"))
        #expect(!verdict("https://youtube.com/ shorts"))
        #expect(!verdict("https://youtube.com/s horts/abc"))
    }

    // 05: "a host with a space in it" gives no match. Raw, at either end of the host, in the middle, or escaped as %20; the space is part of the host, not of the
    // path, even when the path would match.
    @Test(arguments: [
        "https://you tube.com/shorts",
        "https://youtube.com /shorts",
        "https:// youtube.com/shorts",
        "https://youtube .com/shorts",
        "https://www. youtube.com/shorts",
        "https://m.you tube.com/shorts",
        "https://youtube.com%20/shorts",
        "https://%20youtube.com/shorts",
        "https://you%20tube.com/shorts",
    ])
    func aHostWithASpaceInItGivesNoMatch(url: String) {
        #expect(!verdict(url), "\(url) has a space in its host")
    }

    // NOT stated by the design: a space (or newline or tab) in front of the whole address. The expectation follows Foundation's URLComponents, which refuses such
    // text (so the address has no scheme and gives no match) and was kept as no-match by the design owner's decision; it is a regression check on the parser.
    // The same text without the space matches (control).
    @Test(arguments: [" https://youtube.com/shorts", "  https://youtube.com/shorts", "\nhttps://youtube.com/shorts", "\thttps://youtube.com/shorts", " HTTPS://youtube.com/shorts/abc"])
    func aSpaceInFrontOfTheWholeAddressGivesNoMatch(url: String) {
        #expect(!verdict(url), "\(url.debugDescription) does not start with its scheme")
        #expect(verdict(url.trimmingCharacters(in: .whitespacesAndNewlines)), "the same address without the leading space must match")
    }

    // A single call never crashes on awkward bytes: lone surrogates cannot be built in Swift, but NUL, controls, very long runs and mixed scripts can.
    @Test func awkwardInputNeverCrashesAndNeverMatches() {
        let junk = [
            String(repeating: "%", count: 10_000),
            String(repeating: "https://", count: 1_000),
            String(repeating: "/shorts", count: 1_000),
            "https://" + String(repeating: "@", count: 5_000),
            "https://" + String(repeating: ":", count: 5_000),
            "https://" + String(repeating: ".", count: 5_000),
            "https://" + String(repeating: "[", count: 5_000),
            "https://" + String(repeating: "\u{0}", count: 100),
            "https://" + String(repeating: "\u{1F600}", count: 500) + "/shorts",
            "\u{202E}https://youtube.com/shorts",
        ]
        for text in junk {
            #expect(TabRuleMatcher.matchingRule(url: text, rules: [shorts]) == nil, "\(text.prefix(40).debugDescription)... must not match")
            #expect(!TabRuleMatcher.matches(url: text, rule: shorts))
        }
    }
}

// MARK: - very long addresses

@Suite struct TabRuleMatcherLongAddressTests {
    // A very long path or query is just text: the decision still follows the prefix and the ?/# cut. (No timing claim is made.)
    @Test func veryLongPathsAndQueriesFollowTheSameRules() {
        let filler = String(repeating: "a", count: 200_000)
        #expect(verdict("https://youtube.com/shorts/\(filler)"))
        #expect(verdict("https://youtube.com/shorts\(filler)?x=1"))
        #expect(verdict("https://youtube.com/shorts?q=\(filler)"))
        #expect(!verdict("https://youtube.com/\(filler)/shorts"))
        #expect(!verdict("https://youtube.com/watch?q=\(filler)/shorts"))
        #expect(!verdict("https://youtube.com/?q=\(filler)#/shorts"))
        #expect(!verdict("https://\(filler).com/shorts"))
    }

    // Many path segments: the prefix test is on the whole text, not on a segment count.
    @Test func manySegmentsBeforeOrAfterTheRulePathDecideTheSame() {
        let deep = String(repeating: "/seg", count: 5_000)
        #expect(verdict("https://youtube.com/shorts\(deep)"))
        #expect(!verdict("https://youtube.com\(deep)/shorts"))
    }
}

// MARK: - matchingRule (list order)

@Suite struct TabRuleMatcherMatchingRuleTests {
    private let broad = WatchedPathRule(domain: "youtube.com", path: "/shorts")
    private let narrow = WatchedPathRule(domain: "youtube.com", path: "/shorts/abc")
    private let reddit = WatchedPathRule(domain: "reddit.com", path: "/r/Python")
    private let music = WatchedPathRule(domain: "music.youtube.com", path: "/shorts")

    // "the first matching rule in list order is returned when several match": swapping the list order swaps the answer.
    @Test func theFirstMatchingRuleInListOrderIsReturned() {
        let url = "https://www.youtube.com/shorts/abc?x=1"
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [broad, narrow]) == broad)
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [narrow, broad]) == narrow)
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [reddit, narrow, broad]) == narrow)
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [reddit, broad, narrow, music]) == broad)
    }

    // Two rules whose sites overlap (a site and one of its subdomains): the earlier one wins in either order.
    @Test func overlappingSitesAnswerWithTheEarlierRule() {
        let url = "https://music.youtube.com/shorts/x"
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [music, broad]) == music)
        #expect(TabRuleMatcher.matchingRule(url: url, rules: [broad, music]) == broad)
    }

    // "nil comes back for an empty list and when none match".
    @Test func nilComesBackForAnEmptyListAndWhenNoRuleMatches() {
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/shorts", rules: []) == nil)
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/watch", rules: [broad, narrow, reddit]) == nil)
        #expect(TabRuleMatcher.matchingRule(url: "https://example.com/shorts", rules: [broad, narrow, reddit, music]) == nil)
        #expect(TabRuleMatcher.matchingRule(url: "", rules: [broad]) == nil)
        #expect(TabRuleMatcher.matchingRule(url: "", rules: []) == nil)
    }

    // "a rule for a different domain later in the list is found."
    @Test func aRuleForADifferentDomainLaterInTheListIsFound() {
        #expect(TabRuleMatcher.matchingRule(url: "https://old.reddit.com/r/Python/top", rules: [broad, narrow, music, reddit]) == reddit)
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/shorts/abc", rules: [reddit, music, broad]) == broad)
    }

    // An address that is not a web address matches no rule, however many rules there are.
    @Test func aNonWebAddressMatchesNoRuleInAnyList() {
        for url in ["chrome://newtab/", "about:blank", "file:///shorts", "ftp://youtube.com/shorts", "", "garbage"] {
            #expect(TabRuleMatcher.matchingRule(url: url, rules: [broad, narrow, reddit, music]) == nil, "\(url)")
        }
    }

    // The returned rule carries its own domain and path, not those of another rule in the list.
    @Test func theReturnedRuleHasTheMatchingRulesOwnParts() throws {
        let found = try #require(TabRuleMatcher.matchingRule(url: "https://m.reddit.com/r/Python", rules: [broad, reddit, narrow]))
        #expect(found.domain == "reddit.com")
        #expect(found.path == "/r/Python")
    }

    // A long list: the match is found at the first position, in the middle, at the very end, and not at all.
    @Test func aLongListIsSearchedInOrderToTheEnd() {
        var rules = (0..<999).map { WatchedPathRule(domain: "site\($0).example", path: "/p\($0)") }
        rules.append(broad)
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/shorts", rules: rules) == broad)
        #expect(TabRuleMatcher.matchingRule(url: "https://site0.example/p0/a", rules: rules) == rules[0])
        #expect(TabRuleMatcher.matchingRule(url: "https://www.site500.example/p500", rules: rules) == rules[500])
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/watch", rules: rules) == nil)
    }

    // A rule that does not match must not hide a later one that does, and rules on the same site with different paths are told apart.
    @Test func rulesOnTheSameSiteAreToldApartByPath() {
        let watch = WatchedPathRule(domain: "youtube.com", path: "/watch")
        let feed = WatchedPathRule(domain: "youtube.com", path: "/feed")
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/watch?v=1", rules: [feed, broad, watch]) == watch)
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/feed/subscriptions", rules: [watch, broad, feed]) == feed)
        #expect(TabRuleMatcher.matchingRule(url: "https://youtube.com/", rules: [watch, broad, feed]) == nil)
    }
}

// MARK: - rules built the way the daemon builds them

@Suite struct TabRuleMatcherWithParsedRulesTests {
    // Typed rule text goes through PathRuleParser.parse (domain normalized, www. stripped, path keeps its case, trailing * and / removed), then the matcher compares
    // addresses with it. Rows: typed text, addresses that must match, addresses that must not.
    @Test(arguments: [
        ("youtube.com/shorts", ["https://youtube.com/shorts", "https://www.youtube.com/shorts/abc", "https://m.youtube.com/shortsXYZ"], ["https://youtube.com/Shorts", "https://youtube.com/watch", "https://notyoutube.com/shorts"]),
        ("https://www.youtube.com/shorts/?x=1#t", ["https://youtube.com/shorts", "https://youtube.com/shorts/", "https://youtube.com/shorts/abc"], ["https://youtube.com/", "https://youtube.com/?next=/shorts"]),
        ("youtube.com/shorts*", ["https://youtube.com/shorts", "https://youtube.com/shortsXYZ"], ["https://youtube.com/short"]),
        ("youtube.com/shorts/*", ["https://youtube.com/shorts", "https://youtube.com/shorts/x"], ["https://youtube.com/short"]),
        ("YOUTUBE.COM/Shorts", ["https://youtube.com/Shorts", "https://WWW.YOUTUBE.COM/Shorts/x"], ["https://youtube.com/shorts"]),
        ("bücher.de/x", ["https://bücher.de/x", "https://www.bücher.de/x/y", "https://xn--bcher-kva.de/x"], ["https://bucher.de/x", "https://bücher.de/y"]),
        ("www.reddit.com/r/Python/", ["https://old.reddit.com/r/Python", "https://reddit.com/r/Python/top"], ["https://reddit.com/r/python", "https://reddit.com/r"]),
        ("https://www.youtube.com/@MrBeast?x=1", ["https://youtube.com/@MrBeast", "https://www.youtube.com/@MrBeast/videos"], ["https://youtube.com/@mrbeast"]),
    ])
    func aRuleBuiltByThePathRuleParserMatchesAsDescribed(typed: String, matching: [String], notMatching: [String]) throws {
        let parts = try PathRuleParser.parse(typed)
        let rule = WatchedPathRule(domain: parts.domain, path: parts.path)
        for url in matching { #expect(verdict(url, rule), "rule from \(typed.debugDescription) must match \(url)") }
        for url in notMatching { #expect(!verdict(url, rule), "rule from \(typed.debugDescription) must not match \(url)") }
    }
}

// MARK: - generated combinations

private extension Array {
    // This array, or the fallback when this one is empty.
    func nonEmpty(or fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

@Suite struct TabRuleMatcherGeneratedTests {
    // Every part of an address has a known effect on every rule of a small pool: the scheme must be http or https (not httpx, ftp, ...); the host must be the rule's
    // site or a subdomain of it (case, a trailing dot, a leading www. and a Unicode spelling do not matter, a look-alike or a host holding a percent-escaped
    // separator does not count); the path must start with the rule's path; port, user info, query and fragment do not matter. So for any address built from those
    // parts, and any list of rules, the answer is known from the design before the address is built: the FIRST rule of the list for which scheme, host and path
    // all say yes, or nil. Each part's per-rule verdict is written out by hand below; none is computed by the matcher.
    @Test func theFirstRuleWhoseThreePartsAllMatchIsTheAnswerForAnyCombination() {
        // The pool. Rules 0, 3 and 4 share the domain youtube.com; rule 2 is on its subdomain; rule 1 is a Punycode domain (bücher.de).
        let pool = [
            WatchedPathRule(domain: "youtube.com", path: "/shorts"), WatchedPathRule(domain: "xn--bcher-kva.de", path: "/x"), WatchedPathRule(domain: "music.youtube.com", path: "/Charts"),
            WatchedPathRule(domain: "youtube.com", path: "/watch"), WatchedPathRule(domain: "youtube.com", path: "/sh"),
        ]
        // Which rules a host falls under: youtube.com and every subdomain of it fall under 0, 3 and 4; music.youtube.com and its subdomains also under 2.
        let yt: Set<Int> = [0, 3, 4], music: Set<Int> = [0, 2, 3, 4], buecher: Set<Int> = [1], none: Set<Int> = []
        let schemes: [(text: String, ok: Bool)] = [
            ("https", true), ("http", true), ("HTTPS", true), ("hTtp", true),
            ("httpx", false), ("xhttp", false), ("http+x", false), ("htt", false), ("ftp", false), ("file", false), ("wss", false), ("chrome", false),
        ]
        let users = ["", "bob@", "bob:pw@", "youtube.com@", "evil.com:pw@", "www.youtube.com:443@"]
        let hosts: [(text: String, rules: Set<Int>)] = [
            ("youtube.com", yt), ("www.youtube.com", yt), ("m.youtube.com", yt), ("www.m.youtube.com", yt), ("a.b.c.youtube.com", yt), ("YOUTUBE.COM", yt), ("YouTube.Com", yt),
            ("youtube.com.", yt), ("www.youtube.com.", yt), ("M.YouTube.com.", yt), ("www.www.youtube.com", yt),
            ("music.youtube.com", music), ("www.music.youtube.com", music), ("a.MUSIC.youtube.com", music), ("music.youtube.com.", music),
            ("bücher.de", buecher), ("www.BÜCHER.de", buecher), ("xn--bcher-kva.de", buecher), ("XN--BCHER-KVA.de", buecher), ("shop.bücher.de", buecher), ("bücher.de.", buecher),
            ("notyoutube.com", none), ("youtube.com.evil.com", none), ("youtube.co", none), ("xyoutube.com", none), ("youtube.com-evil.com", none), ("wwwyoutube.com", none),
            ("youtube.org", none), ("evil.com", none), ("com", none), ("youtube", none), ("my-youtube.com", none), ("xmusic.youtube.com.evil.com", none), ("music-youtube.com", none),
            ("1.2.3.4", none), ("[::1]", none), ("localhost", none), ("youtube.com..", none), ("a_b.youtube.com", none), ("www.youtube.com.evil.com", none),
            ("bücher.com", none), ("not-bücher.de", none), ("bucher.de", none), ("bücher.de.evil.com", none),
            ("youtube.com%2Fx.evil.com", none), ("youtube.com%2fx.evil.com", none), ("youtube.com%20", none), ("youtube.com%40evil.com", none), ("evil.com%40youtube.com", none),
            ("youtube.com%3A80", none), ("music.youtube.com%2F", none), ("bücher.de%20", none), ("youtube.com%0A", none), ("youtube.com%23x.evil.com", none), ("youtube.com%3Fx.evil.com", none),
        ]
        let ports = ["", ":443", ":8080", ":"]
        // Which rules a path starts with (rule paths: /shorts, /x, /Charts, /watch, /sh): a plain, case-sensitive prefix of the encoded path.
        let paths: [(text: String, rules: Set<Int>)] = [
            ("", []), ("/", []), ("/shorts", [0, 4]), ("/shorts/", [0, 4]), ("/shorts/abc", [0, 4]), ("/shortsXYZ", [0, 4]), ("/shorts%2Fx", [0, 4]), ("/shorts abc", [0, 4]),
            ("/sh", [4]), ("/shirt", [4]), ("/short", [4]), ("/sh orts", [4]), ("/s", []), ("/Shorts", []), ("/SHORTS/abc", []), ("/ shorts", []),
            ("/Charts", [2]), ("/Charts/top", [2]), ("/charts", []), ("/x", [1]), ("/x/y", [1]), ("/xylophone", [1]), ("/X", []),
            ("/watch", [3]), ("/watch/x", [3]), ("/watchlist", [3]), ("/wat", []), ("/a/shorts", []), ("//shorts", []), ("/%73horts", []),
        ]
        let queries = ["", "?x=1", "?next=/shorts", "?", "?/watch"]
        let fragments = ["", "#t", "#/shorts", "#"]

        var generator = MatcherGenerator(state: 0x51_7E_B10C)
        // Takes one random element of an array.
        func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &generator)] }
        var answeredNil = 0, answered = 0, severalMatch = 0, laterRuleWon = 0, emptyLists = 0
        var winners = [Int: Int]()
        var used = (hosts: Set<String>(), paths: Set<String>(), schemes: Set<String>(), users: Set<String>())
        for _ in 0..<12_000 {
            // 0 to 3 distinct rules, in random order.
            let count = [0, 1, 1, 1, 2, 2, 2, 3, 3][Int.random(in: 0..<9, using: &generator)]
            let chosen = Array(Array(0..<pool.count).shuffled(using: &generator).prefix(count))
            // Parts are drawn mostly from the values that fall under at least one chosen rule, so that matches are common; the rest are drawn from everything.
            let favourable = Int.random(in: 0..<100, using: &generator) < 75
            let scheme = favourable ? pick(schemes.filter { $0.ok }) : pick(schemes)
            let user = pick(users)
            let host = Int.random(in: 0..<100, using: &generator) < 75 ? pick(hosts.filter { !$0.rules.isDisjoint(with: chosen) }.nonEmpty(or: hosts)) : pick(hosts)
            let path = Int.random(in: 0..<100, using: &generator) < 75 ? pick(paths.filter { !$0.rules.isDisjoint(with: chosen) }.nonEmpty(or: paths)) : pick(paths)
            let url = "\(scheme.text)://\(user)\(host.text)\(pick(ports))\(path.text)\(pick(queries))\(pick(fragments))"
            let verdicts = chosen.map { scheme.ok && host.rules.contains($0) && path.rules.contains($0) }
            let expected = verdicts.firstIndex(of: true).map { chosen[$0] }
            let actual = TabRuleMatcher.matchingRule(url: url, rules: chosen.map { pool[$0] })
            #expect(actual == expected.map { pool[$0] }, "\(url) with rules \(chosen.map { "\(pool[$0].domain)\(pool[$0].path)" }) expected rule \(String(describing: expected))")
            for (rule, want) in zip(chosen, verdicts) { #expect(TabRuleMatcher.matches(url: url, rule: pool[rule]) == want, "\(url) against \(pool[rule].domain)\(pool[rule].path) expected \(want)") }
            if let expected { answered += 1; winners[expected, default: 0] += 1; if verdicts.filter({ $0 }).count > 1 { severalMatch += 1 }; if verdicts.firstIndex(of: true) != 0 { laterRuleWon += 1 } } else { answeredNil += 1 }
            if chosen.isEmpty { emptyLists += 1 }
            used.hosts.insert(host.text); used.paths.insert(path.text); used.schemes.insert(scheme.text); used.users.insert(user)
        }
        // Guards against a generator that quietly covers little: every value was drawn, both answers happened often, every rule won, and the first-match rule was
        // exercised (several rules matching, and a later rule winning because an earlier one did not match).
        #expect(used.hosts.count == hosts.count)
        #expect(used.paths.count == paths.count)
        #expect(used.schemes.count == schemes.count)
        #expect(used.users.count == users.count)
        #expect(answered > 800, "only \(answered) generated addresses had a matching rule")
        #expect(answeredNil > 800, "only \(answeredNil) generated addresses had no matching rule")
        #expect(severalMatch > 100, "only \(severalMatch) generated lists had two matching rules")
        #expect(laterRuleWon > 100, "only \(laterRuleWon) generated lists were won by a later rule")
        #expect(emptyLists > 200, "only \(emptyLists) generated lists were empty")
        for index in 0..<pool.count { #expect((winners[index] ?? 0) > 60, "rule \(index) won only \(winners[index] ?? 0) times") }
    }
}

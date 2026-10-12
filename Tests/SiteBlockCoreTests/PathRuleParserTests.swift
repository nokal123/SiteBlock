import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § 3a PathRuleParser (split, parse, display, chromeEntry, firefoxPattern) and from
// 01-overview-and-data.md § How Blocking Works ("Blocking part of a site"). Every expected string below is typed from those sections.

@Suite struct PathRuleParserSplitTests {
    // split: "trims the text, drops a scheme://, any user@ part and a :port, cuts at the first ? or #, and returns the host part and the path
    // (everything from the first /)". The host is returned as typed, not lowercased or checked.
    @Test(arguments: [
        ("youtube.com/shorts", "youtube.com", "/shorts"),
        ("https://www.youtube.com/shorts/abc?x=1#frag", "www.youtube.com", "/shorts/abc"),
        ("  youtube.com/shorts \n", "youtube.com", "/shorts"),
        ("HTTPS://WWW.YouTube.COM/Shorts", "WWW.YouTube.COM", "/Shorts"),
        ("user:pw@youtube.com:8443/shorts", "youtube.com", "/shorts"),
        ("youtube.com:8080/a/b", "youtube.com", "/a/b"),
        ("youtube.com/shorts?x=1", "youtube.com", "/shorts"),
        ("youtube.com/shorts#top", "youtube.com", "/shorts"),
        ("youtube.com/shorts/", "youtube.com", "/shorts/"),
        ("youtube.com/shorts*", "youtube.com", "/shorts*"),
        ("youtube.com//shorts", "youtube.com", "//shorts"),
    ])
    func splitReturnsTheHostAndTheCutPath(input: String, host: String, path: String) {
        let parts = PathRuleParser.split(input)
        #expect(parts.host == host)
        #expect(parts.path == path)
    }

    // "The path is nil when there is none, or when it is only / or empty; that means whole site."
    @Test(arguments: ["youtube.com", "youtube.com/", "https://www.youtube.com", "https://www.youtube.com/", "  youtube.com  ", "youtube.com?x=/shorts", "youtube.com#/shorts", "youtube.com/?x=1", "youtube.com/#top", "/", "", "   "])
    func splitGivesNoPathForAWholeSite(input: String) {
        #expect(PathRuleParser.split(input).path == nil, "\(input.debugDescription) must have no path")
    }

    // A lone "/" is the whole site, and what is before it is empty.
    @Test func aLoneSlashHasAnEmptyHostAndNoPath() {
        let parts = PathRuleParser.split("/")
        #expect(parts.host == "")
        #expect(parts.path == nil)
    }

    // An "@" after the first "/" belongs to the path (a YouTube handle), not to a user:password prefix.
    @Test func anAtSignInThePathIsKeptAndDoesNotCutTheHost() {
        let parts = PathRuleParser.split("https://www.youtube.com/@MrBeast")
        #expect(parts.host == "www.youtube.com")
        #expect(parts.path == "/@MrBeast")
    }

    // "://" is a scheme separator only before any "/", "?" or "#", so a link inside a query does not replace the host.
    @Test func aSchemeInsideTheQueryIsNotTheScheme() {
        let parts = PathRuleParser.split("youtube.com/watch?u=http://other.example/x")
        #expect(parts.host == "youtube.com")
        #expect(parts.path == "/watch")
    }

    // Only the first "?" or "#" ends the path: whatever the query or fragment holds, including slashes, is cut off.
    @Test func slashesInTheQueryOrFragmentAreNotPartOfThePath() {
        #expect(PathRuleParser.split("youtube.com/a?b=/c/d").path == "/a")
        #expect(PathRuleParser.split("youtube.com/a#/c/d").path == "/a")
        #expect(PathRuleParser.split("youtube.com/a#b?c").path == "/a")
        #expect(PathRuleParser.split("youtube.com/a?b#c").path == "/a")
    }

    // A Swift Character can glue a combining mark onto "/" and hide it; the split works on scalars like DomainNormalizer, so the slash is still found.
    @Test func aCombiningMarkAfterTheSlashDoesNotHideIt() {
        let parts = PathRuleParser.split("youtube.com/\u{301}shorts")
        #expect(parts.host == "youtube.com")
        #expect(parts.path == "/\u{301}shorts")
    }
}

@Suite struct PathRuleParserParseTests {
    // parse returns (normalized domain, path). Rows: the typed text, the domain and the path the design's rules give.
    @Test(arguments: [
        ("youtube.com/shorts", "youtube.com", "/shorts"),
        ("https://www.youtube.com/shorts/abc?x=1#frag", "youtube.com", "/shorts/abc"),
        ("www.youtube.com/shorts", "youtube.com", "/shorts"),
        ("YOUTUBE.COM/shorts", "youtube.com", "/shorts"),
        ("user:pw@www.youtube.com:443/shorts", "youtube.com", "/shorts"),
        ("youtube.com/watch?v=abc", "youtube.com", "/watch"),
        ("youtube.com/shorts?x=/y", "youtube.com", "/shorts"),
        ("https://www.youtube.com/@MrBeast", "youtube.com", "/@MrBeast"),
        ("reddit.com/r/all", "reddit.com", "/r/all"),
        ("youtube.com//shorts", "youtube.com", "//shorts"),
        ("youtube.com/a%20b", "youtube.com", "/a%20b"),
        ("youtube.com/a-b.c_d~e!f$g&h'i(j)k+l,m;n=o:p@q", "youtube.com", "/a-b.c_d~e!f$g&h'i(j)k+l,m;n=o:p@q"),
    ])
    func parseGivesTheDomainAndThePath(input: String, domain: String, path: String) throws {
        let rule = try PathRuleParser.parse(input)
        #expect(rule.domain == domain)
        #expect(rule.path == path)
    }

    // "keeps its case, because paths are case-sensitive": the host is lowercased, the path is not.
    @Test func uppercaseLettersInThePathAreKeptAndInTheHostAreLowered() throws {
        let rule = try PathRuleParser.parse("YouTube.COM/Shorts/ABC123xyz")
        #expect(rule.domain == "youtube.com")
        #expect(rule.path == "/Shorts/ABC123xyz")
    }

    // "has trailing * characters and then trailing / characters removed (/shorts/ and /shorts* both become /shorts)".
    @Test(arguments: ["youtube.com/shorts/", "youtube.com/shorts*", "youtube.com/shorts/*", "youtube.com/shorts**", "youtube.com/shorts//", "youtube.com/shorts***", "youtube.com/shorts"])
    func trailingStarsAndSlashesAreRemoved(input: String) throws {
        #expect(try PathRuleParser.parse(input).path == "/shorts")
    }

    // Removing the trailing characters takes only the end: a slash or star that is followed by more text stays (a star left in the path is refused below).
    @Test func slashesInTheMiddleOfThePathStay() throws {
        #expect(try PathRuleParser.parse("youtube.com/a/b/c/").path == "/a/b/c")
    }

    // "/shorts*" and "/shorts/" must give the same stored rule, so they are the same rule.
    @Test func differentWaysOfTypingTheSamePathGiveTheSameRule() throws {
        let typed = ["youtube.com/shorts", "youtube.com/shorts/", "youtube.com/shorts*", "https://www.youtube.com/shorts/?feature=share", "WWW.YOUTUBE.COM/shorts#x"]
        let rules = try typed.map { try PathRuleParser.parse($0) }
        for rule in rules { #expect(rule.domain == "youtube.com" && rule.path == "/shorts") }
    }

    // Unicode host names go through DomainNormalizer's Punycode step; a Unicode path is refused (only plain ASCII is allowed).
    @Test func aUnicodeHostBecomesPunycodeAndTheAsciiPathIsKept() throws {
        let rule = try PathRuleParser.parse("https://bücher.de/Pfad")
        #expect(rule.domain == "xn--bcher-kva.de")
        #expect(rule.path == "/Pfad")
    }

    @Test(arguments: ["youtube.com/ü", "youtube.com/日本", "youtube.com/emoji\u{1F600}", "youtube.com/a\u{200B}b", "youtube.com/a\u{00A0}b", "youtube.com/\u{301}x"])
    func nonAsciiCharactersInThePathAreRefused(input: String) {
        #expect(throws: PathRuleError.invalidCharacters) { try PathRuleParser.parse(input) }
    }

    // Spaces and the other characters outside the allowed set: "anything else, including spaces, * in the middle, ", <, >, \, ^, `, {, |, }".
    @Test(arguments: ["youtube.com/my shorts", "youtube.com/a\tb", "youtube.com/a\nb", "youtube.com/a\rb", "youtube.com/sho*rts", "youtube.com/*/shorts", "youtube.com/a\"b", "youtube.com/a<b", "youtube.com/a>b", "youtube.com/a\\b", "youtube.com/a^b", "youtube.com/a`b", "youtube.com/a{b", "youtube.com/a|b", "youtube.com/a}b", "youtube.com/a[b", "youtube.com/a]b", "youtube.com/a\u{0}b"])
    func charactersOutsideTheAllowedSetAreRefused(input: String) {
        #expect(throws: PathRuleError.invalidCharacters) { try PathRuleParser.parse(input) }
    }

    // Surrounding whitespace is trimmed first, so it is not "a space in the path"; a space inside is.
    @Test func surroundingWhitespaceIsTrimmedButInnerWhitespaceIsRefused() throws {
        #expect(try PathRuleParser.parse("  youtube.com/shorts  \n").path == "/shorts")
        #expect(throws: PathRuleError.invalidCharacters) { try PathRuleParser.parse("youtube.com/sho rts") }
    }

    // A site name alone is a whole-site block, not a rule.
    @Test(arguments: ["youtube.com", "youtube.com/", "https://www.youtube.com", "https://www.youtube.com/", "youtube.com?x=/shorts", "youtube.com#/shorts", "youtube.com/?x=1", "youtube.com//", "youtube.com/*", "youtube.com/**", "youtube.com/***"])
    func textWithNoPathIsRefusedAsNoPath(input: String) {
        #expect(throws: PathRuleError.noPath) { try PathRuleParser.parse(input) }
    }

    // A lone "/" has no host, so the site-name problem (empty) is reported before the path problem.
    @Test func aLoneSlashReportsTheEmptyHost() {
        #expect(throws: DomainError.empty) { try PathRuleParser.parse("/") }
    }

    // "normalizes the host with DomainNormalizer.normalize (so every DomainNormalizer error applies)": the host problem wins over a path problem too.
    @Test(arguments: [
        ("1.2.3.4/shorts", DomainError.ipAddress),
        ("1.2.3.4/a b", DomainError.ipAddress),
        ("[::1]/x", DomainError.ipAddress),
        ("localhost/x", DomainError.reserved),
        ("printer.local/x", DomainError.reserved),
        ("reddit/r/all", DomainError.needsDot),
        ("my_site.com/x", DomainError.invalidCharacters),
        ("my site.com/x", DomainError.invalidCharacters),
        ("", DomainError.empty),
        ("   ", DomainError.empty),
        ("https:///shorts", DomainError.empty),
        ("reddit.com:abc/x", DomainError.invalidCharacters),
    ])
    func hostProblemsAreReportedAsDomainErrors(input: String, error: DomainError) {
        #expect(throws: error) { try PathRuleParser.parse(input) }
    }

    // "is at most 256 characters", counting the leading slash. A path of 256 is fine; 257 is too long, whatever the characters are.
    @Test func aPathOf256CharactersIsKeptAndOneOf257IsTooLong() throws {
        let ok = "/" + String(repeating: "a", count: 255)
        #expect(ok.count == 256)
        #expect(try PathRuleParser.parse("youtube.com" + ok).path == ok)
        let tooLong = "/" + String(repeating: "a", count: 256)
        #expect(throws: PathRuleError.tooLong) { try PathRuleParser.parse("youtube.com" + tooLong) }
    }

    // The query is cut before the length is judged, so a long query does not make a short path too long.
    @Test func aLongQueryDoesNotCountTowardTheLength() throws {
        let rule = try PathRuleParser.parse("youtube.com/shorts?" + String(repeating: "x", count: 5000))
        #expect(rule.path == "/shorts")
    }

    // A rule written back as people read it parses to the same rule: display(parse(x)) is a fixed point.
    @Test(arguments: ["youtube.com/shorts", "https://www.YouTube.com/Shorts/?x=1", "bücher.de/Pfad/Datei", "x.com/@name", "reddit.com/r/all/"])
    func theDisplayedRuleParsesBackToTheSameRule(input: String) throws {
        let rule = try PathRuleParser.parse(input)
        let shown = PathRuleParser.display(domain: rule.domain, path: rule.path)
        let again = try PathRuleParser.parse(shown)
        #expect(again.domain == rule.domain && again.path == rule.path)
    }

    // Every error carries a sentence a person can read.
    @Test(arguments: [PathRuleError.noPath, .tooLong, .invalidCharacters])
    func everyPathErrorHasAReadableSentence(error: PathRuleError) {
        #expect(!(error.errorDescription ?? "").isEmpty)
    }
}

@Suite struct PathRuleParserEntryTests {
    // display: "youtube.com/shorts".
    @Test func displayJoinsTheDomainAndThePath() {
        #expect(PathRuleParser.display(domain: "youtube.com", path: "/shorts") == "youtube.com/shorts")
        #expect(PathRuleParser.display(domain: "x.com", path: "/Home/Sub") == "x.com/Home/Sub")
    }

    // chromeEntry: "youtube.com/shorts".
    @Test func theChromeEntryIsTheDomainAndThePath() {
        #expect(PathRuleParser.chromeEntry(domain: "youtube.com", path: "/shorts") == "youtube.com/shorts")
        #expect(PathRuleParser.chromeEntry(domain: "youtube.com", path: "/Shorts") == "youtube.com/Shorts", "the case of the path is kept")
    }

    // firefoxPattern: "*://*.youtube.com/shorts*".
    @Test func theFirefoxPatternMatchesAnySchemeTheDomainAndItsSubdomainsAndAnyPathThatStartsWithThePath() {
        #expect(PathRuleParser.firefoxPattern(domain: "youtube.com", path: "/shorts") == "*://*.youtube.com/shorts*")
        #expect(PathRuleParser.firefoxPattern(domain: "x.com", path: "/a/B") == "*://*.x.com/a/B*")
    }

    // The three outputs for a parsed rule, end to end from typed text.
    @Test func aPastedLinkBecomesTheBrowserEntriesFromTheDesign() throws {
        let rule = try PathRuleParser.parse("https://www.youtube.com/shorts/abc123?feature=share")
        #expect(PathRuleParser.chromeEntry(domain: rule.domain, path: rule.path) == "youtube.com/shorts/abc123")
        #expect(PathRuleParser.firefoxPattern(domain: rule.domain, path: rule.path) == "*://*.youtube.com/shorts/abc123*")
    }
}

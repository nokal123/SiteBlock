import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § DomainNormalizer (steps 1-9 and "Parsing details") and
// 05-testing-and-operations.md § Unit Tests. Where the design is silent the test only asserts a safety
// property (the call throws, or the output is a valid host name), never a value read from the code.

private let label63 = String(repeating: "a", count: 63)
private let label64 = String(repeating: "a", count: 64)
// 63 + 1 + 63 + 1 + 63 + 1 + 61 = 253 characters, the longest name the design allows.
private let name253 = "\(label63).\(label63).\(label63).\(String(repeating: "d", count: 61))"
private let name254 = "\(label63).\(label63).\(label63).\(String(repeating: "d", count: 62))"

// Runs normalize and returns the error it threw as a DomainError, or nil when it returned a value.
private func rejection(_ input: String) -> DomainError? {
    do { _ = try DomainNormalizer.normalize(input); return nil } catch { return error as? DomainError }
}

// True when the string is a host name the design's step 8 would accept, written independently of the implementation.
private func isValidNormalizedHost(_ host: String) -> Bool {
    guard host.count >= 1, host.count <= 253 else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count >= 2 else { return false }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    for label in labels {
        guard label.count >= 1, label.count <= 63 else { return false }
        guard label.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
    }
    if labels.last!.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
    if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }
    return true
}

// A small seeded random generator (SplitMix64) so the property tests below are repeatable.
private struct SeededGenerator: RandomNumberGenerator {
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

@Suite struct DomainNormalizerTests {
    // MARK: accepted inputs

    @Test(arguments: [
        ("reddit.com", "reddit.com"),
        ("REDDIT.COM", "reddit.com"),
        ("Reddit.Com", "reddit.com"),
        ("  reddit.com  ", "reddit.com"),
        ("\t\nreddit.com\n\t", "reddit.com"),
        ("old.reddit.com", "old.reddit.com"),
        ("m.facebook.com", "m.facebook.com"),
        ("a-b.com", "a-b.com"),
        ("a--b.example.org", "a--b.example.org"),
        ("123.com", "123.com"),
        ("1.1.1.1.com", "1.1.1.1.com"),
        ("xn--bcher-kva.de", "xn--bcher-kva.de"),
        ("localhost.com", "localhost.com"),
        ("example.local.com", "example.local.com"),
        ("foo.notlocal", "foo.notlocal"),
        ("bar.mylocalhost", "bar.mylocalhost"),
        ("wwwreddit.com", "wwwreddit.com"),
        ("www2.reddit.com", "www2.reddit.com"),
        ("awww.reddit.com", "awww.reddit.com"),
    ])
    func normalizeAcceptsPlainNamesAndLowercasesThem(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // Step 2: scheme, path, query and fragment are cut away. Step 4: port is dropped.
    @Test(arguments: [
        ("https://reddit.com", "reddit.com"),
        ("http://reddit.com/", "reddit.com"),
        ("https://www.reddit.com/r/swift?x=1#frag", "reddit.com"),
        ("HTTPS://Reddit.COM/Path", "reddit.com"),
        ("ftp://reddit.com", "reddit.com"),
        ("https://reddit.com:8443/x", "reddit.com"),
        ("reddit.com:8080", "reddit.com"),
        ("reddit.com:9", "reddit.com"),
        ("reddit.com:0", "reddit.com"),
        ("reddit.com:9099/x", "reddit.com"),
        ("reddit.com:443/path", "reddit.com"),
        ("reddit.com/r/swift", "reddit.com"),
        ("reddit.com?x=1", "reddit.com"),
        ("reddit.com#top", "reddit.com"),
        ("https://reddit.com?x=y", "reddit.com"),
        ("https://reddit.com#frag", "reddit.com"),
        ("https://sub.reddit.com/a/b/c?d=e&f=g#h", "sub.reddit.com"),
    ])
    func normalizeCutsSchemePortPathQueryAndFragment(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // Step 3: everything up to and including the last "@" is dropped.
    @Test(arguments: [
        ("https://user:pass@reddit.com/", "reddit.com"),
        ("user:pass@reddit.com", "reddit.com"),
        ("user@reddit.com", "reddit.com"),
        ("https://user:pa@ss@reddit.com:8080/p", "reddit.com"),
        ("evil.com@reddit.com", "reddit.com"),
        ("reddit.com@evil.com", "evil.com"),
    ])
    func normalizeDropsUserInfoUpToTheLastAtSign(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // Steps 5 and 7: one trailing dot is removed, one leading "www." is removed, case is folded first.
    @Test(arguments: [
        ("reddit.com.", "reddit.com"),
        ("www.reddit.com", "reddit.com"),
        ("WWW.REDDIT.COM.", "reddit.com"),
        ("WwW.Reddit.com", "reddit.com"),
        ("https://www.reddit.com./x", "reddit.com"),
        ("www.www.reddit.com", "www.reddit.com"),
    ])
    func normalizeRemovesOneTrailingDotAndOneLeadingWww(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // Step 6 with expected values from an independent RFC 3492 codec (Python's punycode codec).
    @Test(arguments: [
        ("bücher.de", "xn--bcher-kva.de"),
        ("BÜCHER.DE", "xn--bcher-kva.de"),
        ("münchen.de", "xn--mnchen-3ya.de"),
        ("www.bücher.de", "xn--bcher-kva.de"),
        ("sub.bücher.de", "sub.xn--bcher-kva.de"),
        ("https://bücher.de/pfad?x=1", "xn--bcher-kva.de"),
        ("bücher.de.", "xn--bcher-kva.de"),
        ("日本語.jp", "xn--wgv71a119e.jp"),
        ("ñ.es", "xn--ida.es"),
        ("example.рф", "example.xn--p1ai"),
        ("😀.com", "xn--e28h.com"),
        ("café.fr", "xn--caf-dma.fr"),
        ("straße.de", "xn--strae-oqa.de"),
    ])
    func normalizeConvertsUnicodeLabelsToPunycode(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // MARK: rejected inputs with a code the design names

    @Test(arguments: ["", " ", "\n", "\t \n  "])
    func normalizeRejectsEmptyAndWhitespaceOnlyInputAsEmpty(input: String) {
        #expect(rejection(input) == .empty)
    }

    @Test(arguments: [
        "1.2.3.4", "127.0.0.1", "0.0.0.0", "999.999.999.999", "1.2.3", "http://192.168.1.1/",
        "192.168.1.1:8080", "https://10.0.0.1:8443/admin?x=1", "foo.123",
    ])
    func normalizeRejectsIPv4AndAllDigitTopLevelLabelsAsIpAddress(input: String) {
        #expect(rejection(input) == .ipAddress)
    }

    // Step 4: input that starts with "[" (after scheme, user info and path are cut) is an IPv6 literal.
    @Test(arguments: ["[::1]", "[2001:db8::1]:8080", "http://[::1]:80/path", "https://[fe80::1]/", "[::1]/x"])
    func normalizeRejectsBracketedIPv6LiteralsAsIpAddress(input: String) {
        #expect(rejection(input) == .ipAddress)
    }

    @Test(arguments: ["reddit", "com", "a", "https://reddit", "reddit:80", "reddit/path"])
    func normalizeRejectsSingleLabelNamesAsNeedsDot(input: String) {
        #expect(rejection(input) == .needsDot)
    }

    @Test(arguments: [
        "printer.local", "PRINTER.LOCAL", "foo.localhost", "a.b.local", "https://mac.local:8080/", "x.localhost.",
        "www.printer.local",
    ])
    func normalizeRejectsLocalNamesAsReserved(input: String) {
        #expect(rejection(input) == .reserved)
    }

    @Test(arguments: [
        "-reddit.com", "reddit-.com", "a.-b.com", "a-.b.com", "my_site.com", "_dmarc.example.com", "my site.com",
        "exa mple.com", "exa\tmple.com", "red$it.com", "red,dit.com", "ex*mple.com", "red!dit.com", "ex\u{7F}ample.com",
        "reddit.com\n127.0.0.1 evil.com", "reddit.com 0.0.0.0 evil.com", "a.b-.com", "reddit.-com",
    ])
    func normalizeRejectsBadLabelCharactersAndHyphensAsInvalidCharacters(input: String) {
        #expect(rejection(input) == .invalidCharacters)
    }

    @Test func normalizeAccepts63CharacterLabelAndRejects64CharacterLabel() throws {
        #expect(try DomainNormalizer.normalize("\(label63).com") == "\(label63).com")
        #expect(try DomainNormalizer.normalize("sub.\(label63).com") == "sub.\(label63).com")
        #expect(rejection("\(label64).com") == .labelTooLong)
        #expect(rejection("sub.\(label64).com") == .labelTooLong)
        #expect(rejection("example.\(label64)") == .labelTooLong)
    }

    @Test func normalizeAccepts253CharacterNameAndRejects254CharacterName() throws {
        #expect(name253.count == 253 && name254.count == 254)
        #expect(try DomainNormalizer.normalize(name253) == name253)
        #expect(rejection(name254) == .tooLong)
    }

    // Steps 5 and 7 run before step 8, so the length limit applies to the name without "www." and without the trailing dot.
    @Test func normalizeAppliesLengthLimitAfterStrippingWwwAndTrailingDot() throws {
        #expect(try DomainNormalizer.normalize("www." + name253) == name253)
        #expect(try DomainNormalizer.normalize(name253 + ".") == name253)
        #expect(rejection("www." + name254) == .tooLong)
    }

    // Step 6 runs before step 8, so the 63-character label limit applies to the xn-- form. Sixty "ü" is 60 characters
    // but encodes to "xn--" + "tda" + 59 "a" (62 characters) = 66 characters.
    @Test func normalizeAppliesLabelLimitToThePunycodeForm() {
        let label = String(repeating: "ü", count: 60)
        #expect(label.count == 60)
        #expect(rejection("\(label).com") == .labelTooLong)
    }

    // Step 7 strips "www." before step 8, so "www.com" is the single label "com".
    @Test func normalizeTreatsWwwComAsTheSingleLabelComAfterStripping() {
        #expect(rejection("www.com") == .needsDot)
    }

    // MARK: rejected, where the design does not fix which code applies

    // Design change: 02-core-components.md § DomainNormalizer, Parsing details, now says "Bare localhost throws .reserved". "localhost"
    // is both a single label (needsDot) and a reserved name, and the design used to leave open which error wins, so this test used to
    // accept either one. The design now names .reserved, so accepting .needsDot would let a wrong error pass.
    @Test(arguments: ["localhost", "LOCALHOST", "Localhost", "localhost.", "http://localhost:3000/app", "www.localhost", "  localhost  "])
    func normalizeRejectsBareLocalhostAsReservedExactly(input: String) {
        #expect(rejection(input) == .reserved)
    }

    // 02-core-components.md § DomainNormalizer, Parsing details: "an empty label (`a..com`) ... throw `.invalidCharacters`". ".reddit.com"
    // has an empty first label, and "reddit.com.." has one empty label left at the end once step 5 has removed ONE trailing dot.
    @Test(arguments: ["a..com", ".reddit.com", "reddit..com", "reddit.com..", "a.b..com", "reddit...com"])
    func normalizeRejectsAnEmptyLabelAsInvalidCharacters(input: String) {
        #expect(rejection(input) == .invalidCharacters, "\(input.debugDescription)")
    }

    // 02-core-components.md § DomainNormalizer, Parsing details: "An empty result after parsing (`https://`, `.`) throws `.empty`." Each of
    // these has nothing left once the scheme, the path, the query, the fragment, the user info or the one trailing dot is cut away.
    @Test(arguments: ["https://", ".", "@", "reddit.com@", "?x=1", "#frag", "http:///path", "https://@", "/path", "user:pass@", "http://?x=1", "https://#top"])
    func normalizeRejectsANameThatIsEmptyAfterParsingAsEmpty(input: String) {
        #expect(rejection(input) == .empty, "\(input.debugDescription)")
    }

    // The design gives no code for these two, so the test only requires a rejection: a lone "www." leaves the single label "www", and
    // two dots leave two empty labels after the one trailing dot is removed.
    @Test(arguments: ["..", "www."])
    func normalizeRejectsTheRemainingDotOnlyInputs(input: String) {
        #expect(rejection(input) != nil)
    }

    // 02-core-components.md steps 6 and 9: four labels of 57 "ü" are 4 * 57 + 3 = 231 scalars, under the 253 limit, and no label has more
    // than 63 scalars, so the size check on the raw scalars passes. Each label then encodes to "xn--" + 59 characters = 63 characters, which
    // is allowed for one label, but the four encoded labels with their three dots are 255 characters, over the whole-name limit of 253,
    // which step 9 checks after the encoding. So the answer is tooLong, not labelTooLong and not an accepted name.
    @Test func fourPunycodeLabelsThatAreEachLegalButTogetherTwoHundredFiftyFiveCharactersAreTooLong() throws {
        let label = String(repeating: "\u{FC}", count: 57)
        let name = [label, label, label, label].joined(separator: ".")
        #expect(name.unicodeScalars.count == 231)
        let encoded = try #require(Punycode.toASCII(label: label))
        #expect(encoded.count == 63, "premise: one encoded label fits in 63 characters")
        #expect(rejection(name) == .tooLong)
        // Three of the same labels are 3 * 63 + 2 = 191 characters and are accepted, so the rejection above is the whole-name limit.
        let three = [label, label, label].joined(separator: ".")
        #expect(try DomainNormalizer.normalize(three) == [encoded, encoded, encoded].joined(separator: "."))
    }

    // 02-core-components.md § DomainNormalizer, Parsing details: "any whitespace, control or invisible character ... throw .invalidCharacters".
    // The C1 control characters U+0080 to U+009F, which include the next-line character U+0085, and the paragraph separator U+2029 are
    // not ASCII, so the Punycode step would turn a label holding one into a perfectly valid "xn--" name if the check did not come first.
    @Test(arguments: ["red\u{85}dit.com", "red\u{80}dit.com", "red\u{9F}dit.com", "red\u{2029}dit.com", "red\u{90}dit.com", "red\u{9B}dit.com", "red\u{1F}dit.com"])
    func normalizeRejectsC1ControlsAndTheParagraphSeparatorAsInvalidCharacters(input: String) {
        #expect(rejection(input) == .invalidCharacters, "\(input.debugDescription)")
    }

    // 02-core-components.md § DomainNormalizer step 4: "Input that starts with `[` is an IPv6 literal and throws `.ipAddress`." Whatever
    // is inside the brackets, even a name or an IPv4 address.
    @Test(arguments: ["[abc]", "[example.com]", "[1.2.3.4]", "[", "[]", "https://[abc]/", "[abc]:80"])
    func normalizeRejectsAnythingStartingWithABracketAsIpAddress(input: String) {
        #expect(rejection(input) == .ipAddress, "\(input.debugDescription)")
    }

    // The design does not define unbracketed IPv6 text; it can never be a valid host name, so it must be rejected.
    @Test(arguments: ["::1", "2001:db8::1", "fe80::1%lo0"])
    func normalizeRejectsUnbracketedIPv6Text(input: String) {
        #expect(rejection(input) != nil)
    }

    // 02-core-components.md § DomainNormalizer, Parsing details: "`://` counts as a scheme separator only when it appears before any
    // `/`, `?` or `#`. So `reddit.com/?next=https://other.com` normalizes to `reddit.com`." This used to be a spec gap (the test was
    // disabled); the behavior matters, because reading the second "://" as the scheme would block other.com instead of reddit.com.
    @Test(arguments: [
        ("reddit.com/?next=https://other.com", "reddit.com"),
        ("reddit.com?next=https://other.com", "reddit.com"),
        ("reddit.com#https://other.com", "reddit.com"),
        ("reddit.com/a://b", "reddit.com"),
        ("https://reddit.com/?next=https://other.com", "reddit.com"),
        ("reddit.com:8080/?u=ftp://other.org", "reddit.com"),
        ("www.reddit.com/redirect?to=http://evil.example/path", "reddit.com"),
    ])
    func normalizeHandlesSchemeSeparatorInsideQuery(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // An "@" that comes after the cut at "/", "?" or "#" belongs to the path, query or fragment, not to user info (step 2 runs before step 3).
    @Test(arguments: [
        ("https://www.youtube.com/@MrBeast", "youtube.com"),
        ("tiktok.com/@user/video/1", "tiktok.com"),
        ("reddit.com?e=a@b.com", "reddit.com"),
        ("reddit.com#@x", "reddit.com"),
        ("https://www.tiktok.com/@user?lang=en", "tiktok.com"),
        ("youtube.com/watch?v=x#t=1@2", "youtube.com"),
        ("reddit.com/a@b/c@d", "reddit.com"),
        ("https://user:pw@reddit.com/@x", "reddit.com"),
        ("user@reddit.com/@x?e=a@b.com#@y", "reddit.com"),
        ("@reddit.com", "reddit.com"),
    ])
    func normalizeIgnoresAnAtSignInThePathQueryOrFragment(input: String, expected: String) throws {
        #expect(try DomainNormalizer.normalize(input) == expected)
    }

    // 02-core-components.md § DomainNormalizer, Parsing details: "any whitespace, control or invisible character (including zero-width
    // characters such as U+200B) throw .invalidCharacters". The code, not just "it throws", is the design's promise.
    @Test(arguments: ["red\u{200B}dit.com", "red\u{200D}dit.com", "red\u{2060}dit.com", "red\u{FEFF}dit.com", "red\u{00AD}dit.com", "red\u{200E}dit.com", "red\u{0}dit.com", "red\u{7F}dit.com", "red\u{A0}dit.com", "red\u{2028}dit.com", "red dit.com", "red\tdit.com", "red\u{3000}dit.com"])
    func normalizeRejectsWhitespaceControlAndInvisibleCharactersAsInvalidCharacters(input: String) {
        #expect(rejection(input) == .invalidCharacters, "\(input.debugDescription)")
    }

    // Step 1 trims "surrounding whitespace and newlines", and Foundation counts U+200B as whitespace, so a zero-width space at the very
    // edge of the input is trimmed away and "reddit.com" comes out. Whether an edge zero-width space should be trimmed or rejected is
    // not stated: the "invisible character" rule is written for characters inside the name.
    @Test(.disabled("spec gap: 02-core-components.md § DomainNormalizer does not say whether a zero-width space at the start or end of the input is trimmed by step 1 or rejected as an invisible character"))
    func normalizeOfAZeroWidthSpaceAtTheEdgeOfTheInput() {
        #expect(rejection("reddit.com\u{200B}") == .invalidCharacters)
    }

    // A port that is not all digits is invalid characters, not a name with a port.
    @Test(arguments: ["reddit.com:abc", "reddit.com:80a", "reddit.com:a80", "reddit.com:-1", "reddit.com: 80", "reddit.com:8 0", "https://reddit.com:abc/path", "reddit.com:0x50", "reddit.com:\u{661}\u{662}"])
    func normalizeRejectsAPortThatIsNotAllDigitsAsInvalidCharacters(input: String) {
        #expect(rejection(input) == .invalidCharacters, "\(input.debugDescription)")
    }

    // MARK: error descriptions

    @Test func domainErrorIpAddressDescriptionIsTheSentenceFromTheDesign() {
        #expect(DomainError.ipAddress.errorDescription == "IP addresses can't be blocked through the hosts file. Enter a site name like example.com.")
    }

    @Test func everyDomainErrorHasADistinctNonEmptySentenceAndLocalizedDescriptionUsesIt() {
        let all: [DomainError] = [.empty, .ipAddress, .invalidCharacters, .labelTooLong, .tooLong, .needsDot, .reserved]
        let sentences = all.map { $0.errorDescription ?? "" }
        #expect(sentences.allSatisfy { !$0.isEmpty && $0.hasSuffix(".") })
        #expect(Set(sentences).count == all.count)
        for error in all { #expect(error.localizedDescription == error.errorDescription) }
    }

    // MARK: safety properties

    // Whatever the user types, the output is either a rejection or a host name that is safe to write into /etc/hosts:
    // no whitespace, newline, comment character or second host can ride along.
    @Test(arguments: [
        "reddit.com\n127.0.0.1 google.com", "reddit.com\r\n::1 evil.com", "reddit.com\t0.0.0.0 evil.com", "red dit.com", "reddit.com #x",
        "reddit.com\u{0}", "red\u{0}dit.com", "reddit.com\u{200B}", "red\u{200B}dit.com", "ｒｅｄｄｉｔ.com", "reddit.com\u{FEFF}",
        "reddit.com\u{2028}evil.com", "reddit.com\u{85}evil.com", "reddit%2ecom", "reddit.com%0a", "reddit.com;evil.com", "reddit.com|evil.com",
        "reddit.com\\evil.com", "reddit.com`id`", "reddit.com$(id)", "\"reddit.com\"", "'reddit.com'", "<reddit.com>", "reddit.com,evil.com",
    ])
    func normalizeNeverLetsHostsFileInjectionCharactersThrough(input: String) {
        guard let output = try? DomainNormalizer.normalize(input) else { return }
        #expect(isValidNormalizedHost(output), "accepted \(input.debugDescription) as \(output.debugDescription)")
    }

    // Structured inputs built around a known base name, so the expected answer is known by construction rather than computed.
    @Test func normalizeRecoversTheBaseNameFromRandomlyDecoratedInputs() throws {
        var rng = SeededGenerator(state: 20_260_706)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let tlds = ["com", "org", "net", "io", "co.uk", "de", "tv"]
        let schemes = ["", "http://", "https://", "HTTPS://", "ftp://"]
        let userInfos = ["", "user@", "user:pw@", "a:b@", "evil.com@"]
        let ports = ["", ":80", ":8443", ":65535"]
        // The "@" suffixes (a handle in a path, an address in a query, a mention in a fragment) must never be taken for user info,
        // because the cut at "/", "?" or "#" happens before the "@" is looked for (02-core-components.md § DomainNormalizer, Parsing details).
        let suffixes = ["", "/", "/a/b", "?q=1", "#f", "/p?q=1#f", "?next=/x", "/@user", "/@u/video/1", "?e=a@b.com", "#@x", "/p?e=a@b#@c", "/@a@b"]
        let wwws = ["", "www.", "WWW.", "Www."]
        let dots = ["", "."]
        let pads = ["", " ", "\n", "\t "]
        var checked = 0
        for _ in 0..<600 {
            let labelCount = Int.random(in: 1...3, using: &rng)
            var labels: [String] = []
            for _ in 0..<labelCount {
                let length = Int.random(in: 1...12, using: &rng)
                var label = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
                if label == "www" { label = "wwx" }
                labels.append(label)
            }
            let base = (labels + [tlds.randomElement(using: &rng)!]).joined(separator: ".")
            let host = String(base.map { Bool.random(using: &rng) ? Character($0.uppercased()) : $0 })
            let input = pads.randomElement(using: &rng)! + schemes.randomElement(using: &rng)! + userInfos.randomElement(using: &rng)!
                + wwws.randomElement(using: &rng)! + host + dots.randomElement(using: &rng)! + ports.randomElement(using: &rng)!
                + suffixes.randomElement(using: &rng)! + pads.randomElement(using: &rng)!
            let result = try? DomainNormalizer.normalize(input)
            #expect(result == base, "input \(input.debugDescription) should give \(base)")
            if result == base { checked += 1 }
        }
        #expect(checked == 600)
    }

    // Random noise from a hostile alphabet: every accepted output must satisfy the design's validity rules, and a second
    // pass over an accepted output changes nothing (except that a second "www." is stripped by the second pass).
    @Test func normalizeAcceptedOutputsAlwaysSatisfyTheDesignRulesForRandomNoise() {
        var rng = SeededGenerator(state: 99)
        let pieces = ["a", "b", "z", "0", "9", "-", "_", ".", ".", ".", "/", "?", "#", "@", ":", "[", "]", " ", "\n", "\t", "ü", "é", "日", "😀", "\u{0}", "www.", "com", "x.com", "://", "https://", "localhost", "local", "xn--"]
        var accepted = 0
        for _ in 0..<4000 {
            let count = Int.random(in: 1...14, using: &rng)
            let input = (0..<count).map { _ in pieces.randomElement(using: &rng)! }.joined()
            guard let output = try? DomainNormalizer.normalize(input) else { continue }
            accepted += 1
            #expect(isValidNormalizedHost(output), "accepted \(input.debugDescription) as \(output.debugDescription)")
            if !output.hasPrefix("www.") { #expect((try? DomainNormalizer.normalize(output)) == output, "not stable: \(output)") }
        }
        #expect(accepted > 0)
    }
}

// 02-core-components.md § DomainNormalizer step 6: sizes are checked on the raw Unicode scalars BEFORE any Punycode encoding. More than
// 63 scalars in one label throws .labelTooLong, and then more than 253 in the whole name throws .tooLong. A name that starts with
// "www." may have 257, because step 8 strips those four characters. Checking first matters because Punycode takes time that grows with
// the square of the label length, and the daemon runs it on the queue every command waits on.
@Suite struct DomainNormalizerSizeCheckTests {
    // A label of `count` distinct CJK characters starting at the given code point. Distinct characters are the worst case for Punycode,
    // because every one of them is a separate insertion.
    private func cjkLabel(count: Int, from start: UInt32 = 0x4E00) -> String {
        var scalars = String.UnicodeScalarView()
        for offset in 0..<count { scalars.append(Unicode.Scalar(start + UInt32(offset))!) }
        return String(scalars)
    }

    // The fastest of a few runs, so a busy machine cannot fail the test while a quadratic encoder (seconds per run) still does.
    private func fastestRun(of input: String, runs: Int = 3) -> (error: DomainError?, time: Duration) {
        var best = Duration.seconds(1_000_000)
        var error: DomainError?
        for _ in 0..<runs {
            let started = ContinuousClock.now
            error = rejection(input)
            best = min(best, started.duration(to: .now))
        }
        return (error, best)
    }

    @Test func aTwentyOneThousandCharacterDistinctLabelIsRejectedAsLabelTooLongInUnderFiftyMilliseconds() {
        let label = cjkLabel(count: 21_000)
        #expect(label.unicodeScalars.count == 21_000 && Set(label.unicodeScalars).count == 21_000)
        let result = fastestRun(of: label + ".com")
        #expect(result.error == .labelTooLong)
        #expect(result.time < .milliseconds(50), "took \(result.time)")
    }

    // Longer labels, and several long labels in one name, are just as quick: the check does not depend on how the input is split.
    @Test func aHugeNameMadeOfSeveralLongDistinctLabelsIsRejectedQuickly() {
        let input = [cjkLabel(count: 5_000), cjkLabel(count: 5_000, from: 0x6000), cjkLabel(count: 5_000, from: 0x7000), "com"].joined(separator: ".")
        let result = fastestRun(of: input)
        #expect(result.error == .labelTooLong)
        #expect(result.time < .milliseconds(50), "took \(result.time)")
    }

    // The fastest of a few runs of the body, so a busy machine or a scheduler pause cannot inflate the figure.
    private func fastest(runs: Int = 5, _ body: () -> Void) -> Duration {
        var best = Duration.seconds(1_000_000)
        for _ in 0..<runs {
            let started = ContinuousClock.now
            body()
            best = min(best, started.duration(to: .now))
        }
        return best
    }

    // Many labels that are each short enough (60 scalars), so no single label is slow to encode, but the whole name is dozens of
    // times over 253. The whole-name check runs before any encoding, so the answer is tooLong at once; without it every one of the
    // 300 labels would be Punycode-encoded first.
    //
    // The timing is a ratio, not a number of milliseconds, so it holds on a slow or busy machine: the rejection must be at least 20 times
    // faster than the Punycode work that an encode-first design would do for the same name. That work is measured here, in the same
    // process just before, by encoding the same 300 labels through the public encoder. (An accepted name cannot serve as the yardstick:
    // a name over 253 scalars is never accepted, and an accepted name's labels must encode to 63 characters or fewer, so an accepted
    // name is a few dozen scalars at most.) Measured on an unloaded machine: about 1 ms to reject, about 170 ms to encode, a ratio near
    // 140, which leaves 7 times of headroom over the required 20.
    @Test func aHugeNameMadeOfHundredsOfShortDistinctLabelsIsRejectedAsTooLongFarFasterThanEncodingItWouldTake() {
        let labels = (0..<300).map { cjkLabel(count: 60, from: 0x4E00 + UInt32($0)) }
        let name = labels.joined(separator: ".") + ".com"
        #expect(name.unicodeScalars.count > 18_000)
        let rejected = fastestRun(of: name)
        #expect(rejected.error == .tooLong)
        var encodedCount = 0
        let encoding = fastest { encodedCount = labels.compactMap { Punycode.toASCII(label: $0) }.count }
        #expect(encodedCount == 300, "premise: every label really is encoded by the baseline")
        #expect(rejected.time * 20 <= encoding, "rejecting took \(rejected.time) but encoding the same labels takes \(encoding): the size check must run before Punycode")
    }

    @Test func aHugeLabelInsideAFullUrlIsRejectedQuickly() {
        let result = fastestRun(of: "https://user:pw@" + cjkLabel(count: 21_000) + ".com:8080/path?q=1#frag")
        #expect(result.error == .labelTooLong)
        #expect(result.time < .milliseconds(50), "took \(result.time)")
    }

    // The label limit is checked first, so one 64-scalar label reports labelTooLong even though the same name is also short enough overall.
    @Test func aSixtyFourCharacterDistinctLabelIsLabelTooLong() {
        #expect(rejection(cjkLabel(count: 64) + ".com") == .labelTooLong)
    }

    // 63 + 1 + 63 + 1 + 63 + 1 + 62 = 254 scalars with no label over 63, so the label check passes and the whole-name check fails. Before
    // any encoding the name is judged by its scalars, so the answer is tooLong (an encoder-first design would say labelTooLong here,
    // because each encoded label is longer than 63 characters).
    @Test func aTwoHundredFiftyFourCharacterNonAsciiNameIsTooLong() {
        let labels = [cjkLabel(count: 63), cjkLabel(count: 63, from: 0x5000), cjkLabel(count: 63, from: 0x6000), cjkLabel(count: 62, from: 0x7000)]
        let name = labels.joined(separator: ".")
        #expect(name.unicodeScalars.count == 254)
        let result = fastestRun(of: name)
        #expect(result.error == .tooLong)
        #expect(result.time < .milliseconds(50), "took \(result.time)")
    }

    @Test func aTwoHundredFiftyFourCharacterAsciiNameIsTooLong() {
        #expect(name254.count == 254)
        #expect(rejection(name254) == .tooLong)
        #expect(rejection(name254 + ".") == .tooLong, "the trailing dot is removed first, so this is the same 254 characters")
    }

    // 4 + 63 + 1 + 63 + 1 + 63 + 1 + 58 = 254 scalars, but it starts with "www.", which step 8 strips, so it is allowed up to 257 and the
    // 250 characters left are a legal name.
    @Test func aNameThatStartsWithWwwMayHaveFourMoreCharactersBecauseTheyAreStripped() throws {
        let rest = "\(label63).\(label63).\(label63).\(String(repeating: "d", count: 58))"
        let typed = "www." + rest
        #expect(typed.count == 254 && rest.count == 250)
        #expect(try DomainNormalizer.normalize(typed) == rest)
        #expect(try DomainNormalizer.normalize(typed.uppercased()) == rest, "the case is folded before the size is judged")
    }

    // The full allowance: "www." plus a legal 253-character name is 257 characters and is accepted; one more character is not.
    @Test func wwwPlusALegalTwoHundredFiftyThreeCharacterNameIsAccepted() throws {
        #expect(name253.count == 253)
        let typed = "www." + name253
        #expect(typed.count == 257)
        #expect(try DomainNormalizer.normalize(typed) == name253)
        #expect(try DomainNormalizer.normalize("WWW." + name253 + ".") == name253)
        #expect(rejection("www." + name254) == .tooLong)
    }

    // The allowance is only for a leading "www.". A name that merely starts with "www" has the plain limit of 253.
    @Test func aNameThatOnlyLooksLikeItStartsWithWwwGetsNoExtraCharacters() {
        let typed = "wwwa.\(label63).\(label63).\(label63).\(String(repeating: "d", count: 57))"
        #expect(typed.count == 254)
        #expect(rejection(typed) == .tooLong)
        // And one character fewer is fine.
        let fits = "wwwa.\(label63).\(label63).\(label63).\(String(repeating: "d", count: 56))"
        #expect(fits.count == 253)
        #expect((try? DomainNormalizer.normalize(fits)) == fits)
    }

    // A label of 200,000 copies of one character gets the same error. Reading 200,000 scalars takes a few tens of milliseconds even
    // when nothing is wrong, and a repeated character is not the worst case for Punycode, so only a loose time bound is checked here
    // (the tight bounds above use distinct characters, where encoding first would take minutes).
    @Test func aHugeRepeatedCharacterLabelIsLabelTooLong() {
        let result = fastestRun(of: String(repeating: "\u{4E2D}", count: 200_000) + ".com")
        #expect(result.error == .labelTooLong)
        #expect(result.time < .seconds(2), "took \(result.time)")
    }
}

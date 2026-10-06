import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § DomainNormalizer (steps 1-8) and
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

    // "localhost" is both a single label (needsDot, step 8 second bullet) and a reserved name (last bullet). The design does
    // not say which wins, so the test only requires that it is rejected with one of the two.
    @Test func normalizeRejectsBareLocalhost() {
        let error = rejection("localhost")
        #expect(error == .needsDot || error == .reserved)
        #expect(rejection("LOCALHOST") == .needsDot || rejection("LOCALHOST") == .reserved)
        #expect(rejection("http://localhost:3000/app") == .needsDot || rejection("http://localhost:3000/app") == .reserved)
    }

    // The design lists no code for an empty label, so the test only requires a rejection.
    @Test(arguments: ["a..com", ".reddit.com", "reddit..com", "reddit.com..", ".", "..", "www.", "@", "reddit.com@", "https://", "http:///path", "?x=1", "#frag"])
    func normalizeRejectsEmptyLabelsAndNamesThatBecomeEmpty(input: String) {
        #expect(rejection(input) != nil)
    }

    // The design does not define unbracketed IPv6 text; it can never be a valid host name, so it must be rejected.
    @Test(arguments: ["::1", "2001:db8::1", "fe80::1%lo0"])
    func normalizeRejectsUnbracketedIPv6Text(input: String) {
        #expect(rejection(input) != nil)
    }

    // The design says "take everything after ://" without saying whether a "://" inside a query string counts. The
    // behavior matters: "reddit.com/?next=https://other.com" could block other.com instead of reddit.com.
    @Test(.disabled("spec gap: a '://' inside the query string of an otherwise bare name is not defined in 02-core-components.md § DomainNormalizer step 2"))
    func normalizeHandlesSchemeSeparatorInsideQuery() throws {
        #expect(try DomainNormalizer.normalize("reddit.com/?next=https://other.com") == "reddit.com")
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
        let suffixes = ["", "/", "/a/b", "?q=1", "#f", "/p?q=1#f", "?next=/x"]
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

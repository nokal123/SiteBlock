import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § 3d BlockedPage: the title "Blocked by SiteBlock"; `address(ruleText:)` is
// `data:text/html;charset=utf-8,` followed by the page HTML percent-encoded, with every character except ASCII letters, digits and `-._~` encoded;
// `html(ruleText:)` holds the heading "<rule> is blocked" and the line "SiteBlock blocked this page. To open it again, use the SiteBlock menu bar app.",
// and HTML-escapes `&`, `<`, `>`, `"` and `'` one Unicode scalar at a time; a `data:` address matches no rule (§ 3b, step 2). 05-testing-and-operations.md
// § Unit Tests (BlockedPageTests) lists the cases. The design does not fix which entity spelling is used (`&#39;` or `&apos;`) or the case of the hex digits,
// so the checks below accept any standard spelling and decode both themselves instead of comparing with a fixed string.

private let prefix = "data:text/html;charset=utf-8,"
private let bodyLine = "SiteBlock blocked this page. To open it again, use the SiteBlock menu bar app."

// Rule texts that try to break out of the page: markup, script, every escaped character, a combining mark glued onto `<`, characters that matter in an
// address, whitespace, and non-ASCII text.
private let hostileRuleTexts = ["<script>alert(1)</script>", "a&b", "say \"hi\"", "it's", "x>y", "<\u{301}b>", "<\u{301}script>alert(1)<\u{301}/script>", "x.com/#frag", "x.com/100%25", "%3Cscript%3E", "two words", "line1\nline2\r\n<i>", "例え.jp", "x.com/😀", "&lt;already escaped&gt;", "\"><img src=x onerror=alert(1)>", "'; DROP?+*$!@=~", "</h1><script>x</script>", ""]

// Decodes an address body the way a browser does: every `%XX` becomes the byte XX, everything else is its own ASCII byte. Returns nil for a broken escape.
private func percentDecodedBytes(_ text: String) -> [UInt8]? {
    var bytes: [UInt8] = []
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        if scalars[i] == "%" {
            guard i + 2 < scalars.count, let byte = UInt8(String(scalars[i + 1]) + String(scalars[i + 2]), radix: 16) else { return nil }
            bytes.append(byte)
            i += 3
        } else {
            guard scalars[i].isASCII else { return nil }
            bytes.append(UInt8(scalars[i].value))
            i += 1
        }
    }
    return bytes
}

// The scalars the design leaves as they are: ASCII letters, digits and - . _ ~.
private func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "-", ".", "_", "~": return true
    default: return false
    }
}

// Lists every scalar of the address body that is neither an unreserved character nor part of a well-formed `%XX` escape.
private func badAddressScalars(_ body: String) -> [Unicode.Scalar] {
    let scalars = Array(body.unicodeScalars)
    var bad: [Unicode.Scalar] = []
    var i = 0
    while i < scalars.count {
        if scalars[i] == "%", i + 2 < scalars.count, scalars[i + 1].properties.isASCIIHexDigit, scalars[i + 2].properties.isASCIIHexDigit {
            i += 3
        } else {
            if !isUnreserved(scalars[i]) { bad.append(scalars[i]) }
            i += 1
        }
    }
    return bad
}

// Turns an HTML text run back into plain text: the standard entity spellings of the five escaped characters, decimal and hex numeric entities.
// Returns nil when an `&` does not start one of those, which means a raw `&` reached the page.
private func decodeEntities(_ text: String) -> String? {
    var result = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var i = 0
    let named: [String: Unicode.Scalar] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
    while i < scalars.count {
        guard scalars[i] == "&" else { result.append(scalars[i]); i += 1; continue }
        guard let end = scalars[i...].firstIndex(of: ";"), end - i <= 10 else { return nil }
        let name = String(String.UnicodeScalarView(scalars[(i + 1)..<end]))
        if let scalar = named[name] {
            result.append(scalar)
        } else if name.hasPrefix("#x") || name.hasPrefix("#X"), let value = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
            result.append(scalar)
        } else if name.hasPrefix("#"), let value = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) {
            result.append(scalar)
        } else {
            return nil
        }
        i = end + 1
    }
    return String(result)
}

// Finds the text the page shows as the heading: whatever sits between the start and end markers wrapped around the rule text, in every place the
// markers appear. Works on scalars so a combining mark cannot hide a character from the search.
private func markedRuns(in html: String, start: String, end: String) -> [String] {
    var runs: [String] = []
    var rest = Substring(html)
    while let s = rest.range(of: start, options: .literal) {
        let after = rest[s.upperBound...]
        guard let e = after.range(of: end, options: .literal) else { break }
        runs.append(String(after[..<e.lowerBound]))
        rest = after[e.upperBound...]
    }
    return runs
}

// Counts the places `needle` appears in `text`, comparing scalars and ignoring case.
private func occurrences(of needle: String, in text: String) -> Int {
    var count = 0
    var rest = Substring(text)
    while let r = rest.range(of: needle, options: [.caseInsensitive, .literal]) { count += 1; rest = rest[r.upperBound...] }
    return count
}

@Suite struct BlockedPageAddressTests {
    // The design fixes the page title.
    @Test func theTitleIsBlockedBySiteBlock() {
        #expect(BlockedPage.title == "Blocked by SiteBlock")
    }

    // The address starts with the exact data: prefix, and its body holds only unreserved ASCII characters and well-formed %XX escapes.
    @Test(arguments: ["x.com", "youtube.com/shorts"] + hostileRuleTexts)
    func theAddressIsTheDataPrefixFollowedOnlyBySafeCharacters(ruleText: String) {
        let address = BlockedPage.address(ruleText: ruleText)
        #expect(address.hasPrefix(prefix))
        let body = String(address.dropFirst(prefix.count))
        #expect(badAddressScalars(body).isEmpty, "unencoded characters: \(badAddressScalars(body))")
    }

    // Decoding the address body byte by byte gives back exactly the UTF-8 bytes of html(ruleText:), so nothing was lost or cut short (by a `#` for example).
    @Test(arguments: ["x.com", "youtube.com/shorts"] + hostileRuleTexts)
    func decodingTheAddressGivesBackTheHTMLExactly(ruleText: String) {
        let body = String(BlockedPage.address(ruleText: ruleText).dropFirst(prefix.count))
        #expect(percentDecodedBytes(body) == Array(BlockedPage.html(ruleText: ruleText).utf8))
    }

    // `#`, `%`, spaces, newlines and non-ASCII characters never appear raw in the address: a raw `#` would start a fragment and cut the page short.
    @Test func charactersThatMatterInAnAddressAreAllEncoded() {
        let body = String(BlockedPage.address(ruleText: "a#b%c d\ne例😀?+*$!@=;:/,()[]{}|^`\\").dropFirst(prefix.count))
        for raw in ["#", " ", "\n", "例", "😀", "<", ">", "\"", "'", "&", "=", ";", ":", "/", "?", "+", ",", "*", "$", "!", "@", "(", ")", "[", "]", "{", "}", "|", "^", "`", "\\"] {
            #expect(!body.unicodeScalars.contains(raw.unicodeScalars.first!), "raw \(raw.debugDescription) in the address")
        }
        // Every `%` in the body must begin an escape: a raw `%` from the rule text would change the decoded page.
        #expect(badAddressScalars(body).isEmpty)
        #expect(body.contains("%23"), "the rule's # must appear as %23")
        #expect(body.contains("%25"), "the rule's % must appear as %25")
    }

    // The page itself is a data: address, so it never matches a rule, even a whole-site rule and a path rule for the very site it names.
    @Test(arguments: ["x.com", "youtube.com/shorts", "https://x.com/", "x.com/#frag"])
    func theBlockedPageAddressMatchesNoRule(ruleText: String) {
        let rules = [WatchedPathRule(domain: "x.com", path: "/"), WatchedPathRule(domain: "youtube.com", path: "/"), WatchedPathRule(domain: "youtube.com", path: "/shorts"), WatchedPathRule(domain: "x.com", path: "/Home")]
        #expect(TabRuleMatcher.matchingRule(url: BlockedPage.address(ruleText: ruleText), rules: rules) == nil)
    }

    // Two different rule texts give two different addresses, so the decider's address memory tells them apart.
    @Test func differentRulesGiveDifferentAddresses() {
        #expect(BlockedPage.address(ruleText: "x.com") != BlockedPage.address(ruleText: "y.com"))
        #expect(BlockedPage.address(ruleText: "x.com") == BlockedPage.address(ruleText: "x.com"))
    }
}

@Suite struct BlockedPageHTMLTests {
    // The page has the title, the heading "<rule> is blocked" and the fixed line about the menu bar app.
    @Test func thePageHasTheTitleTheHeadingAndTheLine() {
        let html = BlockedPage.html(ruleText: "youtube.com/shorts")
        #expect(markedRuns(in: html, start: "<title>", end: "</title>") == ["Blocked by SiteBlock"])
        #expect(html.contains("youtube.com/shorts is blocked"))
        #expect(html.contains(bodyLine))
    }

    // The page follows the system's light or dark appearance.
    @Test func thePageFollowsTheSystemAppearance() {
        let html = BlockedPage.html(ruleText: "x.com")
        // The page sets light colors, so following the appearance needs a dark-mode media block that gives the body another background; a
        // `<meta name="color-scheme">` tag alone does not change an explicitly set background.
        let darkBlock = #/@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)\s*\{(.*?)\}\s*\}/#.dotMatchesNewlines()
        let block = try? darkBlock.firstMatch(in: html)
        #expect(block != nil, "no prefers-color-scheme: dark media block")
        let inside = block.map { String($0.1) } ?? ""
        #expect(inside.contains(#/(^|[\s;}])body\s*\{[^}]*background/#), "the dark block has no body rule setting background: \(inside)")
    }

    // Every place the rule text lands shows it escaped: no raw `<`, `>`, `"` or `'` scalar, every `&` starts an entity, and decoding gives the rule back.
    @Test(arguments: hostileRuleTexts)
    func theRuleTextIsEscapedEverywhereItAppears(ruleText: String) {
        let html = BlockedPage.html(ruleText: "QQSTART" + ruleText + "QQEND")
        let runs = markedRuns(in: html, start: "QQSTART", end: "QQEND")
        #expect(!runs.isEmpty, "the rule text must be on the page")
        for run in runs {
            let raw = run.unicodeScalars.filter { "<>\"'".unicodeScalars.contains($0) }
            #expect(raw.isEmpty, "raw markup characters \(raw) in \(run.debugDescription)")
            let decoded = decodeEntities(run)
            #expect(decoded != nil, "a raw & or an unknown entity in \(run.debugDescription)")
            #expect(decoded.map { Array($0.unicodeScalars) } == Array(ruleText.unicodeScalars), "decoding \(run.debugDescription) must give the rule back scalar for scalar")
        }
    }

    // The heading reads "<rule> is blocked" with the rule escaped, for hostile rule texts too.
    @Test(arguments: hostileRuleTexts)
    func theHeadingReadsRuleIsBlocked(ruleText: String) {
        let html = BlockedPage.html(ruleText: "QQSTART" + ruleText)
        #expect(!markedRuns(in: html, start: "QQSTART", end: " is blocked").isEmpty, "the heading must end with \" is blocked\" right after the rule")
    }

    // A rule can never add markup: the page holds no `<script`, `<img` or `<i>` (compared scalar by scalar, ignoring case) beyond what a harmless
    // rule's page holds, and it has exactly as many raw `<` and `>` scalars as that page, so no tag was opened or closed by the rule.
    @Test(arguments: hostileRuleTexts)
    func aRuleAddsNoMarkupToThePage(ruleText: String) {
        let html = BlockedPage.html(ruleText: ruleText)
        let baseline = BlockedPage.html(ruleText: "x")
        for tag in ["<script", "<img", "<i>", "</h1"] {
            #expect(occurrences(of: tag, in: html) == occurrences(of: tag, in: baseline), "\(tag) count changed")
        }
        #expect(html.range(of: "<script", options: [.caseInsensitive, .literal]) == nil)
        for mark: Unicode.Scalar in ["<", ">"] {
            #expect(html.unicodeScalars.filter { $0 == mark }.count == baseline.unicodeScalars.filter { $0 == mark }.count, "raw \(mark) count changed")
        }
    }

    // A `<` with a combining mark glued onto it is one Character in Swift but two scalars; the `<` scalar must still be escaped.
    @Test func aLessThanSignWithACombiningMarkIsStillEscaped() {
        let html = BlockedPage.html(ruleText: "QQSTART<\u{301}b>QQEND")
        let run = markedRuns(in: html, start: "QQSTART", end: "QQEND").first ?? ""
        #expect(!run.unicodeScalars.contains("<"), "raw < scalar in \(run.debugDescription)")
        #expect(!run.unicodeScalars.contains(">"))
        #expect(run.unicodeScalars.contains("\u{301}"), "the combining mark itself is kept")
        #expect(decodeEntities(run).map { Array($0.unicodeScalars) } == Array("<\u{301}b>".unicodeScalars))
    }

    // Text that already looks escaped is escaped again, so the page shows exactly what the rule says and not what it would decode to.
    @Test func alreadyEscapedTextIsShownAsTyped() {
        let html = BlockedPage.html(ruleText: "QQSTART&lt;b&gt;QQEND")
        let run = markedRuns(in: html, start: "QQSTART", end: "QQEND").first ?? ""
        #expect(decodeEntities(run) == "&lt;b&gt;")
    }
}

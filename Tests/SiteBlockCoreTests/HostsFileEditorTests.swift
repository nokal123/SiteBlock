import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/02-core-components.md § HostsFileEditor (render steps 1-5, marker rule, constants)
// and 05-testing-and-operations.md § Unit Tests (HostsFileEditorTests). The marker strings and the section layout below are
// typed independently from the design, not taken from the library.

private let begin = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted"
private let end = "# END SiteBlock"

// The stock macOS hosts file, with its tabs and its run of spaces before the second "localhost".
private let defaultHosts = "##\n# Host Database\n#\n# localhost is used to configure the loopback interface\n# when the system is booting.  Do not change this entry.\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"

// The managed section the design describes: BEGIN line, then "0.0.0.0 host" and ":: host" for each host in sorted order, then END.
private func section(_ hosts: [String]) -> String {
    var text = begin + "\n"
    for host in hosts.sorted() { text += "0.0.0.0 \(host)\n:: \(host)\n" }
    return text + end + "\n"
}

// What the design says the file looks like after a render: the user's text, one blank line, then the section.
private func withSection(_ userText: String, _ hosts: [String]) -> String {
    hosts.isEmpty ? userText : userText + "\n" + section(hosts)
}

private func count(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

// An independent implementation of the five render steps, written from the design text only. Used to cross-check the
// real renderer on thousands of generated files. It only supports inputs where the design is unambiguous: no whitespace-only
// lines and single-space separators on lines that lose a name.
private func referenceRender(original: String, blocked: [String]) -> String {
    func trim(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
    let lines = original.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var kept: [String] = []
    var index = 0
    while index < lines.count {
        let t = trim(lines[index])
        if t.hasPrefix("# BEGIN SiteBlock") {
            if let endIndex = lines[(index + 1)...].firstIndex(where: { trim($0) == "# END SiteBlock" }) { index = endIndex + 1 } else { index += 1 }
            continue
        }
        if t == "# END SiteBlock" { index += 1; continue }
        kept.append(lines[index])
        index += 1
    }
    let blockedSet = Set(blocked.map { $0.lowercased() })
    var out: [String] = []
    for line in kept {
        let t = trim(line)
        if t.isEmpty || t.hasPrefix("#") { out.append(line); continue }
        let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let fields = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2 else { out.append(line); continue }
        let names = Array(fields.dropFirst())
        let remaining = names.filter { !blockedSet.contains($0.lowercased()) }
        if remaining.count == names.count { out.append(line); continue }
        if remaining.isEmpty { continue }
        out.append(([fields[0]] + remaining).joined(separator: " "))
    }
    while let last = out.last, last.isEmpty { out.removeLast() }
    var text = out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    if !blocked.isEmpty { text += "\n" + section(blocked) }
    return text
}

// A small seeded random generator (SplitMix64) so the generated files are the same on every run.
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

// Builds one random hosts file that starts with the stock header and then mixes comments, blank lines, user entries
// (some naming blocked hosts), well-formed and broken managed sections, and stray markers.
private func randomHostsFile(_ rng: inout SeededGenerator) -> String {
    let addresses = ["1.2.3.4", "151.101.1.140", "0.0.0.0", "::", "10.0.0.5"]
    let names = ["reddit.com", "www.reddit.com", "other.com", "i.redd.it", "nas.lan", "Reddit.Com", "REDD.IT", "redd.it"]
    let comments = ["# some note", "# 1.2.3.4 reddit.com", "#reddit.com", "# reddit.com", "   # indented comment"]
    let beginLines = [begin, "# BEGIN SiteBlock", "# BEGIN SiteBlock (edited)", "   # BEGIN SiteBlock — x  ", "\t# BEGIN SiteBlock"]
    let endLines = [end, "  # END SiteBlock  ", "\t# END SiteBlock"]
    var lines = defaultHosts.components(separatedBy: "\n").dropLast().map { $0 }
    for _ in 0..<Int.random(in: 0...14, using: &rng) {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: lines.append("")
        case 1: lines.append(comments.randomElement(using: &rng)!)
        case 2: lines.append(beginLines.randomElement(using: &rng)!)
        case 3: lines.append(endLines.randomElement(using: &rng)!)
        default:
            let count = Int.random(in: 1...3, using: &rng)
            let chosen = (0..<count).map { _ in names.randomElement(using: &rng)! }
            lines.append(([addresses.randomElement(using: &rng)!] + chosen).joined(separator: " "))
        }
    }
    let newline = Bool.random(using: &rng) ? "\n" : "\r\n"
    var text = lines.joined(separator: newline)
    switch Int.random(in: 0..<3, using: &rng) {
    case 0: text += newline
    case 1: text += newline + newline + newline
    default: break
    }
    return text
}

@Suite struct HostsFileEditorTests {
    // MARK: constants and managedSection

    @Test func markersAreExactlyTheStringsFromTheDesign() {
        #expect(HostsFileEditor.beginMarker == begin)
        #expect(HostsFileEditor.endMarker == end)
    }

    // The design leaves open whether the returned section ends with a newline, so the comparison ignores one trailing newline.
    @Test func managedSectionListsEachHostInSortedOrderAsTwoLinesBetweenTheMarkers() {
        let text = HostsFileEditor.managedSection(for: ["www.reddit.com", "reddit.com", "i.redd.it"])
        let lines = text.hasSuffix("\n") ? String(text.dropLast()).components(separatedBy: "\n") : text.components(separatedBy: "\n")
        #expect(lines == [begin, "0.0.0.0 i.redd.it", ":: i.redd.it", "0.0.0.0 reddit.com", ":: reddit.com", "0.0.0.0 www.reddit.com", ":: www.reddit.com", end])
    }

    @Test func managedSectionForNoHostsIsJustTheTwoMarkers() {
        let text = HostsFileEditor.managedSection(for: [])
        let lines = text.hasSuffix("\n") ? String(text.dropLast()).components(separatedBy: "\n") : text.components(separatedBy: "\n")
        #expect(lines == [begin, end])
    }

    // MARK: the default file and the basic shape of the result

    @Test func renderAddsTheSectionToTheDefaultMacOSFileAndKeepsItsOwnLinesByteForByte() {
        #expect(HostsFileEditor.render(original: defaultHosts, blockedHosts: ["reddit.com"]) == defaultHosts + "\n" + section(["reddit.com"]))
    }

    @Test func renderSortsTheHostsItWritesWhateverOrderTheyArriveIn() {
        let hosts = ["www.reddit.com", "reddit.com", "i.redd.it", "m.reddit.com"]
        #expect(HostsFileEditor.render(original: defaultHosts, blockedHosts: hosts) == withSection(defaultHosts, hosts))
    }

    @Test func renderWritesTheTwoAddressFamiliesForEveryExpandedRedditName() {
        let hosts = DomainExpander.expand("reddit.com")
        let result = HostsFileEditor.render(original: defaultHosts, blockedHosts: hosts)
        for host in hosts {
            #expect(result.contains("\n0.0.0.0 \(host)\n"))
            #expect(result.contains("\n:: \(host)\n"))
        }
        #expect(result.hasSuffix(end + "\n"))
    }

    @Test(arguments: [[], ["reddit.com"], ["reddit.com", "www.reddit.com", "i.redd.it"]])
    func renderTwiceGivesTheSameTextAsRenderingOnce(hosts: [String]) {
        for original in [defaultHosts, withSection(defaultHosts, ["old.com"]), "", "127.0.0.1 localhost", "\r\n\r\n", begin + "\n", end + "\n"] {
            let once = HostsFileEditor.render(original: original, blockedHosts: hosts)
            #expect(HostsFileEditor.render(original: once, blockedHosts: hosts) == once)
            #expect(HostsFileEditor.isCompliant(once, blockedHosts: hosts))
        }
    }

    @Test func renderWithAnEmptyBlockListRemovesTheSectionAndLeavesTheUsersLines() {
        let original = withSection(defaultHosts, ["reddit.com", "www.reddit.com"])
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts)
        #expect(HostsFileEditor.render(original: defaultHosts, blockedHosts: []) == defaultHosts)
    }

    @Test func renderReplacesAHandEditedSectionWithTheCorrectOne() {
        let edited = defaultHosts + "\n" + begin + "\n0.0.0.0 reddit.com\n0.0.0.0 evil.com\n# my note\n" + end + "\n"
        #expect(HostsFileEditor.render(original: edited, blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    // The marker rule: trimmed text that starts with the BEGIN text, or equals the END text.
    @Test func renderRecognizesMarkersWithTrailingSpacesIndentsTabsAndEditedBeginComments() {
        let edited = defaultHosts + "\n   # BEGIN SiteBlock (I edited this comment)  \n0.0.0.0 reddit.com\n\t# END SiteBlock \t\n"
        #expect(HostsFileEditor.render(original: edited, blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    @Test func renderCollapsesTwoSectionsIntoOne() {
        let doubled = defaultHosts + "\n" + section(["reddit.com"]) + "\n" + section(["other.com"])
        let result = HostsFileEditor.render(original: doubled, blockedHosts: ["reddit.com"])
        #expect(result == withSection(defaultHosts, ["reddit.com"]))
        #expect(count(of: "# BEGIN SiteBlock", in: result) == 1)
        #expect(count(of: "# END SiteBlock", in: result) == 1)
    }

    // Only the BEGIN..END lines are removed; a user line between two sections stays, and the blank line before the first
    // section stays too because only trailing blank lines are trimmed.
    @Test func renderKeepsAUserLineThatSitsBetweenTwoSections() {
        let original = defaultHosts + "\n" + section(["a.com"]) + "10.9.8.7 between.lan\n" + section(["b.com"])
        let expected = defaultHosts + "\n10.9.8.7 between.lan\n" + "\n" + section(["a.com"])
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["a.com"]) == expected)
    }

    // The section is always written at the end, so user lines that followed it come before it afterwards.
    @Test func renderMovesUserLinesThatFollowedTheSectionAheadOfTheNewSection() {
        let original = defaultHosts + "\n" + section(["reddit.com"]) + "10.0.0.9 myserver\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == defaultHosts + "\n10.0.0.9 myserver\n" + "\n" + section(["reddit.com"]))
    }

    @Test func renderRemovesASectionThatSitsAtTheTopOfTheFile() {
        #expect(HostsFileEditor.render(original: section(["reddit.com"]) + defaultHosts, blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    // Everything between BEGIN and END is the managed block, including lines a user typed there.
    @Test func renderDeletesUserLinesTypedInsideTheManagedBlock() {
        let original = defaultHosts + begin + "\n# my note inside\n10.0.0.1 inside.lan\n" + end + "\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts)
    }

    // MARK: broken sections

    // Deleting from an unmatched BEGIN to the end of the file could destroy the user's own entries.
    @Test func renderRemovesOnlyTheBeginLineWhenThereIsNoEndAndKeepsLinesAfterIt() {
        let original = defaultHosts + begin + "\n10.0.0.5 nas.lan\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.5 nas.lan\n")
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == defaultHosts + "10.0.0.5 nas.lan\n" + "\n" + section(["reddit.com"]))
    }

    @Test func renderOrphanBeginFollowedByOldManagedLinesDropsThoseLinesOnlyWhenTheirHostsAreBlocked() {
        let original = defaultHosts + begin + "\n0.0.0.0 reddit.com\n:: reddit.com\n10.0.0.5 nas.lan\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == defaultHosts + "10.0.0.5 nas.lan\n" + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "0.0.0.0 reddit.com\n:: reddit.com\n10.0.0.5 nas.lan\n")
    }

    @Test func renderRemovesAStrayEndLineAndKeepsTheLinesAroundIt() {
        #expect(HostsFileEditor.render(original: defaultHosts + end + "\n", blockedHosts: []) == defaultHosts)
        #expect(HostsFileEditor.render(original: defaultHosts + "10.0.0.5 a\n" + end + "\n10.0.0.6 b\n", blockedHosts: []) == defaultHosts + "10.0.0.5 a\n10.0.0.6 b\n")
    }

    @Test func renderRemovesASecondEndLineThatFollowsAWholeSection() {
        let original = defaultHosts + "\n" + section(["reddit.com"]) + end + "\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    @Test func renderTreatsAnEndBeforeABeginAsStrayEndPlusOrphanBegin() {
        let original = defaultHosts + end + "\n10.0.0.5 a\n" + begin + "\n10.0.0.6 b\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.5 a\n10.0.0.6 b\n")
    }

    // "A section starts at a BEGIN line and ends at the next END line": a second BEGIN inside it does not start a new section.
    @Test func renderEndsASectionAtTheFirstEndEvenWhenAnotherBeginAppearsInside() {
        let original = defaultHosts + begin + "\n0.0.0.0 zzz.com\n" + begin + "\n10.0.0.7 q\n" + end + "\n10.0.0.8 after\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.8 after\n")
    }

    // The END marker must equal "# END SiteBlock" once trimmed, so a longer comment is not an END and the BEGIN stays orphaned.
    @Test func renderDoesNotTreatALongerCommentStartingWithTheEndTextAsAnEndMarker() {
        let original = defaultHosts + begin + "\n10.0.0.5 nas.lan\n# END SiteBlock notes\n10.0.0.6 b\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.5 nas.lan\n# END SiteBlock notes\n10.0.0.6 b\n")
    }

    // MARK: bypass lines (step 3)

    @Test func renderRemovesABlockedNameFromAUserLineThatHasOtherNames() {
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 reddit.com other.com\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.com\n" + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 other.com reddit.com\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.com\n" + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 a.com reddit.com b.com\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 a.com b.com\n" + "\n" + section(["reddit.com"]))
    }

    @Test func renderDropsAUserLineWhoseNamesAreAllBlocked() {
        let blocked = ["reddit.com", "www.reddit.com"]
        #expect(HostsFileEditor.render(original: defaultHosts + "151.101.1.140 reddit.com\n", blockedHosts: blocked) == withSection(defaultHosts, blocked))
        #expect(HostsFileEditor.render(original: defaultHosts + "151.101.1.140 reddit.com www.reddit.com\n", blockedHosts: blocked) == withSection(defaultHosts, blocked))
        #expect(HostsFileEditor.render(original: "151.101.1.140 reddit.com\n" + defaultHosts, blockedHosts: blocked) == withSection(defaultHosts, blocked))
    }

    @Test func renderDropsBypassLinesThatUseTheBlockAddresses() {
        let original = defaultHosts + "0.0.0.0 reddit.com\n:: reddit.com\n127.0.0.1 reddit.com\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    @Test func renderMatchesBlockedNamesIgnoringCaseInEitherDirection() {
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 REDDIT.com other.com\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.com\n" + "\n" + section(["reddit.com"]))
        let upperBlocked = HostsFileEditor.render(original: defaultHosts + "1.2.3.4 reddit.com\n", blockedHosts: ["Reddit.COM"])
        #expect(!upperBlocked.contains("1.2.3.4 reddit.com"))
    }

    // A name must equal a blocked host. Longer names that merely contain it, or share a suffix, are different hosts.
    @Test func renderKeepsLinesWhoseNamesOnlyResembleABlockedHost() {
        let lines = "1.2.3.4 www.reddit.com\n1.2.3.4 notreddit.com\n1.2.3.4 reddit.com.evil.org\n1.2.3.4 reddit.community\n1.2.3.4 xreddit.com\n"
        #expect(HostsFileEditor.render(original: defaultHosts + lines, blockedHosts: ["reddit.com"]) == defaultHosts + lines + "\n" + section(["reddit.com"]))
    }

    @Test func renderKeepsCommentLinesThatMentionABlockedHost() {
        let comments = "# reddit.com is blocked by SiteBlock\n#reddit.com\n   # 1.2.3.4 reddit.com\n# 151.101.1.140 reddit.com\n"
        #expect(HostsFileEditor.render(original: defaultHosts + comments, blockedHosts: ["reddit.com"]) == defaultHosts + comments + "\n" + section(["reddit.com"]))
    }

    // Anything after "#" is a comment, so a blocked name that only appears in the comment part is not a name on the line.
    @Test func renderKeepsALineWhoseTrailingCommentMentionsABlockedHost() {
        let line = "1.2.3.4 other.com # reddit.com\n"
        #expect(HostsFileEditor.render(original: defaultHosts + line, blockedHosts: ["reddit.com"]) == defaultHosts + line + "\n" + section(["reddit.com"]))
    }

    // The resolver treats everything after "#" as a comment even with no space before it, so "reddit.com#x" is the name
    // "reddit.com" and would bypass the block if it were kept.
    @Test func renderDropsALineWhereTheBlockedNameIsFollowedDirectlyByAHash() {
        let original = defaultHosts + "1.2.3.4 reddit.com#note\n1.2.3.4 reddit.com # note\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    // The design does not say whether an inline comment survives on a line that loses a name, so only the name list is checked.
    @Test func renderKeepsTheOtherNamesOnALineWithAnInlineCommentWhenOneNameIsRemoved() {
        let result = HostsFileEditor.render(original: defaultHosts + "1.2.3.4 reddit.com other.com # keep\n", blockedHosts: ["reddit.com"])
        let userLines = result.components(separatedBy: "\n").filter { $0.contains("other.com") }
        #expect(userLines.count == 1)
        let fields = (userLines.first ?? "").split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
        #expect(fields == ["1.2.3.4", "other.com"])
    }

    // MARK: whitespace, line endings, file ends

    @Test func renderHandlesTabsBetweenFieldsOnLinesThatLoseNames() {
        let result = HostsFileEditor.render(original: defaultHosts + "1.2.3.4\treddit.com\tother.com\n", blockedHosts: ["reddit.com"])
        let userLine = result.components(separatedBy: "\n").first { $0.contains("other.com") && !$0.hasPrefix("0.0.0.0") && !$0.hasPrefix("::") }
        #expect((userLine ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) == ["1.2.3.4", "other.com"])
        #expect(!result.contains("1.2.3.4\treddit.com"))
        #expect(HostsFileEditor.render(original: defaultHosts + "151.101.1.140\treddit.com\n", blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + " \t 1.2.3.4 \t reddit.com \t\n", blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    // Swift treats "\r\n" as one Character, which is a classic way for a "\n" split to miss every line break.
    @Test func renderConvertsCRLFInputToLFOutput() {
        let crlf = defaultHosts.replacingOccurrences(of: "\n", with: "\r\n")
        let result = HostsFileEditor.render(original: crlf, blockedHosts: ["reddit.com"])
        #expect(result == withSection(defaultHosts, ["reddit.com"]))
        #expect(!result.contains("\r"))
    }

    @Test func renderRecognizesAndReplacesAManagedSectionInACRLFFile() {
        let crlf = withSection(defaultHosts, ["old.com"]).replacingOccurrences(of: "\n", with: "\r\n")
        let result = HostsFileEditor.render(original: crlf, blockedHosts: ["reddit.com"])
        #expect(result == withSection(defaultHosts, ["reddit.com"]))
        #expect(!result.contains("\r"))
    }

    @Test func renderRemovesBypassLinesFromACRLFFile() {
        let crlf = (defaultHosts + "151.101.1.140 reddit.com other.com\n").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(HostsFileEditor.render(original: crlf, blockedHosts: ["reddit.com"]) == defaultHosts + "151.101.1.140 other.com\n" + "\n" + section(["reddit.com"]))
    }

    @Test func renderHandlesAFileWithMixedLineEndings() {
        let mixed = "127.0.0.1\tlocalhost\r\n::1\tlocalhost\n1.2.3.4 reddit.com other.com\r\n"
        #expect(HostsFileEditor.render(original: mixed, blockedHosts: ["reddit.com"]) == "127.0.0.1\tlocalhost\n::1\tlocalhost\n1.2.3.4 other.com\n" + "\n" + section(["reddit.com"]))
    }

    @Test func renderAddsTheMissingFinalNewlineWhenTheFileHasNone() {
        #expect(HostsFileEditor.render(original: "127.0.0.1\tlocalhost", blockedHosts: ["reddit.com"]) == "127.0.0.1\tlocalhost\n" + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: "127.0.0.1\tlocalhost", blockedHosts: []) == "127.0.0.1\tlocalhost\n")
        #expect(HostsFileEditor.render(original: defaultHosts + begin + "\n0.0.0.0 a.com\n" + end, blockedHosts: []) == defaultHosts)
    }

    @Test func renderTrimsTrailingBlankLinesBeforeAddingTheSection() {
        #expect(HostsFileEditor.render(original: defaultHosts + "\n\n\n", blockedHosts: []) == defaultHosts)
        #expect(HostsFileEditor.render(original: defaultHosts + "\n\n\n", blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
    }

    // Blank lines in the middle belong to the user's formatting, so they stay. (The design only says trailing blank lines go.)
    @Test func renderKeepsBlankLinesInTheMiddleOfTheFile() {
        let original = "127.0.0.1 localhost\n\n\n10.0.0.1 a\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == original)
    }

    @Test func renderKeepsNonASCIICommentsAndNamesUntouched() {
        let lines = "# café ☕ reddit.com\n1.2.3.4 bücher.de\n"
        #expect(HostsFileEditor.render(original: defaultHosts + lines, blockedHosts: ["reddit.com"]) == defaultHosts + lines + "\n" + section(["reddit.com"]))
    }

    @Test func renderOfAnEmptyFileWithNoBlockedHostsIsEmpty() {
        #expect(HostsFileEditor.render(original: "", blockedHosts: []) == "")
    }

    // The design does not say whether the section of a file with no other content starts with a blank line, so only the
    // properties that matter are checked: the section is there, exactly once, and the result is stable.
    @Test func renderOfAnEmptyFileProducesAStableFileWithOneSection() {
        let result = HostsFileEditor.render(original: "", blockedHosts: ["reddit.com"])
        #expect(result.hasSuffix(section(["reddit.com"])))
        #expect(count(of: "# BEGIN SiteBlock", in: result) == 1)
        #expect(HostsFileEditor.render(original: result, blockedHosts: ["reddit.com"]) == result)
    }

    // MARK: isCompliant

    @Test func isCompliantIsTrueForTheRenderedFileAndForTheDefaultFileWithNothingBlocked() {
        #expect(HostsFileEditor.isCompliant(withSection(defaultHosts, ["reddit.com"]), blockedHosts: ["reddit.com"]))
        #expect(HostsFileEditor.isCompliant(defaultHosts, blockedHosts: []))
        #expect(HostsFileEditor.isCompliant("", blockedHosts: []))
    }

    @Test func isCompliantIsFalseWhenTheSectionIsMissing() {
        #expect(!HostsFileEditor.isCompliant(defaultHosts, blockedHosts: ["reddit.com"]))
    }

    @Test func isCompliantIsFalseWhenAHostIsMissingFromTheSection() {
        #expect(!HostsFileEditor.isCompliant(withSection(defaultHosts, ["reddit.com"]), blockedHosts: ["reddit.com", "www.reddit.com"]))
    }

    @Test func isCompliantIsFalseWhenTheSectionHasAHostThatIsNoLongerBlocked() {
        #expect(!HostsFileEditor.isCompliant(withSection(defaultHosts, ["reddit.com", "www.reddit.com"]), blockedHosts: ["reddit.com"]))
        #expect(!HostsFileEditor.isCompliant(withSection(defaultHosts, ["reddit.com"]), blockedHosts: []))
    }

    @Test func isCompliantIsFalseWhenABypassLineIsPresent() {
        #expect(!HostsFileEditor.isCompliant("151.101.1.140 reddit.com\n" + withSection(defaultHosts, ["reddit.com"]), blockedHosts: ["reddit.com"]))
        #expect(!HostsFileEditor.isCompliant(defaultHosts + "151.101.1.140 reddit.com\n" + "\n" + section(["reddit.com"]), blockedHosts: ["reddit.com"]))
    }

    @Test func isCompliantIsFalseWhenTheSectionWasHandEdited() {
        let edited = withSection(defaultHosts, ["reddit.com"]).replacingOccurrences(of: ":: reddit.com\n", with: "")
        #expect(!HostsFileEditor.isCompliant(edited, blockedHosts: ["reddit.com"]))
        let renamedMarker = withSection(defaultHosts, ["reddit.com"]).replacingOccurrences(of: begin, with: "# BEGIN SiteBlock (edited)")
        #expect(!HostsFileEditor.isCompliant(renamedMarker, blockedHosts: ["reddit.com"]))
    }

    @Test func isCompliantIsFalseForACRLFFileEvenWhenItsContentIsRight() {
        let crlf = withSection(defaultHosts, ["reddit.com"]).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(!HostsFileEditor.isCompliant(crlf, blockedHosts: ["reddit.com"]))
    }

    @Test func isCompliantIsFalseWhenTheFileHasNoFinalNewline() {
        #expect(!HostsFileEditor.isCompliant("127.0.0.1\tlocalhost", blockedHosts: []))
    }

    // MARK: scale and generated files

    // Public hosts-file ad blocklists run to 100,000 lines. The daemon renders every two seconds, so a quadratic
    // renderer would hang it. The generous limit only catches runaway growth, not slow machines.
    @Test func renderHandlesAFiftyThousandLineFileCorrectlyAndQuickly() {
        var original = defaultHosts
        var expectedUser = defaultHosts
        for i in 0..<50_000 {
            if i % 1000 == 0 {
                original += "10.0.\(i % 250).1 host\(i).example.com reddit.com\n"
                expectedUser += "10.0.\(i % 250).1 host\(i).example.com\n"
            } else {
                let line = "10.0.\(i % 250).1 host\(i).example.com\n"
                original += line
                expectedUser += line
            }
        }
        let hosts = DomainExpander.expand("reddit.com")
        let started = Date()
        let result = HostsFileEditor.render(original: original, blockedHosts: hosts)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == withSection(expectedUser, hosts))
        #expect(elapsed < 20, "render took \(elapsed) seconds")
    }

    // 600 generated files (random markers, bypass lines, comments, blank lines, CRLF or LF) rendered by the real code and by
    // the reference written from the design steps. A disagreement means one of the two misreads the design.
    @Test func renderAgreesWithAnIndependentReferenceOnGeneratedFiles() {
        var rng = SeededGenerator(state: 2026_10_06)
        let blockSets: [[String]] = [[], ["reddit.com"], ["i.redd.it", "reddit.com", "www.reddit.com"], ["other.com", "redd.it"], ["nas.lan"]]
        for round in 0..<600 {
            let original = randomHostsFile(&rng)
            let blocked = blockSets[round % blockSets.count]
            let actual = HostsFileEditor.render(original: original, blockedHosts: blocked)
            let expected = referenceRender(original: original, blocked: blocked)
            #expect(actual == expected, "round \(round): original \(original.debugDescription) blocked \(blocked)")
            #expect(HostsFileEditor.render(original: actual, blockedHosts: blocked) == actual, "round \(round) is not idempotent")
            #expect(HostsFileEditor.isCompliant(actual, blockedHosts: blocked), "round \(round) output is not compliant")
        }
    }
}

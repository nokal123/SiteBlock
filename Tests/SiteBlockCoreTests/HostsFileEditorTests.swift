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

// The three stock lines the Mac needs, with the layout a hand-written file may use (a tab, a tab, and a single space).
private let stockLines = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1 localhost\n"

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

// What the generated files exercised, so a generator that quietly stops producing a case cannot make the cross-check pass vacuously.
private struct ReferenceStats {
    var droppedLines = 0
    var rewrittenLines = 0
    var rewrittenWithComment = 0
    var nulDrops = 0
    var normalizedMatches = 0
    var pairedSections = 0
    var strayEnds = 0
    var orphanBegins = 0
    var supersededBegins = 0
    var droppedHostileEntries = 0
    var droppedSystemNames = 0
}

// Splits UTF-8 bytes into lines on "\n", "\r\n" and a lone "\r" (design step 1 and "Line breaks"). Working on bytes means a
// line break can never hide inside a multi-byte character or behind a combining mark.
private func referenceSplit(_ bytes: [UInt8]) -> [[UInt8]] {
    var lines: [[UInt8]] = [[]]
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x0A {
            lines.append([])
        } else if byte == 0x0D {
            lines.append([])
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
        } else {
            lines[lines.count - 1].append(byte)
        }
        index += 1
    }
    return lines
}

// A line without its leading and trailing ASCII spaces and tabs (the generated files contain no other kind of padding).
private func referenceTrim(_ line: [UInt8]) -> [UInt8] {
    var slice = line[...]
    while let first = slice.first, first == 0x20 || first == 0x09 { slice = slice.dropFirst() }
    while let last = slice.last, last == 0x20 || last == 0x09 { slice = slice.dropLast() }
    return Array(slice)
}

// A name the way the design says it is compared (step 3): ASCII letters lowercased, then one trailing "." removed. Bytes only, so a
// non-ASCII look-alike never matches, and Swift's Unicode-aware String comparison cannot fold anything together.
private func referenceComparable(_ name: [UInt8]) -> [UInt8] {
    var bytes = name
    if bytes.last == 0x2E { bytes.removeLast() }
    return bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
}

// Design step 2, read literally: each END line closes the nearest BEGIN line above it that is not already closed, and only that BEGIN,
// the END and the lines between them are removed. Every BEGIN left unclosed, and every END with no open BEGIN above it, is removed alone.
private func referenceRemoveSections(_ lines: [[UInt8]], stats: inout ReferenceStats) -> [[UInt8]] {
    let beginPrefix = Array("# BEGIN SiteBlock".utf8)
    let endText = Array("# END SiteBlock".utf8)
    func isBegin(_ line: [UInt8]) -> Bool { referenceTrim(line).starts(with: beginPrefix) }
    func isEnd(_ line: [UInt8]) -> Bool { referenceTrim(line) == endText }
    var removed = [Bool](repeating: false, count: lines.count)
    var closed = Set<Int>()
    for index in lines.indices where isEnd(lines[index]) {
        if let begin = (0..<index).last(where: { isBegin(lines[$0]) && !closed.contains($0) }) {
            closed.insert(begin)
            for covered in begin...index { removed[covered] = true }
            stats.pairedSections += 1
        } else {
            removed[index] = true
            stats.strayEnds += 1
        }
    }
    for index in lines.indices where isBegin(lines[index]) && !closed.contains(index) {
        removed[index] = true
        stats.orphanBegins += 1
        if closed.contains(where: { $0 > index }) { stats.supersededBegins += 1 }
    }
    return zip(lines, removed).filter { !$0.1 }.map { $0.0 }
}

// Design step 3, read literally. Returns nil when the line must be dropped, the same line when nothing in it is blocked, otherwise the
// rewritten line. Only the parts of a rewritten line the design pins are rebuilt here: the address, the remaining names, and the
// comment as " #comment". The generator never makes a rewritten line whose layout the design leaves open (extra spaces, tabs or leading
// whitespace between its fields, or text after a NUL), and this function records an issue if it ever does.
private func referenceStripNames(from line: [UInt8], blocked: Set<[UInt8]>, stats: inout ReferenceStats) -> [UInt8]? {
    let trimmed = referenceTrim(line)
    // A blank line or a comment line has no names.
    if trimmed.isEmpty || trimmed.first == 0x23 { return line }
    // The line ends at the first NUL or "#".
    let cut = line.firstIndex(where: { $0 == 0x00 || $0 == 0x23 }) ?? line.count
    let body = Array(line[..<cut])
    let tail = Array(line[cut...])
    // Fields are separated only by ASCII spaces and tabs; the first is the address.
    let fields = body.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 }).map { Array($0) }
    guard fields.count >= 2 else { return line }
    let names = Array(fields.dropFirst())
    let remaining = names.filter { !blocked.contains(referenceComparable($0)) }
    if remaining.count == names.count { return line }
    if names.contains(where: { blocked.contains(referenceComparable($0)) && !blocked.contains($0) }) { stats.normalizedMatches += 1 }
    if remaining.isEmpty {
        stats.droppedLines += 1
        if tail.first == 0x00 { stats.nulDrops += 1 }
        return nil
    }
    var rewritten = fields[0]
    for name in remaining { rewritten += [0x20] + name }
    var compactBody = Array(body)
    while let last = compactBody.last, last == 0x20 || last == 0x09 { compactBody.removeLast() }
    if compactBody != Array(fields.joined(separator: [0x20])) || tail.first == 0x00 {
        Issue.record("the generator made a rewritten line whose layout the design does not pin: \(String(decoding: line, as: UTF8.self).debugDescription)")
    }
    if tail.first == 0x23 {
        rewritten += [0x20] + tail
        stats.rewrittenWithComment += 1
    }
    stats.rewrittenLines += 1
    return rewritten
}

// The bytes the input guard allows in a host name: a-z, 0-9, "-" and ".".
private func referenceIsAllowedHostByte(_ byte: UInt8) -> Bool {
    (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x2E
}

// True when the bytes end with the given text. Written by hand so no String or Foundation suffix test is shared with the library.
private func referenceEndsWith(_ bytes: [UInt8], _ suffix: String) -> Bool {
    let wanted = Array(suffix.utf8)
    return bytes.count >= wanted.count && Array(bytes[(bytes.count - wanted.count)...]) == wanted
}

// The names the Mac itself relies on (design, Input guard): localhost, broadcasthost, and anything ending in .local or .localhost.
private func referenceIsSystemName(_ host: [UInt8]) -> Bool {
    host == Array("localhost".utf8) || host == Array("broadcasthost".utf8) || referenceEndsWith(host, ".local") || referenceEndsWith(host, ".localhost")
}

// The design's input guard, read literally and worked out on UTF-8 bytes: trim each entry, lowercase it, drop it when it is empty, holds a
// byte outside a-z 0-9 - . or is a system name, then remove duplicates. The design says only "trim", so this trims the four ASCII
// whitespace bytes (space, tab, line feed, carriage return); no generated entry has any other whitespace at its edges, so the
// cross-check does not depend on that choice. Lowercasing touches only A-Z, so a non-ASCII look-alike (a Kelvin sign) stays non-ASCII
// and is dropped, and nothing here uses Foundation's trimming or Swift's Unicode lowercasing, so this guard can disagree with the library's.
private func referenceCleanHosts(_ entries: [String], stats: inout ReferenceStats) -> [String] {
    var kept = Set<[UInt8]>()
    for entry in entries {
        var bytes = Array(entry.utf8)
        while let first = bytes.first, [0x20, 0x09, 0x0A, 0x0D].contains(first) { bytes.removeFirst() }
        while let last = bytes.last, [0x20, 0x09, 0x0A, 0x0D].contains(last) { bytes.removeLast() }
        bytes = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        guard !bytes.isEmpty, bytes.allSatisfy(referenceIsAllowedHostByte) else {
            stats.droppedHostileEntries += 1
            continue
        }
        if referenceIsSystemName(bytes) {
            stats.droppedSystemNames += 1
            continue
        }
        kept.insert(bytes)
    }
    return kept.map { String(decoding: $0, as: UTF8.self) }.sorted()
}

// An independent implementation of the whole renderer, written from the design text only: the input guard on blocked hosts, the three
// line-break kinds, steps 2 and 3 as read above, the trailing-empty-line trim, and the appended section. Used to cross-check the real
// renderer on thousands of generated files. It supports the inputs where the design is unambiguous: no whitespace-only lines.
private func referenceRender(original: String, blocked: [String], stats: inout ReferenceStats) -> String {
    // Input guard: trim and lowercase each entry, then drop any entry that is empty, has a character outside a-z 0-9 - . or is a system name.
    let hosts = referenceCleanHosts(blocked, stats: &stats)
    let blockedBytes = Set(hosts.map { Array($0.utf8) })
    let lines = referenceRemoveSections(referenceSplit(Array(original.utf8)), stats: &stats)
    var kept: [[UInt8]] = []
    for line in lines { if let stripped = referenceStripNames(from: line, blocked: blockedBytes, stats: &stats) { kept.append(stripped) } }
    // Step 4: trailing empty lines go, and the text ends with one "\n" unless it is empty.
    while let last = kept.last, last.isEmpty { kept.removeLast() }
    var bytes: [UInt8] = []
    for line in kept { bytes += line + [0x0A] }
    var text = String(decoding: bytes, as: UTF8.self)
    // Step 5: one empty line and the section, when anything is left to block.
    if !hosts.isEmpty { text += "\n" + section(hosts) }
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

// Builds one random hosts file that starts with the stock header and then mixes comments, blank lines, user entries (some naming
// blocked hosts in different cases or with a trailing dot), well-formed and broken managed sections, stray and superseded markers,
// inline comments, NUL bytes, and all three kinds of line break.
private func randomHostsFile(_ rng: inout SeededGenerator) -> String {
    let addresses = ["1.2.3.4", "151.101.1.140", "0.0.0.0", "::", "10.0.0.5"]
    // Case variants, one trailing dot (the same name), two trailing dots (a different name), and look-alikes built from non-ASCII
    // characters: a Kelvin sign is not an ASCII "k", and a combining mark or a no-break space makes a different name.
    let names = ["reddit.com", "www.reddit.com", "other.com", "i.redd.it", "nas.lan", "Reddit.Com", "REDD.IT", "redd.it", "reddit.com.", "REDDIT.COM.", "www.reddit.com.", "reddit.com..", "kick.com", "\u{212A}ick.com", "reddit.com\u{301}", "reddit.com\u{A0}"]
    let comments = ["# some note", "# 1.2.3.4 reddit.com", "#reddit.com", "# reddit.com", "   # indented comment", "\t#reddit.com.", "# END SiteBlock notes", "#BEGIN SiteBlock"]
    let beginLines = [begin, "# BEGIN SiteBlock", "# BEGIN SiteBlock (edited)", "   # BEGIN SiteBlock — x  ", "\t# BEGIN SiteBlock", "# BEGIN SiteBlock entries I added myself"]
    let endLines = [end, "  # END SiteBlock  ", "\t# END SiteBlock"]
    let inlineComments = ["", "", "", " # note", " #reddit.com", "#attached", " # keep"]
    let leads = ["", " ", "\t", " \t "]
    let separators = [" ", "\t", "  ", " \t "]
    let trails = ["", " ", "\t", "\u{0}tail", "\u{0}reddit.com", "\u{0}"]
    var lines = defaultHosts.components(separatedBy: "\n").dropLast().map { $0 }
    for _ in 0..<Int.random(in: 0...16, using: &rng) {
        switch Int.random(in: 0..<16, using: &rng) {
        case 0: lines.append("")
        case 1: lines.append(comments.randomElement(using: &rng)!)
        case 2, 3: lines.append(beginLines.randomElement(using: &rng)!)
        case 4, 5: lines.append(endLines.randomElement(using: &rng)!)
        case 6:
            // One name only, so the line is either dropped or left alone and its odd spacing never has to be rebuilt.
            let trail = trails.randomElement(using: &rng)!
            let comment = trail.contains("\u{0}") ? "" : ["", "#c", " # reddit.com"].randomElement(using: &rng)!
            lines.append(leads.randomElement(using: &rng)! + addresses.randomElement(using: &rng)! + separators.randomElement(using: &rng)! + names.randomElement(using: &rng)! + trail + comment)
        case 7: lines.append(["1.2.3.4", "10.0.0.5 # reddit.com", "  ::  ", "\t0.0.0.0\t#x"].randomElement(using: &rng)!)
        case 8:
            // A blocked name in the address position is not a name on the line, so only the names after it count.
            lines.append(["reddit.com 1.2.3.4", "reddit.com", "www.reddit.com 10.0.0.5 other.com", "REDDIT.COM 1.2.3.4"].randomElement(using: &rng)!)
        default:
            let count = Int.random(in: 1...3, using: &rng)
            let chosen = (0..<count).map { _ in names.randomElement(using: &rng)! }
            lines.append(([addresses.randomElement(using: &rng)!] + chosen).joined(separator: " ") + inlineComments.randomElement(using: &rng)!)
        }
    }
    // Most files use one kind of line break throughout; one join in five switches to a random kind, so mixed files appear too.
    let newlines = ["\n", "\r\n", "\r"]
    let dominant = ["\n", "\n", "\r\n", "\r"].randomElement(using: &rng)!
    var text = ""
    for (index, line) in lines.enumerated() {
        text += line
        if index < lines.count - 1 { text += Int.random(in: 0..<5, using: &rng) == 0 ? newlines.randomElement(using: &rng)! : dominant }
    }
    switch Int.random(in: 0..<3, using: &rng) {
    case 0: text += dominant
    case 1: text += dominant + dominant + dominant
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

    // Design change: 02-core-components.md § HostsFileEditor, render step 2. The old rule said a section starts at a BEGIN line and
    // ends at the next END line, so a second BEGIN inside it was swallowed, and the first BEGIN took every line down to the END with it,
    // including the line "0.0.0.0 zzz.com" below. The design now pairs each END with the NEAREST open BEGIN above it and removes only
    // that BEGIN, the END and the lines between them. Every other BEGIN (here the first one, which the second BEGIN superseded) is
    // removed as a single line. The old assertion expected "0.0.0.0 zzz.com" to be deleted; under the current rule it sits outside
    // any BEGIN/END pair, so it is a user line and must survive (no blocked host names it, so step 3 leaves it too).
    @Test func renderPairsAnEndWithTheNearestBeginAboveItAndDropsTheEarlierBeginAsASingleLine() {
        let original = defaultHosts + begin + "\n0.0.0.0 zzz.com\n" + begin + "\n10.0.0.7 q\n" + end + "\n10.0.0.8 after\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "0.0.0.0 zzz.com\n10.0.0.8 after\n")
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

    // 02-core-components.md § HostsFileEditor, "Comments on rewritten lines": when step 3 removes a name from a user line, the line's trailing
    // comment is kept as " #comment". So the whole rewritten line is pinned here, not only its name list: the address, the names that
    // are left, and the comment (the comment text is " keep", so the line ends in " # keep").
    @Test func renderKeepsTheOtherNamesAndTheInlineCommentOnALineWhenOneNameIsRemoved() {
        let result = HostsFileEditor.render(original: defaultHosts + "1.2.3.4 reddit.com other.com # keep\n", blockedHosts: ["reddit.com"])
        #expect(result == defaultHosts + "1.2.3.4 other.com # keep\n" + "\n" + section(["reddit.com"]))
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

    // 02-core-components.md § HostsFileEditor, render step 5: "append one empty line and the managed section". Step 4 leaves an empty file
    // empty, so the result of rendering "" is that one empty line followed by the section: it starts with "\n# BEGIN" and has no
    // other text in front. The section is there exactly once, and the result is stable.
    @Test func renderOfAnEmptyFileStartsWithTheOneEmptyLineOfStepFiveThenTheSection() {
        let result = HostsFileEditor.render(original: "", blockedHosts: ["a.com"])
        #expect(result == "\n" + section(["a.com"]))
        #expect(result.hasPrefix("\n# BEGIN"))
        #expect(!result.hasPrefix("\n\n"))
        let reddit = HostsFileEditor.render(original: "", blockedHosts: ["reddit.com"])
        #expect(reddit.hasSuffix(section(["reddit.com"])))
        #expect(count(of: "# BEGIN SiteBlock", in: reddit) == 1)
        #expect(HostsFileEditor.render(original: reddit, blockedHosts: ["reddit.com"]) == reddit)
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

    // Design change: the reference renderer used to implement the old step 2 (a section ends at the first END, so a BEGIN inside it was
    // swallowed) and the old step 3 (split on any whitespace, no NUL cut, no trailing-dot rule). It was rewritten from the current
    // 02-core-components.md § HostsFileEditor: step 2 pairs each END with the nearest open BEGIN above it; step 3 ends the line at the
    // first NUL or "#", splits fields only on ASCII space and tab, ASCII-lowercases each name and removes one trailing "."; untouched
    // lines stay byte for byte and a rewritten line keeps " #comment". The input guard (trim, lowercase, drop entries with characters
    // outside a-z 0-9 - . and drop the system names localhost, broadcasthost, .local and .localhost) and the lone "\r" line break are part of
    // the reference too. The guard is written on UTF-8 bytes with its own trimming and lowercasing, so it does not share Foundation's
    // whitespace set with the library and can disagree with it. Against the old reference the real renderer
    // disagreed on 17 of the 600 earlier files, all of them differences that the design change introduced on purpose.
    //
    // 1,500 generated files (random markers, stray and superseded BEGIN lines, bypass lines in several spellings, comments, NUL bytes,
    // blank lines, and all three line-break kinds) rendered by the real code and by the reference. A disagreement means one of the two
    // misreads the design.
    @Test func renderAgreesWithAnIndependentReferenceOnGeneratedFiles() {
        var rng = SeededGenerator(state: 2026_10_06)
        let blockSets: [[String]] = [
            [], ["reddit.com"], ["i.redd.it", "reddit.com", "www.reddit.com"], ["other.com", "redd.it"], ["nas.lan"], ["kick.com"],
            // Dirty entries: padding and upper case are cleaned up, and entries with a newline, space, colon, "#" or nothing at all are dropped.
            // The two newline entries are made only of allowed characters plus the one line break, which is the shape of a real injection.
            [" Reddit.COM ", "evil.com\n0.0.0.0 bank.com", "evil.com\nbank.com", "a b.com", "a:b.com", "x.com#y", ""], ["REDD.IT", "www.reddit.com\t", "other.com\r"],
            // System names the Mac relies on are never blocked, so the stock localhost and broadcasthost lines in every generated file stay.
            ["LOCALHOST", "broadcasthost", "printer.local", "x.localhost", "reddit.com"], ["localhost", " BroadcastHost ", "redd.it", "mac.LOCAL"],
        ]
        var stats = ReferenceStats()
        for round in 0..<1500 {
            let original = randomHostsFile(&rng)
            let blocked = blockSets[round % blockSets.count]
            let actual = HostsFileEditor.render(original: original, blockedHosts: blocked)
            let expected = referenceRender(original: original, blocked: blocked, stats: &stats)
            #expect(actual == expected, "round \(round): original \(original.debugDescription) blocked \(blocked)")
            #expect(HostsFileEditor.render(original: actual, blockedHosts: blocked) == actual, "round \(round) is not idempotent")
            #expect(HostsFileEditor.isCompliant(actual, blockedHosts: blocked), "round \(round) output is not compliant")
        }
        // Guard against a vacuous run: the generator must really have produced each situation the reference is meant to judge.
        #expect(stats.droppedLines > 100, "dropped lines: \(stats.droppedLines)")
        #expect(stats.rewrittenLines > 50, "rewritten lines: \(stats.rewrittenLines)")
        #expect(stats.rewrittenWithComment > 10, "rewritten lines that kept a comment: \(stats.rewrittenWithComment)")
        #expect(stats.nulDrops > 10, "lines dropped by a name that sat before a NUL: \(stats.nulDrops)")
        #expect(stats.normalizedMatches > 50, "lines matched only after lowercasing or removing a trailing dot: \(stats.normalizedMatches)")
        #expect(stats.pairedSections > 200, "paired sections: \(stats.pairedSections)")
        #expect(stats.strayEnds > 50, "stray END lines: \(stats.strayEnds)")
        #expect(stats.orphanBegins > 100, "unclosed BEGIN lines: \(stats.orphanBegins)")
        #expect(stats.supersededBegins > 20, "BEGIN lines superseded by a later BEGIN: \(stats.supersededBegins)")
        #expect(stats.droppedHostileEntries > 500, "block-list entries dropped for their characters: \(stats.droppedHostileEntries)")
        #expect(stats.droppedSystemNames > 500, "block-list entries dropped as system names: \(stats.droppedSystemNames)")
    }
}

// True when the needle's Unicode scalars appear, in order and next to each other, in the text. Swift's own String search works on
// grapheme clusters, so a needle that starts with a combining mark would not be found after a space that it combines with.
private func containsScalars(_ text: String, _ needle: String) -> Bool {
    let haystack = Array(text.unicodeScalars)
    let wanted = Array(needle.unicodeScalars)
    guard !wanted.isEmpty, haystack.count >= wanted.count else { return false }
    return (0...(haystack.count - wanted.count)).contains { start in Array(haystack[start..<(start + wanted.count)]) == wanted }
}

// The text split on "\n" only, which is how the output is written. Splitting by scalars keeps a line break followed by a combining mark intact.
private func outputLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar == "\n" {
            lines.append(String(current))
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty { lines.append(String(current)) }
    return lines
}

// The fields of a line, split only on ASCII space and tab and by Unicode scalars, so a space glued to a combining mark still splits.
private func asciiFields(_ line: String) -> [String] {
    var fields: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in line.unicodeScalars {
        if scalar == " " || scalar == "\t" {
            if !current.isEmpty { fields.append(String(current)) }
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty { fields.append(String(current)) }
    return fields
}

// A line the design allows in the output for a hostile block list: one of the two markers, or "0.0.0.0 h" / ":: h" where h is a
// non-empty lowercase host made only of a-z, 0-9, "-" and ".".
private func isMarkerOrCleanAddressLine(_ line: String) -> Bool {
    if line == begin || line == end { return true }
    let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, parts[0] == "0.0.0.0" || parts[0] == "::" else { return false }
    return !parts[1].isEmpty && parts[1].unicodeScalars.allSatisfy { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "-" || $0 == "." }
}

// Expected values come from 02-core-components.md § HostsFileEditor: the input guard, render step 2 (END pairs with the nearest open
// BEGIN), render step 3 (resolver-style parsing), "Line breaks" and "Comments on rewritten lines".
@Suite struct HostsFileEditorHostileInputTests {
    private static let hostile = ["evil.com\n0.0.0.0 bank.com", "a b.com", "x.com#y", "", "UPPER.com"]

    // "A hostile entry such as evil.com plus a newline and a second host line therefore produces no line at all."
    @Test func managedSectionDropsEveryHostileEntryAndKeepsOnlyTheLowercasedCleanOne() {
        let lines = outputLines(HostsFileEditor.managedSection(for: Self.hostile))
        #expect(lines == [begin, "0.0.0.0 upper.com", ":: upper.com", end])
    }

    @Test func everyLineRenderWritesForAHostileBlockListIsAMarkerOrACleanAddressLine() {
        for original in [defaultHosts, ""] {
            let result = HostsFileEditor.render(original: original, blockedHosts: Self.hostile)
            let written = original.isEmpty ? result : String(result.dropFirst(defaultHosts.count))
            #expect(result.hasPrefix(original))
            for line in outputLines(written) where !line.isEmpty { #expect(isMarkerOrCleanAddressLine(line), "unexpected line \(line.debugDescription)") }
            #expect(containsScalars(result, "0.0.0.0 upper.com\n:: upper.com\n"))
            for forbidden in ["evil.com", "bank.com", "a b.com", "x.com", "UPPER"] { #expect(!containsScalars(result, forbidden), "\(forbidden) leaked into the file") }
        }
        #expect(HostsFileEditor.render(original: defaultHosts, blockedHosts: Self.hostile) == defaultHosts + "\n" + section(["upper.com"]))
    }

    // Each of these alone leaves nothing to write, so the managed section is just the two markers, and render adds no host line. The entries
    // from "a.com\nb.com" to "a.com\u{B}b.com" are built only from allowed characters plus one bad one (a line break of each kind, a colon, an
    // IPv6 address, a next-line character, a paragraph separator, a vertical tab), because that is how a real injection would look: if
    // the guard let any of them through, the entry would write a line (or two) of clean-looking host text.
    @Test(arguments: [
        "evil.com\n0.0.0.0 bank.com", "evil.com\r\n:: bank.com", "a b.com", "a\tb.com", "x.com#y", "", "   ", "a_b.com", "bank.com\u{0}", "x.com\u{2028}y.com", "b\u{FC}cher.de", "*.example.com", "ex/ample.com", "a,b.com",
        "a.com\nb.com", "a.com\rb.com", "a.com\r\nb.com", "a:b.com", "::1", "a.com\u{85}b.com", "a.com\u{2029}b.com", "a.com\u{B}b.com",
    ])
    func aHostileEntryOnItsOwnProducesNoHostLine(entry: String) {
        #expect(outputLines(HostsFileEditor.managedSection(for: [entry])) == [begin, end])
        let result = HostsFileEditor.render(original: defaultHosts, blockedHosts: [entry])
        #expect(result.hasPrefix(defaultHosts))
        for line in outputLines(String(result.dropFirst(defaultHosts.count))) where !line.isEmpty { #expect(isMarkerOrCleanAddressLine(line), "unexpected line \(line.debugDescription) for \(entry.debugDescription)") }
        #expect(!result.contains("0.0.0.0 ") && !result.contains(":: "), "no address line may be written for \(entry.debugDescription)")
    }

    // 02-core-components.md § HostsFileEditor, Input guard: localhost, broadcasthost and names ending in .local or .localhost are never blocked,
    // because step 3 would also delete the stock lines the Mac needs. These entries are made only of allowed characters, so only the
    // system-name rule can drop them. Each one alone leaves nothing to write: no address line may appear, and the stock lines stay.
    // Whether render still writes an empty BEGIN/END section when the guard drops every entry is not specified, so both are accepted.
    @Test(arguments: ["localhost", "broadcasthost", "printer.local", "x.localhost", "LOCALHOST", " Localhost ", "BroadcastHost", "PRINTER.LOCAL", "a.b.localhost", "mac.local"])
    func aSystemNameOnItsOwnProducesNoHostLineAndLeavesTheStockLines(entry: String) {
        #expect(outputLines(HostsFileEditor.managedSection(for: [entry])) == [begin, end], "\(entry.debugDescription)")
        let result = HostsFileEditor.render(original: stockLines, blockedHosts: [entry])
        #expect(result == stockLines || result == stockLines + "\n" + section([]), "\(entry.debugDescription): \(result.debugDescription)")
        #expect(!result.contains("0.0.0.0 ") && !result.contains(":: "), "no address line may be written for \(entry.debugDescription)")
        #expect(HostsFileEditor.render(original: result, blockedHosts: [entry]) == result)
    }

    // The stock lines survive a block list that mixes system names with a real site, and the real site is still written. Without the system-name
    // rule step 3 would delete all three lines.
    @Test func theStockLocalhostAndBroadcasthostLinesSurviveABlockListThatNamesThem() {
        let blocked = ["localhost", "broadcasthost", "LOCALHOST", "printer.local", "x.localhost", "reddit.com"]
        #expect(HostsFileEditor.render(original: stockLines, blockedHosts: blocked) == stockLines + "\n" + section(["reddit.com"]))
        #expect(outputLines(HostsFileEditor.managedSection(for: blocked)) == [begin, "0.0.0.0 reddit.com", ":: reddit.com", end])
        #expect(HostsFileEditor.render(original: defaultHosts, blockedHosts: blocked) == defaultHosts + "\n" + section(["reddit.com"]))
        // The same stock lines with their original layout (tabs, and a run of spaces) are kept byte for byte, and CRLF input is no different.
        let crlf = stockLines.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(HostsFileEditor.render(original: crlf, blockedHosts: blocked) == stockLines + "\n" + section(["reddit.com"]))
    }

    // A user's own line for a system name is not touched either: the name is never in the block list, so step 3 has nothing to remove.
    @Test func aUsersOwnLineForASystemNameIsKept() {
        let original = stockLines + "10.0.0.5 printer.local localhost.lan\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["printer.local", "reddit.com"]) == original + "\n" + section(["reddit.com"]))
    }

    // Only the exact name localhost and broadcasthost, and a name that ENDS in .local or .localhost, are system names. A name that merely
    // contains or starts with them is an ordinary host, and the guard must still write it.
    @Test func namesThatOnlyResembleSystemNamesAreStillWritten() {
        let blocked = ["localhost.com", "xlocalhost", "broadcasthost.net", "x.local.com", "mylocal.com", "xlocal", "x.localhost.org", "notbroadcasthost", "local-host.com"]
        #expect(HostsFileEditor.render(original: stockLines, blockedHosts: blocked) == stockLines + "\n" + section(blocked))
        #expect(outputLines(HostsFileEditor.managedSection(for: blocked)) == [begin] + blocked.sorted().flatMap { ["0.0.0.0 \($0)", ":: \($0)"] } + [end])
    }

    // The guard trims and lowercases first, then judges what is left.
    @Test func theGuardTrimsAndLowercasesBeforeJudgingAnEntry() {
        #expect(outputLines(HostsFileEditor.managedSection(for: [" \tPadded.COM  ", "Mixed-Case.Org"])) == [begin, "0.0.0.0 mixed-case.org", ":: mixed-case.org", "0.0.0.0 padded.com", ":: padded.com", end])
    }

    // The whole chain: a hostile name typed by a user is refused by the engine, so it never reaches the block list or the file.
    @Test func anAddOfAHostileNameIsRejectedAndTheBlockedHostsStayCleanAllTheWayToTheHostsFile() {
        let engine = makeEngine(blocking: ["reddit.com"])
        for input in ["evil.com\n0.0.0.0 bank.com", "evil.com\r\n:: bank.com", "a b.com", "evil.com 0.0.0.0 bank.com"] { expectFailure(engine.send(.add, domain: input), .invalidDomain) }
        #expect(engine.state.blocked.map(\.domain) == ["reddit.com"])
        #expect(engine.blockedHosts == DomainExpander.expand("reddit.com"))
        for host in engine.blockedHosts { #expect(host.unicodeScalars.allSatisfy { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "-" || $0 == "." }, "\(host.debugDescription) is not clean") }
        let rendered = HostsFileEditor.render(original: defaultHosts, blockedHosts: engine.blockedHosts)
        #expect(rendered == defaultHosts + "\n" + section(DomainExpander.expand("reddit.com")))
        #expect(!rendered.contains("bank.com") && !rendered.contains("evil.com"))
    }
}

@Suite struct HostsFileEditorParsingTests {
    // MARK: step 2, pairing

    // 02-core-components.md step 2: a comment the user wrote, "# BEGIN SiteBlock entries I added myself", far above the real section
    // starts an open BEGIN that the real section's BEGIN supersedes. It costs that one line and never the user's entries below it.
    @Test func aStrayBeginCommentFarAboveTheRealSectionLosesOnlyItsOwnLine() {
        var userLines = ""
        for index in 0..<30 { userLines += "10.0.\(index).1 host\(index).lan\n" }
        let original = defaultHosts + "# BEGIN SiteBlock entries I added myself\n" + userLines + "\n" + section(["reddit.com"])
        #expect(HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"]) == defaultHosts + userLines + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + userLines)
    }

    @Test func nestedBeginsAreAllClosedByTheEndsThatFollowThemInnerFirst() {
        let original = defaultHosts + begin + "\n10.0.0.1 x\n" + begin + "\n10.0.0.2 y\n" + end + "\n10.0.0.3 z\n" + end + "\n10.0.0.4 after\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.4 after\n")
    }

    @Test func anEndClosesOnlyTheNearestOpenBeginSoTheLinesBetweenAnEarlierBeginAndItStay() {
        let original = defaultHosts + "# BEGIN SiteBlock mine\n10.0.0.1 keep-a\n" + begin + "\n0.0.0.0 old.com\n" + end + "\n10.0.0.2 keep-b\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.1 keep-a\n10.0.0.2 keep-b\n")
    }

    @Test func aSecondEndAfterAClosedSectionIsAStrayEndAndOnlyItsOwnLineGoes() {
        let original = defaultHosts + begin + "\n10.0.0.1 inside\n" + end + "\n10.0.0.2 between\n" + end + "\n10.0.0.3 after\n"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == defaultHosts + "10.0.0.2 between\n10.0.0.3 after\n")
    }

    // MARK: step 3, reading a line the way the resolver does

    @Test func aBlockedNameWithATrailingDotIsRemovedFromTheLine() {
        #expect(HostsFileEditor.render(original: defaultHosts + "151.101.1.141 reddit.com.\n", blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "151.101.1.141 REDDIT.COM.\n", blockedHosts: ["reddit.com"]) == withSection(defaultHosts, ["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 other.net reddit.com. other.org\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.net other.org\n" + "\n" + section(["reddit.com"]))
    }

    // Only one trailing dot is removed, so "reddit.com.." is a different name that the resolver would not match with the block.
    @Test func aNameWithTwoTrailingDotsIsNotTheBlockedName() {
        let line = "1.2.3.4 reddit.com..\n"
        #expect(HostsFileEditor.render(original: defaultHosts + line, blockedHosts: ["reddit.com"]) == defaultHosts + line + "\n" + section(["reddit.com"]))
    }

    // The resolver stops reading the line at a NUL byte, so a blocked name in front of one is on the line and a name behind one is not.
    @Test func aBlockedNameBeforeANulByteIsRemovedAndTheTextAfterTheNulIsNeverSearched() {
        #expect(HostsFileEditor.render(original: defaultHosts + "151.101.1.142 www.reddit.com\u{0}x\n", blockedHosts: ["www.reddit.com"]) == withSection(defaultHosts, ["www.reddit.com"]))
        let hidden = "1.2.3.4 other.com\u{0}reddit.com\n"
        #expect(HostsFileEditor.render(original: defaultHosts + hidden, blockedHosts: ["reddit.com"]) == defaultHosts + hidden + "\n" + section(["reddit.com"]))
    }

    // "when step 3 removes a name from a user line, the line's trailing comment (if any) is kept as ' #comment'."
    @Test func aRewrittenLineKeepsItsTrailingComment() {
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 other.net reddit.com. # keep\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.net # keep\n" + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 reddit.com other.net#keep\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.net #keep\n" + "\n" + section(["reddit.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 other.net reddit.com#keep\n", blockedHosts: ["reddit.com"]) == defaultHosts + "1.2.3.4 other.net #keep\n" + "\n" + section(["reddit.com"]))
    }

    // A space followed by a combining mark is one Swift Character, so a parser that splits on Characters would not see the space.
    // Fields are split on the ASCII space itself, so "\u{301}reddit.com" is its own field and is not the blocked name.
    @Test func aCombiningMarkAfterASeparatorKeepsTheLineStableOnASecondRender() {
        let original = defaultHosts + "x\twww.reddit.com \u{301}reddit.com\n"
        let blocked = ["reddit.com", "www.reddit.com"]
        let once = HostsFileEditor.render(original: original, blockedHosts: blocked)
        #expect(HostsFileEditor.render(original: once, blockedHosts: blocked) == once)
        #expect(HostsFileEditor.isCompliant(once, blockedHosts: blocked))
        // The user's line keeps its address and the name that is not blocked, and loses the blocked name. Fields are read by ASCII space and tab only.
        let userLines = outputLines(once).filter { $0.unicodeScalars.contains("\u{301}") }
        #expect(userLines.count == 1, "expected exactly one user line with the combining mark: \(once.debugDescription)")
        #expect(asciiFields(userLines.first ?? "") == ["x", "\u{301}reddit.com"])
    }

    // Fields are separated only by ASCII spaces and tabs. These characters look like separators, but to the resolver they are part of
    // a name, so the lines hold no blocked name and stay byte for byte.
    @Test(arguments: ["1.2.3.4\u{A0}reddit.com", "1.2.3.4 \u{B}reddit.com", "1.2.3.4 other.com\u{C}reddit.com", "1.2.3.4 reddit.com\u{3000}", "1.2.3.4\u{2003}reddit.com", "1.2.3.4 reddit.com\u{85}other.com"])
    func charactersThatOnlyLookLikeSeparatorsDoNotSplitAName(line: String) {
        #expect(HostsFileEditor.render(original: defaultHosts + line + "\n", blockedHosts: ["reddit.com"]) == defaultHosts + line + "\n" + "\n" + section(["reddit.com"]))
    }

    // A blocked name in the address position is the address, not a name, so the line is left alone.
    @Test func aBlockedNameInTheAddressFieldIsNotAName() {
        let line = "reddit.com 1.2.3.4\n"
        #expect(HostsFileEditor.render(original: defaultHosts + line, blockedHosts: ["reddit.com"]) == defaultHosts + line + "\n" + section(["reddit.com"]))
    }

    // A Kelvin sign (U+212A) is not an ASCII "k", and only ASCII letters are lowercased, so it is not the blocked name "kick.com".
    @Test func onlyAsciiLettersAreLowercasedWhenNamesAreCompared() {
        let lookalike = "1.2.3.4 \u{212A}ick.com\n"
        #expect(HostsFileEditor.render(original: defaultHosts + lookalike, blockedHosts: ["kick.com"]) == defaultHosts + lookalike + "\n" + section(["kick.com"]))
        #expect(HostsFileEditor.render(original: defaultHosts + "1.2.3.4 KICK.com\n", blockedHosts: ["kick.com"]) == withSection(defaultHosts, ["kick.com"]))
    }

    // MARK: line breaks

    // "\n, \r\n and a lone \r all count as line breaks on input. Output always uses \n."
    @Test func aLoneCarriageReturnIsALineBreakOnInputAndTheOutputUsesLineFeeds() {
        let original = "127.0.0.1\tlocalhost\r1.2.3.4 reddit.com other.com\r10.0.0.1 a\r"
        let result = HostsFileEditor.render(original: original, blockedHosts: ["reddit.com"])
        #expect(result == "127.0.0.1\tlocalhost\n1.2.3.4 other.com\n10.0.0.1 a\n" + "\n" + section(["reddit.com"]))
        #expect(!result.unicodeScalars.contains("\r"))
        #expect(HostsFileEditor.render(original: result, blockedHosts: ["reddit.com"]) == result)
    }

    @Test func aSectionWhoseLinesAreSeparatedByLoneCarriageReturnsIsRecognizedAndRemoved() {
        let original = "x\r" + begin + "\r0.0.0.0 reddit.com\r" + end + "\ry\r"
        #expect(HostsFileEditor.render(original: original, blockedHosts: []) == "x\ny\n")
    }

    // A "\r" followed by a "\n" is one break ("\r\n"), but "\n\r" and "\r\r" are two, so those keep a blank line between the user's lines.
    @Test func carriageReturnAndLineFeedPairsCountAsOneBreakInThatOrderOnly() {
        #expect(HostsFileEditor.render(original: "a\r\nb\n", blockedHosts: []) == "a\nb\n")
        #expect(HostsFileEditor.render(original: "a\n\rb\n", blockedHosts: []) == "a\n\nb\n")
        #expect(HostsFileEditor.render(original: "a\r\rb\n", blockedHosts: []) == "a\n\nb\n")
    }
}

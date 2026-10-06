import Foundation

/// Computes the correct text of a hosts file from its current text and the set of host names that must be blocked. It works only on strings, so it needs no file access and can be tested on any input.
public enum HostsFileEditor {
    /// The first line of the managed section.
    public static let beginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted"
    /// The last line of the managed section.
    public static let endMarker = "# END SiteBlock"

    /// True when the line opens a managed section: its trimmed text starts with "# BEGIN SiteBlock", so trailing spaces and a hand-edited comment after the BEGIN text are tolerated. The comparison is on Unicode scalars, so a combining mark glued onto a letter is never silently folded into the match.
    private static func isBeginLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.starts(with: "# BEGIN SiteBlock".unicodeScalars)
    }

    /// True when the line closes a managed section: its trimmed text is exactly "# END SiteBlock".
    private static func isEndLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.elementsEqual("# END SiteBlock".unicodeScalars)
    }

    /// True for a line that is empty or only whitespace.
    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Trims and lowercases each host, keeps only entries made entirely of a-z, 0-9, "-" and ".", then sorts and drops duplicates. Blocked hosts are reloaded from state.json, so this allowlist is the last gate before text reaches root's hosts file: an entry carrying a newline, "#", a space or anything else can never inject an extra line.
    private static func cleanHosts(_ hosts: [String]) -> [String] {
        let usable = hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { host in
            !host.isEmpty && host.unicodeScalars.allSatisfy { allowedHostScalars.contains($0) }
        }
        return Array(Set(usable)).sorted()
    }

    /// The only characters a host name may contain when it is written to the hosts file.
    private static let allowedHostScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")

    /// Returns the managed section: the BEGIN line, then two lines (IPv4 and IPv6) per host in sorted order, then the END line, each line ending in a newline.
    public static func managedSection(for blockedHosts: [String]) -> String {
        var lines = [beginMarker]
        for host in cleanHosts(blockedHosts) {
            lines.append("0.0.0.0 \(host)")
            lines.append(":: \(host)")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Builds a String from Unicode scalars exactly as given, with no normalization, so text taken out of a line and put back keeps the original scalars.
    private static func string(from scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Splits text into lines on "\n", "\r\n" and a lone "\r". It walks the Unicode scalars, because Swift's string search can treat a line break followed by a combining mark as one unit and miss it. The result always has at least one entry, and text ending in a line break gives a final empty entry.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                // The "\n" of a "\r\n" pair was already counted when the "\r" ended the line.
                if !previousWasCarriageReturn {
                    lines.append(String(current))
                    current = String.UnicodeScalarView()
                }
                previousWasCarriageReturn = false
            } else if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCarriageReturn = true
            } else {
                current.append(scalar)
                previousWasCarriageReturn = false
            }
        }
        lines.append(String(current))
        return lines
    }

    /// Removes every managed section from the lines. Each END line closes the nearest BEGIN line above it that is still open, and that BEGIN, the END and every line between them are removed. A BEGIN that no END closes, and an END with no open BEGIN, are removed as single lines. This keeps a comment the user wrote, such as "# BEGIN SiteBlock entries I added myself", from taking the user's own lines with it.
    private static func removingManagedSections(from lines: [String]) -> [String] {
        var openBegins: [Int] = []
        // A difference array marks every removed range in one pass: +1 where a range starts and -1 just after it ends, so nested and overlapping ranges cost nothing extra.
        var delta = [Int](repeating: 0, count: lines.count + 1)
        for (index, line) in lines.enumerated() {
            if isBeginLine(line) {
                openBegins.append(index)
            } else if isEndLine(line) {
                if let begin = openBegins.popLast() {
                    delta[begin] += 1
                    delta[index + 1] -= 1
                } else {
                    delta[index] += 1
                    delta[index + 1] -= 1
                }
            }
        }
        // Whatever is still open at the end never got an END, so only its own line goes.
        for begin in openBegins {
            delta[begin] += 1
            delta[begin + 1] -= 1
        }
        var kept: [String] = []
        var depth = 0
        for index in lines.indices {
            depth += delta[index]
            if depth == 0 { kept.append(lines[index]) }
        }
        return kept
    }

    /// The bytes a host name is compared as: ASCII letters lowercased, one trailing "." removed, nothing else changed. Comparing bytes means a non-ASCII look-alike character can never match a blocked name.
    private static func comparisonBytes(of name: ArraySlice<Unicode.Scalar>) -> [UInt8] {
        var scalars = Array(name)
        if scalars.last == "." { scalars.removeLast() }
        let lowered = scalars.map { scalar -> Unicode.Scalar in
            scalar.value >= 0x41 && scalar.value <= 0x5A ? Unicode.Scalar(scalar.value + 0x20)! : scalar
        }
        return Array(string(from: lowered).utf8)
    }

    /// Removes the blocked names from one hosts line; returns the line unchanged when no name was removed, or nil when no names are left and the line should be dropped. It reads the line the way the macOS resolver does: the line ends at the first NUL or "#", and fields are separated only by ASCII spaces and tabs. A line with no blocked name is returned byte for byte as it came in.
    private static func removingBlockedNames(from line: String, blocked: Set<[UInt8]>) -> String? {
        if blocked.isEmpty { return line }
        let scalars = Array(line.unicodeScalars)
        // Everything from the first NUL or "#" onward is invisible to the resolver, so it is never searched for names.
        let cut = scalars.firstIndex(where: { $0 == "\u{0}" || $0 == "#" }) ?? scalars.count
        let cutIsHash = cut < scalars.count && scalars[cut] == "#"
        var fields: [ArraySlice<Unicode.Scalar>] = []
        var fieldStart: Int?
        for index in 0..<cut {
            if scalars[index] == " " || scalars[index] == "\t" {
                if let start = fieldStart {
                    fields.append(scalars[start..<index])
                    fieldStart = nil
                }
            } else if fieldStart == nil {
                fieldStart = index
            }
        }
        if let start = fieldStart { fields.append(scalars[start..<cut]) }
        // The first field is the address, so a line needs at least one name after it.
        guard fields.count >= 2 else { return line }
        let names = Array(fields.dropFirst())
        let remaining = names.filter { !blocked.contains(comparisonBytes(of: $0)) }
        if remaining.count == names.count { return line }
        if remaining.isEmpty { return nil }
        var rewritten = string(from: fields[0]) + " " + remaining.map { string(from: $0) }.joined(separator: " ")
        // A "#" comment is kept as " #comment". Text after a NUL is dead data the resolver never reads, so it is dropped rather than kept next to the rewritten names.
        if cutIsHash { rewritten += " " + string(from: scalars[cut...]) }
        return rewritten
    }

    /// Returns the corrected hosts file text: every managed section removed, blocked names stripped from the user's own lines, and one fresh managed section appended when there is anything to block.
    public static func render(original: String, blockedHosts: [String]) -> String {
        let hosts = cleanHosts(blockedHosts)
        let blocked = Set(hosts.map { Array($0.utf8) })

        // Step 1: split into lines, accepting \n and \r\n.
        // A lone \r is also treated as a line break. Left alone it would glue onto the following \n in the output, and the next render would then read it as \r\n and change the text, breaking idempotence.
        let lines = splitLines(original)

        // Step 2: remove every managed section, pairing each END with the nearest open BEGIN above it.
        var kept = removingManagedSections(from: lines)

        // Step 3: strip blocked names from the user's remaining lines, because macOS uses the first matching line and a hand-added "1.2.3.4 reddit.com" would otherwise win.
        kept = kept.compactMap { removingBlockedNames(from: $0, blocked: blocked) }

        // Step 4: drop trailing empty lines, then end the text with exactly one newline.
        while let last = kept.last, isBlank(last) { kept.removeLast() }
        var text = kept.joined(separator: "\n")
        if !kept.isEmpty { text += "\n" }

        // Step 5: append one empty line and the managed section when there is anything to block.
        if !hosts.isEmpty { text += "\n" + managedSection(for: hosts) }
        return text
    }

    /// True when the text is already exactly what render would produce, so nothing needs rewriting.
    public static func isCompliant(_ text: String, blockedHosts: [String]) -> Bool {
        render(original: text, blockedHosts: blockedHosts) == text
    }
}

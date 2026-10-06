import Foundation

/// Computes the correct text of a hosts file from its current text and the set of host names that must be blocked. It works only on strings, so it needs no file access and can be tested on any input.
public enum HostsFileEditor {
    /// The first line of the managed section.
    public static let beginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted"
    /// The last line of the managed section.
    public static let endMarker = "# END SiteBlock"

    /// True when the line starts the managed section; trailing spaces and a hand-edited comment after the BEGIN text are tolerated.
    private static func isBeginLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# BEGIN SiteBlock")
    }

    /// True when the line ends the managed section.
    private static func isEndLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "# END SiteBlock"
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

    /// Removes the blocked names from one hosts line; returns the line unchanged when no name was removed, or nil when no names are left and the line should be dropped.
    private static func removingBlockedNames(from line: String, blocked: Set<String>) -> String? {
        // Comment lines and blank lines carry no host names.
        if blocked.isEmpty || isBlank(line) || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return line }
        var content = line
        var comment: String?
        if let hash = line.firstIndex(of: "#") {
            content = String(line[..<hash])
            comment = String(line[hash...])
        }
        // Any whitespace separates fields, so a stray carriage return cannot glue itself onto a name and hide it from the match.
        let fields = content.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 2 else { return line }
        let names = Array(fields.dropFirst())
        let remaining = names.filter { !blocked.contains($0.lowercased()) }
        // Untouched lines keep the user's own spacing.
        if remaining.count == names.count { return line }
        if remaining.isEmpty { return nil }
        return fields[0] + " " + remaining.joined(separator: " ") + (comment.map { " " + $0 } ?? "")
    }

    /// Returns the corrected hosts file text: every managed section removed, blocked names stripped from the user's own lines, and one fresh managed section appended when there is anything to block.
    public static func render(original: String, blockedHosts: [String]) -> String {
        let hosts = cleanHosts(blockedHosts)
        let blocked = Set(hosts.map { $0.lowercased() })

        // Step 1: split into lines, accepting both \n and \r\n.
        // A lone \r is also treated as a line break. Left alone it would glue onto the following \n in the output, and the next render would then read it as \r\n and change the text, breaking idempotence.
        let lines = original.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")

        // Step 2: remove every managed section.
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBeginLine(line) {
                // A BEGIN with no END after it removes only the BEGIN line itself; deleting to the end of the file could destroy the user's own entries.
                if let end = lines[(index + 1)...].firstIndex(where: { isEndLine($0) }) { index = end + 1 } else { index += 1 }
                continue
            }
            // A stray END line with no BEGIN is removed.
            if isEndLine(line) {
                index += 1
                continue
            }
            kept.append(line)
            index += 1
        }

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

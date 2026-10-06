import Foundation

/// The reasons a typed site name cannot be blocked; each case carries a plain sentence a person can read.
public enum DomainError: Error, LocalizedError, Equatable {
    case empty
    case ipAddress
    case invalidCharacters
    case labelTooLong
    case tooLong
    case needsDot
    case reserved

    /// The sentence shown to the user for this problem.
    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter a site name like example.com."
        case .ipAddress: return "IP addresses can't be blocked through the hosts file. Enter a site name like example.com."
        case .invalidCharacters: return "That isn't a valid site name. Use only letters, digits, hyphens and dots, like example.com."
        case .labelTooLong: return "Each part of a site name (between the dots) can be at most 63 characters long."
        case .tooLong: return "A site name can be at most 253 characters long."
        case .needsDot: return "Enter a full site name with a dot in it, like example.com."
        case .reserved: return "Names like localhost and .local are used by the Mac itself, so they can't be blocked."
        }
    }
}

/// Turns whatever the user typed (a bare name, a full URL, a name with a port or path) into one canonical lowercase base domain.
public enum DomainNormalizer {
    // Characters that end the host part of a URL: the start of the path, the query or the fragment.
    private static let hostEnders: Set<Unicode.Scalar> = ["/", "?", "#"]

    /// Returns the canonical base domain for the input, or throws a DomainError explaining why it cannot be blocked.
    public static func normalize(_ input: String) throws -> String {
        // Step 1: trim whitespace.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw DomainError.empty }
        // All text surgery below works on Unicode scalars, because Swift Characters can glue a combining mark onto a "/" or "." and hide it from comparisons.
        var scalars = Array(trimmed.unicodeScalars)

        // Step 2: drop a leading "scheme://", then cut at the first "/", "?" or "#".
        // The "://" only counts as a scheme when it comes before any "/", "?" or "#", so "reddit.com/r?u=http://x.com" stays reddit.com instead of becoming x.com.
        if let at = indexOfScheme(in: scalars), !scalars[..<at].contains(where: { hostEnders.contains($0) }) { scalars = Array(scalars[(at + 3)...]) }
        if let cut = scalars.firstIndex(where: { hostEnders.contains($0) }) { scalars = Array(scalars[..<cut]) }

        // Step 3: drop a "user:pass@" prefix (everything up to and including the last "@").
        if let at = scalars.lastIndex(of: "@") { scalars = Array(scalars[(at + 1)...]) }

        // Step 4: reject IPv6 literals and drop a ":port" suffix.
        if scalars.first == "[" { throw DomainError.ipAddress }
        let colonCount = scalars.filter { $0 == ":" }.count
        // More than one colon cannot be a name plus a port, so it is a bare IPv6 address.
        if colonCount > 1 { throw DomainError.ipAddress }
        if colonCount == 1, let colon = scalars.firstIndex(of: ":") {
            // A port must be digits only (or empty); anything else is not a site name.
            guard scalars[(colon + 1)...].allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { throw DomainError.invalidCharacters }
            scalars = Array(scalars[..<colon])
        }

        // Step 5: lowercase and remove one trailing dot.
        var host = makeString(scalars).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { throw DomainError.empty }

        // Step 6: convert every label that has non-ASCII characters to its xn-- form.
        var labels = host.components(separatedBy: ".")
        for index in labels.indices {
            let label = labels[index]
            if label.unicodeScalars.allSatisfy({ $0.isASCII }) { continue }
            // Reject invisible or space-like characters before encoding, because Punycode would turn them into a valid-looking label.
            if label.unicodeScalars.contains(where: { isForbiddenNonASCII($0) }) { throw DomainError.invalidCharacters }
            guard let ascii = Punycode.toASCII(label: label) else { throw DomainError.invalidCharacters }
            labels[index] = ascii
        }
        var ascii = labels.joined(separator: ".")

        // Step 7: strip one leading "www." so www.reddit.com and reddit.com are the same site (the expander adds www. back).
        if ascii.hasPrefix("www.") { ascii.removeFirst(4) }

        // Step 8: validate the final ASCII name.
        if ascii.isEmpty { throw DomainError.empty }
        if ascii.utf8.count > 253 { throw DomainError.tooLong }
        // The reserved check comes before the dot check so a bare "localhost" is reported as reserved rather than as missing a dot.
        if ascii == "localhost" || ascii.hasSuffix(".local") || ascii.hasSuffix(".localhost") { throw DomainError.reserved }
        let finalLabels = ascii.components(separatedBy: ".")
        if finalLabels.count < 2 { throw DomainError.needsDot }
        for label in finalLabels {
            if label.isEmpty { throw DomainError.invalidCharacters }
            if label.utf8.count > 63 { throw DomainError.labelTooLong }
            if !label.utf8.allSatisfy({ isAllowedLabelByte($0) }) { throw DomainError.invalidCharacters }
            if label.hasPrefix("-") || label.hasSuffix("-") { throw DomainError.invalidCharacters }
        }
        // A last label made only of digits means the input was an IPv4 address such as 1.2.3.4.
        if let last = finalLabels.last, last.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { throw DomainError.ipAddress }
        return ascii
    }

    /// Finds where "://" starts in the scalars, or nil when it is absent.
    private static func indexOfScheme(in scalars: [Unicode.Scalar]) -> Int? {
        guard scalars.count >= 3 else { return nil }
        for i in 0...(scalars.count - 3) where scalars[i] == ":" && scalars[i + 1] == "/" && scalars[i + 2] == "/" { return i }
        return nil
    }

    /// Builds a String back from a list of Unicode scalars.
    private static func makeString(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// True for a byte that may appear inside a final label: a-z, 0-9 or a hyphen.
    private static func isAllowedLabelByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
    }

    /// True for a non-ASCII character that can never be part of a site name: controls, invisible formatting marks, spaces, separators, private-use and unassigned code points.
    private static func isForbiddenNonASCII(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }
}

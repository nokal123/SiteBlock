import Foundation

/// The reasons the path part of a typed rule cannot be used; each case carries a plain sentence a person can read.
public enum PathRuleError: Error, LocalizedError, Equatable {
    /// The text names a site but no path under it (or the path is only slashes and stars), so it is a whole-site block, not a path rule.
    case noPath
    /// The path is longer than 256 characters.
    case tooLong
    /// The path contains a character that is not allowed, such as a space, a star in the middle, or a letter outside plain ASCII.
    case invalidCharacters

    /// The sentence shown to the user for this problem.
    public var errorDescription: String? {
        switch self {
        case .noPath: return "Type the part of the site to block after its name, like youtube.com/shorts. A site name alone blocks the whole site."
        case .tooLong: return "The part of the address after the site name can be at most 256 characters long."
        case .invalidCharacters: return "That part of the address has a character SiteBlock can't use. Use only letters, digits and - . _ ~ / % ! $ & ' ( ) + , ; = : @, with no spaces."
        }
    }
}

/// Turns typed text such as `youtube.com/shorts` or `https://www.youtube.com/shorts/abc?x=1` into a path rule (a site plus the start of a path under it), or says the text has no path (so it is a whole-site block), or explains why it cannot be used. It also builds the entries that go into each browser's block list.
public enum PathRuleParser {
    /// The longest path a rule may have, counting the leading slash.
    public static let maxPathLength = 256

    /// The characters other than ASCII letters and digits that a path may contain.
    private static let allowedPathPunctuation: Set<Unicode.Scalar> = ["-", ".", "_", "~", "/", "%", "!", "$", "&", "'", "(", ")", "+", ",", ";", "=", ":", "@"]

    /// Splits typed text into its host part and its path. The text is trimmed; a leading `scheme://`, a `user@` prefix and a `:port` suffix are dropped from the host; everything from the first `?` or `#` on is cut off; and the path is everything from the first `/` that remains. The path is nil when there is none, or when it is only `/`, because that means "the whole site". The host is returned as typed (not lowercased or checked); `parse` does the checking.
    public static func split(_ input: String) -> (host: String, path: String?) {
        // Like DomainNormalizer, this works on Unicode scalars, because a Swift Character can glue a combining mark onto a "/" and hide it from comparisons.
        var scalars = Array(input.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)

        // A "://" is a scheme separator only when it comes before any "/", "?" or "#", so "youtube.com/watch?u=http://x.com" keeps its own host.
        if let at = indexOfScheme(in: scalars), indexOfHostEnder(in: scalars).map({ $0 >= at }) ?? true { scalars = Array(scalars[(at + 3)...]) }

        let hostEnd = indexOfHostEnder(in: scalars) ?? scalars.count
        var host = Array(scalars[..<hostEnd])

        // A path starts only at a "/". If the host is ended by "?" or "#" instead, the rest is a query or fragment and there is no path.
        var path: String?
        if hostEnd < scalars.count, scalars[hostEnd] == "/" {
            var pathEnd = hostEnd
            while pathEnd < scalars.count, scalars[pathEnd] != "?", scalars[pathEnd] != "#" { pathEnd += 1 }
            // A lone "/" is the whole site, not a path.
            if pathEnd - hostEnd > 1 { path = makeString(scalars[hostEnd..<pathEnd]) }
        }

        // Drop "user:pass@" (everything up to the last "@" in the host part). An "@" inside the path, such as /@MrBeast, is not in the host part and stays.
        if let at = host.lastIndex(of: "@") { host = Array(host[(at + 1)...]) }

        // Drop a ":port" only when it is exactly one colon followed by digits. Anything else (an IPv6 address, a port with letters) is left for DomainNormalizer to refuse.
        let colons = host.indices.filter { host[$0] == ":" }
        if colons.count == 1, host.first != "[", host[(colons[0] + 1)...].allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) { host = Array(host[..<colons[0]]) }

        return (makeString(host[...]), path)
    }

    /// Reads typed text as a path rule: the normalized base domain (all of DomainNormalizer's rules apply, so `www.` is stripped and the name is lowercased) and the path. The path keeps its case, because paths are case-sensitive. Trailing `*` characters and then trailing `/` characters are removed, so `/shorts/` and `/shorts*` both become `/shorts`. Text with no path throws `PathRuleError.noPath`; a path over 256 characters throws `.tooLong`; a path with any character outside letters, digits and `- . _ ~ / % ! $ & ' ( ) + , ; = : @` (a space, a star left in the middle, a quote, a bracket, a letter outside ASCII) throws `.invalidCharacters`.
    public static func parse(_ input: String) throws -> (domain: String, path: String) {
        // The host is checked first, so a typo in the site name reports the site name problem. DomainNormalizer cuts the text at the first "/", "?" or "#" itself, so it sees only the host part.
        let domain = try DomainNormalizer.normalize(input)
        guard let rawPath = split(input).path else { throw PathRuleError.noPath }

        var scalars = Array(rawPath.unicodeScalars)
        // Stars come off first and slashes second, so "/shorts/*" becomes "/shorts/" and then "/shorts".
        while scalars.last == "*" { scalars.removeLast() }
        while scalars.last == "/" { scalars.removeLast() }
        // Nothing is left for a text such as "/", "//" or "/*": that is the whole site again.
        if scalars.isEmpty { throw PathRuleError.noPath }
        if scalars.count > maxPathLength { throw PathRuleError.tooLong }
        // Any star still in the path is in the middle, and anything outside the allowed set (spaces included) cannot be written safely into a browser's block list.
        guard scalars.allSatisfy({ isAllowedPathScalar($0) }) else { throw PathRuleError.invalidCharacters }
        return (domain, makeString(scalars[...]))
    }

    /// The rule as people read it, for example `youtube.com/shorts`.
    public static func display(domain: String, path: String) -> String {
        domain + path
    }

    /// The entry for the Chrome, Edge and Brave `URLBlocklist`. Chrome's format matches the domain, its subdomains and any address whose path starts with the given one, so the entry is the rule as people read it.
    public static func chromeEntry(domain: String, path: String) -> String {
        domain + path
    }

    /// The entry for Firefox's `WebsiteFilter`: a match pattern (Firefox's address-pattern format) for any scheme, the domain and its subdomains, and any path that starts with the given one.
    public static func firefoxPattern(domain: String, path: String) -> String {
        "*://*." + domain + path + "*"
    }

    /// True for an ASCII letter or digit, or one of the allowed punctuation characters.
    private static func isAllowedPathScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39) { return true }
        return allowedPathPunctuation.contains(scalar)
    }

    /// Finds where "://" starts in the scalars, or nil when it is absent.
    private static func indexOfScheme(in scalars: [Unicode.Scalar]) -> Int? {
        var i = 0
        while i + 2 < scalars.count {
            if scalars[i] == ":" && scalars[i + 1] == "/" && scalars[i + 2] == "/" { return i }
            i += 1
        }
        return nil
    }

    /// Finds the first "/", "?" or "#" in the scalars, or nil when there is none.
    private static func indexOfHostEnder(in scalars: [Unicode.Scalar]) -> Int? {
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "/" || scalar == "?" || scalar == "#" { return i }
            i += 1
        }
        return nil
    }

    /// Builds a String back from a run of Unicode scalars, exactly as given.
    private static func makeString(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

using System.Text;

namespace SiteBlock.Core;

/// <summary>
/// One path rule as the service reports it: a site plus the start of a path under it, such as youtube.com and /shorts.
/// The tab watcher compares browser tab addresses against a list of these.
/// </summary>
/// <param name="Domain">The site name, already normalized the way the service stores it: lowercase, Punycode for non-ASCII letters, no leading <c>www.</c>, for example <c>youtube.com</c>.</param>
/// <param name="Path">The start of the path, beginning with <c>/</c>, in its original case and without a trailing <c>/</c> or <c>*</c>, for example <c>/shorts</c>.</param>
public readonly record struct WatchedPathRule(string Domain, string Path);

/// <summary>
/// Decides whether the address of an open browser tab falls under a path rule. The steps mirror what Chrome's <c>youtube.com/shorts</c> entry and Firefox's <c>*://*.youtube.com/shorts*</c> pattern match, so the tab watcher reloads only tabs that the browser will then block.
/// The address is parsed by hand, following the RFC 3986 layout the Swift version gets from <c>URLComponents</c>: .NET's <c>Uri</c> lowercases hosts, re-escapes paths and refuses some addresses <c>URLComponents</c> accepts, so it would give different answers.
/// </summary>
public static class TabRuleMatcher
{
    /// <summary>The two parts of a tab address that a rule is compared with: the host normalized with DomainNormalizer, and the percent-encoded path (<c>/</c> when the address has none).</summary>
    private readonly record struct Address(string Host, string Path);

    /// <summary>Returns the first rule, in list order, that the address falls under, or null when it falls under none (or is not an ordinary web address). It never throws.</summary>
    public static WatchedPathRule? MatchingRule(string url, IEnumerable<WatchedPathRule> rules)
    {
        ArgumentNullException.ThrowIfNull(rules);
        // The address is read once and then compared with every rule, because reading it is the costly part.
        if (AddressFrom(url) is not Address address) return null;
        foreach (WatchedPathRule rule in rules)
        {
            if (Matches(address, rule)) return rule;
        }
        return null;
    }

    /// <summary>True when the address is an http or https address on the rule's site (or one of its subdomains) whose path starts with the rule's path. It never throws.</summary>
    public static bool Matches(string url, WatchedPathRule rule)
    {
        if (AddressFrom(url) is not Address address) return false;
        return Matches(address, rule);
    }

    /// <summary>Compares an already-read address with one rule.</summary>
    private static bool Matches(Address address, WatchedPathRule rule)
    {
        if (rule.Domain is null || rule.Path is null) return false;
        // The host must be the rule's site or a subdomain of it. The dot in front of the rule's name makes "notyoutube.com" fail while "m.youtube.com" passes.
        if (!(address.Host == rule.Domain || address.Host.EndsWith("." + rule.Domain, StringComparison.Ordinal))) return false;
        // A plain, case-sensitive prefix test, which is what the browsers do: "/shorts", "/shorts/abc" and "/shortsXYZ" all start with "/shorts", but "/Shorts" does not.
        // The address path is ASCII after encoding, so an ordinal prefix test gives the same answer as the Swift byte comparison.
        return address.Path.StartsWith(rule.Path, StringComparison.Ordinal);
    }

    /// <summary>
    /// Reads the host and path out of a tab address, or returns null when the address cannot be a blockable web page: it does not parse, its scheme is not http or https, or its host is missing, odd, or not a valid site name (an IP address, for example).
    /// Port, user info, query and fragment play no part in the decision.
    /// </summary>
    private static Address? AddressFrom(string? url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        // The scheme is the text before the first ":", and only counts when no "/", "?" or "#" comes before that ":".
        int colon = url.IndexOf(':');
        if (colon <= 0) return null;
        int firstEnder = url.IndexOfAny(['/', '?', '#']);
        if (firstEnder >= 0 && firstEnder < colon) return null;
        // Only web pages can be blocked by the browser's block list; chrome:, about:, file:, data: and javascript: addresses are left alone.
        string scheme = url[..colon];
        if (!IsWebScheme(scheme)) return null;

        // An address without "//" after the scheme has no host, so it cannot be a site.
        if (url.Length < colon + 3 || url[colon + 1] != '/' || url[colon + 2] != '/') return null;
        int authorityStart = colon + 3;
        int authorityEnd = url.IndexOfAny(['/', '?', '#'], authorityStart);
        if (authorityEnd < 0) authorityEnd = url.Length;
        string authority = url[authorityStart..authorityEnd];

        // The user info is everything up to the last "@" and is not the host, so "https://youtube.com@other.com/shorts" is judged by other.com.
        int at = authority.LastIndexOf('@');
        string hostAndPort = at >= 0 ? authority[(at + 1)..] : authority;
        // A bracketed IP literal holds ":" and brackets, which no site name can hold.
        if (hostAndPort.StartsWith('[')) return null;
        int portColon = hostAndPort.IndexOf(':');
        string rawHost = portColon >= 0 ? hostAndPort[..portColon] : hostAndPort;
        if (portColon >= 0)
        {
            // A port that is not all digits makes the address unparseable, as URLComponents refuses it.
            foreach (char c in hostAndPort.AsSpan(portColon + 1))
            {
                if (c is < '0' or > '9') return null;
            }
        }

        // The host is compared after percent-escapes are turned back into characters, as URLComponents.host does.
        string? host = PercentDecode(rawHost);
        if (string.IsNullOrEmpty(host) || HasUnsafeHostCharacter(host)) return null;
        // The same normalizer the rules went through, so both sides use one spelling. A host it refuses (an IP address, a bad label) cannot match any rule.
        string normalized;
        try
        {
            normalized = DomainNormalizer.Normalize(host);
        }
        catch (DomainException)
        {
            return null;
        }

        string path = "";
        if (authorityEnd < url.Length && url[authorityEnd] == '/')
        {
            int pathEnd = url.IndexOfAny(['?', '#'], authorityEnd);
            if (pathEnd < 0) pathEnd = url.Length;
            path = PercentEncodePath(url[authorityEnd..pathEnd]);
        }
        return new Address(normalized, path.Length == 0 ? "/" : path);
    }

    /// <summary>True when the scheme, compared without regard to ASCII letter case, is http or https.</summary>
    private static bool IsWebScheme(string scheme)
    {
        foreach (char c in scheme)
        {
            if (c >= 0x80) return false;
        }
        string lowered = scheme.ToLowerInvariant();
        return lowered is "http" or "https";
    }

    /// <summary>
    /// True when the host holds a character that cannot be in a real host name: one of <c>/ ? # @ : \ [ ]</c>, whitespace or a line break, or a control or invisible format character.
    /// Percent-escapes were already turned back into characters, so "youtube.com%2Fx.evil.com" arrives as "youtube.com/x.evil.com"; refusing these hosts keeps such an address from matching a site it does not belong to.
    /// </summary>
    private static bool HasUnsafeHostCharacter(string host)
    {
        foreach (int scalar in SwiftText.Scalars(host))
        {
            if (scalar is '/' or '?' or '#' or '@' or ':' or '\\' or '[' or ']') return true;
            if (SwiftText.IsFoundationWhitespace(scalar) || SwiftText.IsFoundationControl(scalar)) return true;
        }
        return false;
    }

    /// <summary>Turns every <c>%XX</c> escape back into its byte and reads the result as UTF-8. A <c>%</c> not followed by two hex digits stays as it is. Returns null when the bytes are not valid UTF-8, as URLComponents then reports no host.</summary>
    private static string? PercentDecode(string text)
    {
        if (!text.Contains('%', StringComparison.Ordinal)) return text;
        byte[] raw = Encoding.UTF8.GetBytes(text);
        var bytes = new List<byte>(raw.Length);
        for (int i = 0; i < raw.Length; i++)
        {
            if (raw[i] == '%' && i + 2 < raw.Length && IsHex(raw[i + 1]) && IsHex(raw[i + 2]))
            {
                bytes.Add((byte)((HexValue(raw[i + 1]) << 4) | HexValue(raw[i + 2])));
                i += 2;
            }
            else
            {
                bytes.Add(raw[i]);
            }
        }
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes.ToArray());
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>
    /// Writes the path the way URLComponents.percentEncodedPath reports it: every byte that may not appear in a path (anything other than letters, digits, <c>- . _ ~ ! $ &amp; ' ( ) * + , ; = : @ /</c> and a valid <c>%XX</c> escape) becomes <c>%XX</c> with uppercase hex.
    /// So a raw space becomes <c>%20</c>, as browsers report it, and an address that is already encoded is left exactly as it is.
    /// </summary>
    private static string PercentEncodePath(string path)
    {
        byte[] raw = Encoding.UTF8.GetBytes(path);
        var builder = new StringBuilder(raw.Length);
        for (int i = 0; i < raw.Length; i++)
        {
            byte b = raw[i];
            if (b == '%' && i + 2 < raw.Length && IsHex(raw[i + 1]) && IsHex(raw[i + 2]))
            {
                builder.Append('%').Append((char)raw[i + 1]).Append((char)raw[i + 2]);
                i += 2;
            }
            else if (IsPathByte(b))
            {
                builder.Append((char)b);
            }
            else
            {
                builder.Append('%').Append(b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture));
            }
        }
        return builder.ToString();
    }

    /// <summary>True for a byte RFC 3986 allows in a path as it is: an unreserved character, a sub-delimiter, ":", "@" or "/".</summary>
    private static bool IsPathByte(byte b) =>
        b is (>= (byte)'a' and <= (byte)'z') or (>= (byte)'A' and <= (byte)'Z') or (>= (byte)'0' and <= (byte)'9')
            or (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~'
            or (byte)'!' or (byte)'$' or (byte)'&' or (byte)'\'' or (byte)'(' or (byte)')' or (byte)'*' or (byte)'+' or (byte)',' or (byte)';' or (byte)'='
            or (byte)':' or (byte)'@' or (byte)'/';

    /// <summary>True for an ASCII hex digit in either case.</summary>
    private static bool IsHex(byte b) => b is (>= (byte)'0' and <= (byte)'9') or (>= (byte)'a' and <= (byte)'f') or (>= (byte)'A' and <= (byte)'F');

    /// <summary>The value 0-15 of an ASCII hex digit.</summary>
    private static int HexValue(byte b) => b <= '9' ? b - '0' : (b | 0x20) - 'a' + 10;
}

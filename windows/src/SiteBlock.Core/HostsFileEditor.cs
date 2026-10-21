using System.Text;

namespace SiteBlock.Core;

/// <summary>
/// Computes the correct text of a hosts file from its current text and the set of host names that must be blocked.
/// It works only on strings, so it needs no file access and can be tested on any input.
/// </summary>
public static class HostsFileEditor
{
    /// <summary>The first line of the managed section.</summary>
    public const string BeginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted";
    /// <summary>The last line of the managed section.</summary>
    public const string EndMarker = "# END SiteBlock";

    /// <summary>True when the line opens a managed section: its trimmed text starts with "# BEGIN SiteBlock", so trailing spaces and a hand-edited comment after the BEGIN text are tolerated.</summary>
    private static bool IsBeginLine(string line) => SwiftText.Trim(line).StartsWith("# BEGIN SiteBlock", StringComparison.Ordinal);

    /// <summary>True when the line closes a managed section: its trimmed text is exactly "# END SiteBlock".</summary>
    private static bool IsEndLine(string line) => string.Equals(SwiftText.Trim(line), "# END SiteBlock", StringComparison.Ordinal);

    /// <summary>True for a line that is empty or only whitespace.</summary>
    private static bool IsBlank(string line) => SwiftText.Trim(line).Length == 0;

    /// <summary>
    /// Trims and lowercases each host, keeps only entries made entirely of a-z, 0-9, "-" and ".", drops names the system itself relies on, then sorts and drops duplicates.
    /// Blocked hosts are reloaded from state.json, so this allowlist is the last gate before text reaches the hosts file: an entry carrying a newline, "#", a space or anything else can never inject an extra line.
    /// </summary>
    private static List<string> CleanHosts(IEnumerable<string> hosts)
    {
        var usable = new HashSet<string>(StringComparer.Ordinal);
        foreach (string? entry in hosts)
        {
            if (entry is null) continue;
            string host = SwiftText.Lowercased(SwiftText.Trim(entry));
            if (host.Length > 0 && host.All(IsAllowedHostChar) && !IsSystemName(host)) usable.Add(host);
        }
        var sorted = usable.ToList();
        sorted.Sort(StringComparer.Ordinal);
        return sorted;
    }

    /// <summary>True for localhost, broadcasthost and names ending in .local or .localhost. Blocking one of these would also make step 3 delete the stock "127.0.0.1 localhost" style lines the system needs, so they are never written even if a forged state file lists them.</summary>
    private static bool IsSystemName(string host) =>
        host == "localhost" || host == "broadcasthost" || host.EndsWith(".local", StringComparison.Ordinal) || host.EndsWith(".localhost", StringComparison.Ordinal);

    /// <summary>True for the only characters a host name may contain when it is written to the hosts file.</summary>
    private static bool IsAllowedHostChar(char c) => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-' or '.';

    /// <summary>Returns the managed section: the BEGIN line, then two lines (IPv4 and IPv6) per host in sorted order, then the END line, each line ending in a newline.</summary>
    public static string ManagedSection(IEnumerable<string> blockedHosts)
    {
        ArgumentNullException.ThrowIfNull(blockedHosts);
        var lines = new List<string> { BeginMarker };
        foreach (string host in CleanHosts(blockedHosts))
        {
            lines.Add($"0.0.0.0 {host}");
            lines.Add($":: {host}");
        }
        lines.Add(EndMarker);
        return string.Join('\n', lines) + "\n";
    }

    /// <summary>Splits text into lines on "\n", "\r\n" and a lone "\r". The result always has at least one entry, and text ending in a line break gives a final empty entry.</summary>
    private static List<string> SplitLines(string text)
    {
        var lines = new List<string>();
        var current = new StringBuilder();
        bool previousWasCarriageReturn = false;
        foreach (char c in text)
        {
            if (c == '\n')
            {
                // The "\n" of a "\r\n" pair was already counted when the "\r" ended the line.
                if (!previousWasCarriageReturn)
                {
                    lines.Add(current.ToString());
                    current.Clear();
                }
                previousWasCarriageReturn = false;
            }
            else if (c == '\r')
            {
                lines.Add(current.ToString());
                current.Clear();
                previousWasCarriageReturn = true;
            }
            else
            {
                current.Append(c);
                previousWasCarriageReturn = false;
            }
        }
        lines.Add(current.ToString());
        return lines;
    }

    /// <summary>
    /// Removes every managed section from the lines. Each END line closes the nearest BEGIN line above it that is still open, and that BEGIN, the END and every line between them are removed.
    /// A BEGIN that no END closes, and an END with no open BEGIN, are removed as single lines. This keeps a comment the user wrote, such as "# BEGIN SiteBlock entries I added myself", from taking the user's own lines with it.
    /// </summary>
    private static List<string> RemovingManagedSections(List<string> lines)
    {
        var openBegins = new Stack<int>();
        // A difference array marks every removed range in one pass: +1 where a range starts and -1 just after it ends, so nested and overlapping ranges cost nothing extra.
        var delta = new int[lines.Count + 1];
        for (int index = 0; index < lines.Count; index++)
        {
            string line = lines[index];
            if (IsBeginLine(line))
            {
                openBegins.Push(index);
            }
            else if (IsEndLine(line))
            {
                if (openBegins.TryPop(out int begin))
                {
                    delta[begin] += 1;
                    delta[index + 1] -= 1;
                }
                else
                {
                    delta[index] += 1;
                    delta[index + 1] -= 1;
                }
            }
        }
        // Whatever is still open at the end never got an END, so only its own line goes.
        foreach (int begin in openBegins)
        {
            delta[begin] += 1;
            delta[begin + 1] -= 1;
        }
        var kept = new List<string>();
        int depth = 0;
        for (int index = 0; index < lines.Count; index++)
        {
            depth += delta[index];
            if (depth == 0) kept.Add(lines[index]);
        }
        return kept;
    }

    /// <summary>The form a host name is compared in: ASCII letters lowercased, one trailing "." removed, nothing else changed, so a non-ASCII look-alike character can never match a blocked name.</summary>
    private static string ComparisonForm(string name)
    {
        if (name.EndsWith('.')) name = name[..^1];
        var builder = new StringBuilder(name.Length);
        foreach (char c in name) builder.Append(c is >= 'A' and <= 'Z' ? (char)(c + 0x20) : c);
        return builder.ToString();
    }

    /// <summary>
    /// Removes the blocked names from one hosts line; returns the line unchanged when no name was removed, or null when no names are left and the line should be dropped.
    /// It reads the line the way the resolver does: the line ends at the first NUL or "#", and fields are separated only by ASCII spaces and tabs. A line with no blocked name is returned exactly as it came in.
    /// </summary>
    private static string? RemovingBlockedNames(string line, HashSet<string> blocked)
    {
        if (blocked.Count == 0) return line;
        // Everything from the first NUL or "#" onward is invisible to the resolver, so it is never searched for names.
        int cut = line.IndexOfAny(['\0', '#']);
        if (cut < 0) cut = line.Length;
        bool cutIsHash = cut < line.Length && line[cut] == '#';
        var fields = new List<string>();
        int fieldStart = -1;
        for (int index = 0; index < cut; index++)
        {
            if (line[index] is ' ' or '\t')
            {
                if (fieldStart >= 0)
                {
                    fields.Add(line[fieldStart..index]);
                    fieldStart = -1;
                }
            }
            else if (fieldStart < 0)
            {
                fieldStart = index;
            }
        }
        if (fieldStart >= 0) fields.Add(line[fieldStart..cut]);
        // The first field is the address, so a line needs at least one name after it.
        if (fields.Count < 2) return line;
        var names = fields.Skip(1).ToList();
        var remaining = names.Where(name => !blocked.Contains(ComparisonForm(name))).ToList();
        if (remaining.Count == names.Count) return line;
        if (remaining.Count == 0) return null;
        string rewritten = fields[0] + " " + string.Join(' ', remaining);
        // A "#" comment is kept as " #comment". Text after a NUL is dead data the resolver never reads, so it is dropped rather than kept next to the rewritten names.
        if (cutIsHash) rewritten += " " + line[cut..];
        return rewritten;
    }

    /// <summary>Returns the corrected hosts file text: every managed section removed, blocked names stripped from the user's own lines, and one fresh managed section appended when there is anything to block.</summary>
    public static string Render(string original, IEnumerable<string> blockedHosts)
    {
        ArgumentNullException.ThrowIfNull(original);
        ArgumentNullException.ThrowIfNull(blockedHosts);
        List<string> hosts = CleanHosts(blockedHosts);
        var blocked = new HashSet<string>(hosts, StringComparer.Ordinal);

        // Step 1: split into lines, accepting \n and \r\n.
        // A lone \r is also treated as a line break. Left alone it would glue onto the following \n in the output, and the next render would then read it as \r\n and change the text, breaking idempotence.
        List<string> lines = SplitLines(original);

        // Step 2: remove every managed section, pairing each END with the nearest open BEGIN above it.
        List<string> kept = RemovingManagedSections(lines);

        // Step 3: strip blocked names from the user's remaining lines, because the resolver uses the first matching line and a hand-added "1.2.3.4 reddit.com" would otherwise win.
        kept = kept.Select(line => RemovingBlockedNames(line, blocked)).OfType<string>().ToList();

        // Step 4: drop trailing empty lines, then end the text with exactly one newline.
        while (kept.Count > 0 && IsBlank(kept[^1])) kept.RemoveAt(kept.Count - 1);
        string text = string.Join('\n', kept);
        if (kept.Count > 0) text += "\n";

        // Step 5: append one empty line and the managed section when there is anything to block.
        if (hosts.Count > 0) text += "\n" + ManagedSection(hosts);
        return text;
    }

    /// <summary>True when the text is already exactly what <see cref="Render"/> would produce, so nothing needs rewriting.</summary>
    public static bool IsCompliant(string text, IEnumerable<string> blockedHosts) => Render(text, blockedHosts) == text;
}

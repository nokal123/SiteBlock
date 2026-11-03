using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace SiteBlock.Core;

/// <summary>
/// One setting in a Local Group Policy file (<c>Registry.pol</c>): a registry key under HKEY_LOCAL_MACHINE, a value name, the value's registry type and its raw bytes.
/// Two entries are equal when the key and the name match without regard to letter case, as the registry compares them, and the type and the bytes match exactly.
/// </summary>
public sealed class PolEntry(string key, string name, uint type, byte[] data) : IEquatable<PolEntry>
{
    /// <summary>The registry type of text (REG_SZ).</summary>
    public const uint RegSz = 1;
    /// <summary>The registry type of a 32-bit number (REG_DWORD).</summary>
    public const uint RegDword = 4;
    /// <summary>The special value name that makes Group Policy delete every value in the key before it writes the entries that follow.</summary>
    public const string DeleteAllValues = "**delvals.";

    /// <summary>The key, for example <c>SOFTWARE\Policies\Google\Chrome\URLBlocklist</c>.</summary>
    public string Key { get; } = key;
    /// <summary>The value name, for example <c>1</c> or <c>DnsOverHttpsMode</c>.</summary>
    public string Name { get; } = name;
    /// <summary>The registry type, for example <see cref="RegSz"/>.</summary>
    public uint Type { get; } = type;
    /// <summary>The value's bytes as the file stores them: UTF-16 text with its closing zero for REG_SZ, four little-endian bytes for REG_DWORD.</summary>
    public byte[] Data { get; } = data;

    /// <summary>A text entry (REG_SZ).</summary>
    public static PolEntry Text(string key, string name, string text) => new(key, name, RegSz, Encoding.Unicode.GetBytes(text + "\0"));

    /// <summary>A number entry (REG_DWORD).</summary>
    public static PolEntry Number(string key, string name, int number) => new(key, name, RegDword, BitConverter.GetBytes(number));

    /// <summary>True when both entries name the same key and value (ignoring letter case) and hold the same type and bytes.</summary>
    public bool Equals(PolEntry? other) => other is not null && string.Equals(Key, other.Key, StringComparison.OrdinalIgnoreCase)
        && string.Equals(Name, other.Name, StringComparison.OrdinalIgnoreCase) && Type == other.Type && Data.AsSpan().SequenceEqual(other.Data);

    /// <summary>Equality with any object, through <see cref="Equals(PolEntry?)"/>.</summary>
    public override bool Equals(object? obj) => Equals(obj as PolEntry);

    /// <summary>A hash that agrees with <see cref="Equals(PolEntry?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Key.ToUpperInvariant(), Name.ToUpperInvariant(), Type, Data.Length);

    /// <summary>A short readable form for test failures: key, name and type, without the data.</summary>
    public override string ToString() => $"{Key}\\{Name} (type {Type}, {Data.Length} bytes)";
}

/// <summary>Thrown when a <c>Registry.pol</c> file does not follow the format, so it is left alone rather than rewritten.</summary>
public sealed class PolFormatException(string message) : Exception(message);

/// <summary>
/// Reads and writes the <c>Registry.pol</c> format: the four bytes <c>PReg</c>, the version number 1, and then one entry after another, each written as
/// <c>[key;name;type;size;data]</c> with the brackets, semicolons, key and name in UTF-16 (key and name each end with a zero character), and type and size as 32-bit little-endian numbers.
/// </summary>
public static class RegistryPol
{
    private static readonly byte[] Signature = "PReg"u8.ToArray();
    private const uint FormatVersion = 1;
    // An entry larger than this cannot be real policy and means the file is damaged; it also keeps a bad size from asking for gigabytes.
    private const uint MaxDataBytes = 1 << 20;

    /// <summary>The entries of the file in their order. An empty file, or one holding only the header, has none. Throws <see cref="PolFormatException"/> for anything that breaks the format.</summary>
    public static List<PolEntry> Parse(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        var entries = new List<PolEntry>();
        if (bytes.Length == 0) return entries;
        if (bytes.Length < 8 || !bytes.AsSpan(0, 4).SequenceEqual(Signature)) throw new PolFormatException("The file does not start with PReg.");
        if (BitConverter.ToUInt32(bytes, 4) != FormatVersion) throw new PolFormatException("The file has an unknown format version.");
        int at = 8;
        while (at < bytes.Length)
        {
            ExpectChar(bytes, ref at, '[');
            string key = ReadString(bytes, ref at);
            ExpectChar(bytes, ref at, ';');
            string name = ReadString(bytes, ref at);
            ExpectChar(bytes, ref at, ';');
            uint type = ReadUInt(bytes, ref at);
            ExpectChar(bytes, ref at, ';');
            uint size = ReadUInt(bytes, ref at);
            ExpectChar(bytes, ref at, ';');
            if (size > MaxDataBytes || at + size > bytes.Length) throw new PolFormatException("An entry's data runs past the end of the file.");
            byte[] data = bytes.AsSpan(at, (int)size).ToArray();
            at += (int)size;
            ExpectChar(bytes, ref at, ']');
            entries.Add(new PolEntry(key, name, type, data));
        }
        return entries;
    }

    /// <summary>The bytes of a file holding the entries in order, header included.</summary>
    public static byte[] Serialize(IEnumerable<PolEntry> entries)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write(Signature);
        writer.Write(FormatVersion);
        foreach (PolEntry entry in entries)
        {
            writer.Write(Encoding.Unicode.GetBytes("[" + entry.Key + "\0;" + entry.Name + "\0;"));
            writer.Write(entry.Type);
            writer.Write(Encoding.Unicode.GetBytes(";"));
            writer.Write((uint)entry.Data.Length);
            writer.Write(Encoding.Unicode.GetBytes(";"));
            writer.Write(entry.Data);
            writer.Write(Encoding.Unicode.GetBytes("]"));
        }
        writer.Flush();
        return stream.ToArray();
    }

    /// <summary>Reads one UTF-16 character and throws unless it is the expected one.</summary>
    private static void ExpectChar(byte[] bytes, ref int at, char expected)
    {
        if (at + 2 > bytes.Length || BitConverter.ToChar(bytes, at) != expected) throw new PolFormatException($"Expected '{expected}' at byte {at}.");
        at += 2;
    }

    /// <summary>Reads UTF-16 characters up to and including the closing zero character, and returns them without it.</summary>
    private static string ReadString(byte[] bytes, ref int at)
    {
        int start = at;
        while (at + 2 <= bytes.Length)
        {
            if (bytes[at] == 0 && bytes[at + 1] == 0)
            {
                string text = Encoding.Unicode.GetString(bytes, start, at - start);
                at += 2;
                return text;
            }
            at += 2;
        }
        throw new PolFormatException("A key or value name has no closing zero character.");
    }

    /// <summary>Reads a 32-bit little-endian number.</summary>
    private static uint ReadUInt(byte[] bytes, ref int at)
    {
        if (at + 4 > bytes.Length) throw new PolFormatException("The file ends inside a number.");
        uint value = BitConverter.ToUInt32(bytes, at);
        at += 4;
        return value;
    }
}

/// <summary>
/// The pure rules for SiteBlock's part of the computer's Local Group Policy. When the block lists are also in <c>Registry.pol</c>, Windows itself applies them and then signals every program that asked to hear
/// about policy changes, which is the only signal Chrome, Edge and Brave act on while they run (06-windows.md § BrowserPolicyEnforcer). SiteBlock owns exactly the entries for the values and list subkeys
/// <see cref="WindowsBrowserPolicy"/> owns; every other entry in the file is kept as it is and where it is.
/// </summary>
public static partial class LocalGroupPolicy
{
    /// <summary>The Group Policy part that applies <c>Registry.pol</c> (the registry extension) and the editor part that writes it (Administrative Templates), as gpt.ini names them.</summary>
    public const string RegistryExtension = "{35378EAC-683F-11D2-A89A-00C04FBBCFA2}";
    /// <summary>The editor part paired with <see cref="RegistryExtension"/> in gpt.ini.</summary>
    public const string AdministrativeTemplatesTool = "{D02B1F72-3407-48AE-BA88-E8213C6761F1}";

    /// <summary>True when SiteBlock owns the entry: it sits in one of SiteBlock's list subkeys, or it names (or deletes, with <c>**del.</c>) one of SiteBlock's values.</summary>
    public static bool IsOwned(PolEntry entry, IEnumerable<RegistryPolicy> policies) => new Ownership(policies).Owns(entry);

    /// <summary>SiteBlock's keys, built once from the policies so each entry is checked with lookups, ignoring letter case as the registry does.</summary>
    private sealed class Ownership
    {
        // The full key paths of SiteBlock's list subkeys; every entry in them is SiteBlock's.
        private readonly HashSet<string> _listKeys = new(StringComparer.OrdinalIgnoreCase);
        // For each key that holds SiteBlock's named values, the names SiteBlock owns there.
        private readonly Dictionary<string, HashSet<string>> _valueNames = new(StringComparer.OrdinalIgnoreCase);

        /// <summary>Collects the owned list keys and value names of every policy.</summary>
        public Ownership(IEnumerable<RegistryPolicy> policies)
        {
            foreach (RegistryPolicy policy in policies)
            {
                foreach (string list in policy.OwnedListSubkeys) _listKeys.Add(policy.KeyFor(list));
                foreach (var (subkey, names) in policy.OwnedValueNames)
                {
                    string key = policy.KeyFor(subkey);
                    if (!_valueNames.TryGetValue(key, out var owned)) _valueNames[key] = owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    owned.UnionWith(names);
                }
            }
        }

        /// <summary>True when the entry is in an owned list key, or names one of the owned values, directly or through <c>**del.</c>.</summary>
        public bool Owns(PolEntry entry)
        {
            if (_listKeys.Contains(entry.Key)) return true;
            if (!_valueNames.TryGetValue(entry.Key, out var names)) return false;
            string name = entry.Name.StartsWith("**del.", StringComparison.OrdinalIgnoreCase) ? entry.Name["**del.".Length..] : entry.Name;
            return names.Contains(name);
        }
    }

    /// <summary>
    /// The entries SiteBlock wants, in a fixed order: for each policy, its named values (subkeys and names in ordinal order), then each list as a <see cref="PolEntry.DeleteAllValues"/> entry followed by
    /// the values <c>1</c>, <c>2</c>, <c>3</c> … The delete-all entry makes Windows clear the list before writing it, so an entry dropped from the list is dropped from the registry too.
    /// </summary>
    public static List<PolEntry> Wanted(IEnumerable<RegistryPolicy> policies)
    {
        var entries = new List<PolEntry>();
        foreach (RegistryPolicy policy in policies)
        {
            foreach (var (subkey, values) in policy.Values.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                string key = policy.KeyFor(subkey);
                foreach (var (name, value) in values.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                {
                    entries.Add(value.Kind == RegValueKind.DWord ? PolEntry.Number(key, name, value.Number ?? 0) : PolEntry.Text(key, name, value.Text ?? ""));
                }
            }
            foreach (var (subkey, list) in policy.Lists.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                string key = policy.KeyFor(subkey);
                // The editor writes a single space as the delete-all entry's text, and so does SiteBlock.
                entries.Add(PolEntry.Text(key, PolEntry.DeleteAllValues, " "));
                for (int i = 0; i < list.Count; i++) entries.Add(PolEntry.Text(key, (i + 1).ToString(CultureInfo.InvariantCulture), list[i]));
            }
        }
        return entries;
    }

    /// <summary>
    /// The file's entries with SiteBlock's part made right, or null when they already are. SiteBlock's part is right when the entries it owns, read in file order, are exactly <see cref="Wanted"/>.
    /// Otherwise every owned entry is removed, the other entries keep their order, and the wanted entries are added at the end.
    /// </summary>
    public static List<PolEntry>? Merged(IReadOnlyList<PolEntry> existing, IReadOnlyList<RegistryPolicy> policies)
    {
        var ownership = new Ownership(policies);
        var owned = new List<PolEntry>();
        var others = new List<PolEntry>();
        foreach (PolEntry entry in existing) (ownership.Owns(entry) ? owned : others).Add(entry);
        List<PolEntry> wanted = Wanted(policies);
        if (owned.SequenceEqual(wanted)) return null;
        return [.. others, .. wanted];
    }

    /// <summary>
    /// The text of gpt.ini after a change to the computer's policy file: the computer half of <c>Version</c> (its low 16 bits) goes up by one, skipping 0, while the user half is kept; and
    /// <c>gPCMachineExtensionNames</c> lists the registry extension with the Administrative Templates tool, so Windows knows the file holds registry settings. Every other line is kept.
    /// A missing or empty file gives a new one, and a file without a <c>[General]</c> section gets one at the top.
    /// </summary>
    public static string UpdatedGptIni(string? text)
    {
        var lines = (text ?? "").Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').ToList();
        if (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        int general = lines.FindIndex(line => line.Trim().Equals("[General]", StringComparison.OrdinalIgnoreCase));
        if (general < 0)
        {
            lines.Insert(0, "[General]");
            general = 0;
        }
        // The [General] section runs to the next section header or the end of the file.
        int end = lines.FindIndex(general + 1, line => line.TrimStart().StartsWith('['));
        if (end < 0) end = lines.Count;

        // Replaces the key's line in the section with its new value, or adds the line at the section's end, which keeps the lines above where they are.
        void Set(string key, Func<string?, string> newValue)
        {
            int line = FindKey(lines, general + 1, end, key);
            string text = key + "=" + newValue(line >= 0 ? ValueOf(lines[line]) : null);
            if (line >= 0) lines[line] = text;
            else lines.Insert(end++, text);
        }
        Set("gPCMachineExtensionNames", current => WithRegistryExtension(current ?? ""));
        Set("Version", NextVersion);
        return string.Join("\r\n", lines) + "\r\n";
    }

    /// <summary>The version after a computer policy change: the low 16 bits (the computer half) go up by one, skipping 0, and the high 16 bits (the user half) stay. A missing or non-numeric value counts as 0.</summary>
    private static string NextVersion(string? current)
    {
        uint.TryParse(current, NumberStyles.Integer, CultureInfo.InvariantCulture, out uint version);
        uint computer = (version & 0xFFFF) + 1;
        if (computer > 0xFFFF) computer = 1;
        return ((version & 0xFFFF0000) | computer).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// The extension list with the registry extension and its tool in it. The list is a run of bracketed groups, each an extension id followed by its tool ids, such as
    /// <c>[{A}{B}][{C}{D}]</c>. The groups are kept, the registry group gains the tool when it lacks it, and the groups are written sorted by extension id with each group's tools sorted, the order the editor uses.
    /// </summary>
    private static string WithRegistryExtension(string names)
    {
        var groups = new Dictionary<string, SortedSet<string>>(StringComparer.OrdinalIgnoreCase);
        // The tool ids of one extension's group, made empty when the extension has no group yet.
        SortedSet<string> ToolsOf(string extension)
        {
            if (!groups.TryGetValue(extension, out var tools)) groups[extension] = tools = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            return tools;
        }
        foreach (Match group in BracketGroup().Matches(names))
        {
            var ids = GuidText().Matches(group.Groups[1].Value).Select(id => id.Value.ToUpperInvariant()).ToList();
            if (ids.Count > 0) ToolsOf(ids[0]).UnionWith(ids.Skip(1));
        }
        ToolsOf(RegistryExtension).Add(AdministrativeTemplatesTool);
        return string.Concat(groups.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase).Select(pair => "[" + pair.Key + string.Concat(pair.Value) + "]"));
    }

    /// <summary>The index of the line in [start, end) that sets the key (ignoring letter case and spaces around the name), or -1.</summary>
    private static int FindKey(List<string> lines, int start, int end, string key)
    {
        for (int i = start; i < end; i++)
        {
            int equals = lines[i].IndexOf('=', StringComparison.Ordinal);
            if (equals > 0 && lines[i][..equals].Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) return i;
        }
        return -1;
    }

    /// <summary>The text after the first '=' of a line, trimmed.</summary>
    private static string ValueOf(string line) => line[(line.IndexOf('=', StringComparison.Ordinal) + 1)..].Trim();

    [GeneratedRegex(@"\[([^\]]*)\]")]
    private static partial Regex BracketGroup();

    [GeneratedRegex(@"\{[0-9A-Fa-f\-]{36}\}")]
    private static partial Regex GuidText();
}

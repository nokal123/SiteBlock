using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;
using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// Where the browsers' policy keys live: the real registry on Windows, or a JSON file in a sandbox. Key paths are relative to HKEY_LOCAL_MACHINE (for example
/// <c>SOFTWARE\Policies\Google\Chrome\URLBlocklist</c>) and compared without regard to letter case, as the registry does.
/// </summary>
public interface IPolicyStore
{
    /// <summary>
    /// The values directly in the key, by name, or null when the key does not exist. A value of a type SiteBlock never writes (for example binary or a 64-bit number) is returned as a text value
    /// with no text, so it never equals a wanted value and is rewritten.
    /// </summary>
    IReadOnlyDictionary<string, RegValue>? ReadValues(string keyPath);

    /// <summary>True when the key exists.</summary>
    bool KeyExists(string keyPath);

    /// <summary>True when the key exists and holds no values and no subkeys.</summary>
    bool KeyIsEmpty(string keyPath);

    /// <summary>Writes one value, creating the key (and its parents) when missing.</summary>
    void SetValue(string keyPath, string name, RegValue value);

    /// <summary>Deletes one value; a missing value or key is fine.</summary>
    void DeleteValue(string keyPath, string name);

    /// <summary>Deletes the key and everything under it; a missing key is fine.</summary>
    void DeleteKey(string keyPath);

    /// <summary>
    /// Makes the key hold exactly the list: text values named "1", "2", "3" … holding the entries in order, and nothing else (every other value and every subkey is removed).
    /// The key itself is never deleted on the way, so a browser that reloads its policy mid-change never sees an empty block list.
    /// </summary>
    void ReplaceList(string keyPath, IReadOnlyList<string> entries);
}

/// <summary>Chooses the policy store for a run.</summary>
public static class PolicyStores
{
    /// <summary>The sandbox's registry.json for a sandbox run; the 64-bit view of HKEY_LOCAL_MACHINE otherwise.</summary>
    public static IPolicyStore For(Paths paths)
    {
        if (paths.IsSandbox || !OperatingSystem.IsWindows()) return new FilePolicyStore(paths.RegistryFile);
        return new RegistryPolicyStore();
    }
}

/// <summary>
/// The real registry. By default it works in the 64-bit view of HKEY_LOCAL_MACHINE, where browsers read machine policy; tests point it at a throwaway key under HKEY_CURRENT_USER
/// with <c>rootPrefix</c>, which is put in front of every key path.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class RegistryPolicyStore : IPolicyStore
{
    private readonly RegistryHive _hive;
    private readonly string _rootPrefix;

    /// <summary>Creates a store over the given hive (HKEY_LOCAL_MACHINE by default), with an optional key path put in front of every path.</summary>
    public RegistryPolicyStore(RegistryHive hive = RegistryHive.LocalMachine, string? rootPrefix = null)
    {
        _hive = hive;
        _rootPrefix = string.IsNullOrEmpty(rootPrefix) ? "" : rootPrefix.TrimEnd('\\') + "\\";
    }

    /// <summary>Opens the hive's 64-bit view, so a 32-bit process would still reach the keys browsers read.</summary>
    private RegistryKey OpenBase() => RegistryKey.OpenBaseKey(_hive, RegistryView.Registry64);

    /// <summary>The full path of a key inside the hive.</summary>
    private string Full(string keyPath) => _rootPrefix + keyPath;

    /// <inheritdoc />
    public IReadOnlyDictionary<string, RegValue>? ReadValues(string keyPath)
    {
        using var root = OpenBase();
        using var key = root.OpenSubKey(Full(keyPath));
        if (key is null) return null;
        var values = new Dictionary<string, RegValue>(StringComparer.OrdinalIgnoreCase);
        foreach (string name in key.GetValueNames())
        {
            // DoNotExpandEnvironmentNames keeps text as stored, so %VAR% is compared as written.
            object? data = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            values[name] = key.GetValueKind(name) switch
            {
                RegistryValueKind.String when data is string text => RegValue.Str(text),
                RegistryValueKind.DWord when data is int number => RegValue.DWord(number),
                // Any other type (expandable text, a 64-bit number, binary data) is the wrong type for every value SiteBlock owns.
                _ => new RegValue(RegValueKind.String, null, null),
            };
        }
        return values;
    }

    /// <inheritdoc />
    public bool KeyExists(string keyPath)
    {
        using var root = OpenBase();
        using var key = root.OpenSubKey(Full(keyPath));
        return key is not null;
    }

    /// <inheritdoc />
    public bool KeyIsEmpty(string keyPath)
    {
        using var root = OpenBase();
        using var key = root.OpenSubKey(Full(keyPath));
        return key is not null && key.ValueCount == 0 && key.SubKeyCount == 0;
    }

    /// <inheritdoc />
    public void SetValue(string keyPath, string name, RegValue value)
    {
        using var root = OpenBase();
        using var key = root.CreateSubKey(Full(keyPath), writable: true);
        if (value.Kind == RegValueKind.DWord) key.SetValue(name, value.Number ?? 0, RegistryValueKind.DWord);
        else key.SetValue(name, value.Text ?? "", RegistryValueKind.String);
    }

    /// <inheritdoc />
    public void DeleteValue(string keyPath, string name)
    {
        using var root = OpenBase();
        using var key = root.OpenSubKey(Full(keyPath), writable: true);
        key?.DeleteValue(name, throwOnMissingValue: false);
    }

    /// <inheritdoc />
    public void DeleteKey(string keyPath)
    {
        using var root = OpenBase();
        root.DeleteSubKeyTree(Full(keyPath), throwOnMissingSubKey: false);
    }

    /// <inheritdoc />
    public void ReplaceList(string keyPath, IReadOnlyList<string> entries)
    {
        using var root = OpenBase();
        using var key = root.CreateSubKey(Full(keyPath), writable: true);
        var names = WindowsBrowserPolicy.ListValueNames(entries.Count);
        // The new entries are written over the old ones first, and only then are leftovers removed, so the list never passes through empty.
        for (int i = 0; i < entries.Count; i++) key.SetValue(names[i], entries[i], RegistryValueKind.String);
        var keep = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
        foreach (string name in key.GetValueNames()) if (!keep.Contains(name)) key.DeleteValue(name, throwOnMissingValue: false);
        foreach (string subkey in key.GetSubKeyNames()) key.DeleteSubKeyTree(subkey, throwOnMissingSubKey: false);
    }
}

/// <summary>
/// The sandbox stand-in for the registry: <c>registry.json</c>, a JSON object from key path to an object of values, each value written as
/// <c>{"type": "string", "value": "off"}</c> or <c>{"type": "dword", "value": 1}</c>. Tests read it to check what was written and edit it to tamper.
/// A missing file is an empty registry; a value with another type, or a value that does not match its type, is read as the wrong type.
/// Every change rewrites the whole file through a temporary file, so a reader never sees half of it.
/// </summary>
public sealed class FilePolicyStore : IPolicyStore
{
    private readonly string _path;
    private readonly object _lock = new();

    /// <summary>Creates a store backed by the JSON file at the path.</summary>
    public FilePolicyStore(string path) => _path = path;

    /// <summary>
    /// Reads the whole file into key path → value name → value. A missing, empty or damaged file (not a JSON object) reads as an empty registry, so the next write replaces it,
    /// the way the Mac replaces a policy file that is not a valid property list.
    /// </summary>
    private Dictionary<string, Dictionary<string, RegValue>> Load()
    {
        var keys = new Dictionary<string, Dictionary<string, RegValue>>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(_path)) return keys;
        string text = File.ReadAllText(_path);
        if (string.IsNullOrWhiteSpace(text)) return keys;
        JsonNode? root;
        try { root = JsonNode.Parse(text); }
        catch (JsonException) { return keys; }
        if (root is not JsonObject keyObjects) return keys;
        foreach (var (keyPath, valuesNode) in keyObjects)
        {
            var values = new Dictionary<string, RegValue>(StringComparer.OrdinalIgnoreCase);
            if (valuesNode is JsonObject valueObjects)
            {
                foreach (var (name, valueNode) in valueObjects) values[name] = ReadValue(valueNode);
            }
            keys[keyPath] = values;
        }
        return keys;
    }

    /// <summary>Reads one value object. Anything that is not a string with text or a dword with a whole number is the wrong type.</summary>
    private static RegValue ReadValue(JsonNode? node)
    {
        var wrong = new RegValue(RegValueKind.String, null, null);
        if (node is not JsonObject value) return wrong;
        string? type = value["type"] is JsonValue t && t.TryGetValue(out string? s) ? s : null;
        JsonNode? data = value["value"];
        if (type == "string" && data is JsonValue text && text.TryGetValue(out string? str)) return RegValue.Str(str);
        if (type == "dword" && data is JsonValue number && number.TryGetValue(out int dword)) return RegValue.DWord(dword);
        return wrong;
    }

    /// <summary>Writes the whole registry back, keys and value names sorted, through a temporary file in the same folder.</summary>
    private void Save(Dictionary<string, Dictionary<string, RegValue>> keys)
    {
        var root = new JsonObject();
        foreach (var (keyPath, values) in keys.OrderBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase))
        {
            var valueObjects = new JsonObject();
            foreach (var (name, value) in values.OrderBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase))
            {
                valueObjects[name] = value.Kind == RegValueKind.DWord
                    ? new JsonObject { ["type"] = "dword", ["value"] = value.Number ?? 0 }
                    : new JsonObject { ["type"] = "string", ["value"] = value.Text };
            }
            root[keyPath] = valueObjects;
        }
        string folder = Path.GetDirectoryName(Path.GetFullPath(_path))!;
        Directory.CreateDirectory(folder);
        string temp = Path.Combine(folder, $".registry.{Guid.NewGuid():N}.tmp");
        File.WriteAllText(temp, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, _path, overwrite: true);
    }

    /// <summary>True when a stored key is the given key or lies under it.</summary>
    private static bool IsAtOrUnder(string stored, string keyPath) =>
        string.Equals(stored, keyPath, StringComparison.OrdinalIgnoreCase) || stored.StartsWith(keyPath + "\\", StringComparison.OrdinalIgnoreCase);

    /// <summary>Adds the key and each of its parents when missing, as creating a registry key does.</summary>
    private static Dictionary<string, RegValue> Ensure(Dictionary<string, Dictionary<string, RegValue>> keys, string keyPath)
    {
        string[] parts = keyPath.Split('\\');
        for (int i = 1; i <= parts.Length; i++)
        {
            string path = string.Join('\\', parts[..i]);
            if (!keys.ContainsKey(path)) keys[path] = new Dictionary<string, RegValue>(StringComparer.OrdinalIgnoreCase);
        }
        return keys[keyPath];
    }

    /// <inheritdoc />
    public IReadOnlyDictionary<string, RegValue>? ReadValues(string keyPath)
    {
        lock (_lock) return Load().TryGetValue(keyPath, out var values) ? values : null;
    }

    /// <inheritdoc />
    public bool KeyExists(string keyPath)
    {
        lock (_lock) return Load().ContainsKey(keyPath);
    }

    /// <inheritdoc />
    public bool KeyIsEmpty(string keyPath)
    {
        lock (_lock)
        {
            var keys = Load();
            if (!keys.TryGetValue(keyPath, out var values) || values.Count > 0) return false;
            return !keys.Keys.Any(stored => stored.StartsWith(keyPath + "\\", StringComparison.OrdinalIgnoreCase));
        }
    }

    /// <inheritdoc />
    public void SetValue(string keyPath, string name, RegValue value)
    {
        lock (_lock)
        {
            var keys = Load();
            Ensure(keys, keyPath)[name] = value;
            Save(keys);
        }
    }

    /// <inheritdoc />
    public void DeleteValue(string keyPath, string name)
    {
        lock (_lock)
        {
            var keys = Load();
            if (keys.TryGetValue(keyPath, out var values) && values.Remove(name)) Save(keys);
        }
    }

    /// <inheritdoc />
    public void DeleteKey(string keyPath)
    {
        lock (_lock)
        {
            var keys = Load();
            var doomed = keys.Keys.Where(stored => IsAtOrUnder(stored, keyPath)).ToList();
            if (doomed.Count == 0) return;
            foreach (string stored in doomed) keys.Remove(stored);
            Save(keys);
        }
    }

    /// <inheritdoc />
    public void ReplaceList(string keyPath, IReadOnlyList<string> entries)
    {
        lock (_lock)
        {
            var keys = Load();
            foreach (string stored in keys.Keys.Where(stored => IsAtOrUnder(stored, keyPath)).ToList()) keys.Remove(stored);
            var values = Ensure(keys, keyPath);
            var names = WindowsBrowserPolicy.ListValueNames(entries.Count);
            for (int i = 0; i < entries.Count; i++) values[names[i]] = RegValue.Str(entries[i]);
            Save(keys);
        }
    }
}

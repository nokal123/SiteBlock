using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SiteBlock.Core;

/// <summary>What GitHub's version file (<c>version.json</c> on the Mac, <c>version-windows.json</c> on Windows) says about the newest published build.</summary>
/// <param name="Version">The version text, always <c>1.0.&lt;build&gt;</c>.</param>
/// <param name="Build">The build number: the count of commits the package was built from.</param>
/// <param name="Commit">The full 40-character commit hash the package was built from.</param>
/// <param name="Asset">The file name of the package in the same release (<c>SiteBlock.zip</c> on the Mac, <c>SiteBlock-Windows.zip</c> on Windows).</param>
/// <param name="Sha256">The SHA-256 checksum of the package as 64 lowercase hex characters.</param>
/// <param name="DisplayVersion">The version number people see, for example 1.2.0, or null in a file written before it existed. The banner shows it in place of <paramref name="Version"/>.</param>
public sealed record UpdateInfo(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("build")] int Build,
    [property: JsonPropertyName("commit")] string Commit,
    [property: JsonPropertyName("asset")] string Asset,
    [property: JsonPropertyName("sha256")] string Sha256,
    [property: JsonPropertyName("displayVersion")] string? DisplayVersion = null)
{
    /// <summary>What to show people: <see cref="DisplayVersion"/> when the file has one, otherwise <see cref="Version"/>.</summary>
    [JsonIgnore]
    public string ShownVersion => DisplayVersion ?? Version;
}

/// <summary>
/// The pure rules of the update check: where the newest version is published, whether a published file is usable, whether it is newer than the installed build, and whether a download matches its checksum.
/// Nothing here touches the network, so the app does the fetching and this code does the judging.
/// </summary>
public static class UpdateCheck
{
    /// <summary>Where the newest Mac build's <c>version.json</c> is published. This is a constant: nothing outside the code can point the app at another server.</summary>
    public static readonly Uri VersionUrl = new("https://github.com/nokal123/SiteBlock/releases/latest/download/version.json");

    /// <summary>Where the newest Mac package is published, under a name that never changes.</summary>
    public static readonly Uri PackageUrl = new("https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip");

    /// <summary>Where the newest Windows build's <c>version-windows.json</c> is published.</summary>
    public static readonly Uri WindowsVersionUrl = new("https://github.com/nokal123/SiteBlock/releases/download/windows-latest/version-windows.json");

    /// <summary>Where the newest Windows package is published, under a name that never changes.</summary>
    public static readonly Uri WindowsPackageUrl = new("https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip");

    /// <summary>The only package file name a Mac version file may name.</summary>
    public const string MacAsset = "SiteBlock.zip";

    /// <summary>The only package file name a Windows version file may name.</summary>
    public const string WindowsAsset = "SiteBlock-Windows.zip";

    /// <summary>
    /// Reads a version file. Returns null unless it is a JSON object with all five required fields of the right type and every rule holds:
    /// the build is above 0, the version is <c>1.0.</c> followed by that build, the asset is exactly <paramref name="expectedAsset"/>, the checksum is exactly 64 lowercase hex characters, and the commit is exactly 40.
    /// A display version, when present, must be three dot-separated numbers of one to four digits. Extra fields are ignored. Anything else means "no usable update info" and never throws.
    /// </summary>
    public static UpdateInfo? Parse(byte[] data, string expectedAsset)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(data);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;

            // When a key appears twice the last one wins, as in Swift's decoder. Key matching is exact and case-sensitive.
            var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (JsonProperty property in document.RootElement.EnumerateObject()) fields[property.Name] = property.Value;

            if (!TryString(fields, "version", out string? version) || version is null) return null;
            if (!fields.TryGetValue("build", out JsonElement buildElement) || buildElement.ValueKind != JsonValueKind.Number || !buildElement.TryGetInt32(out int build)) return null;
            if (!TryString(fields, "commit", out string? commit) || commit is null) return null;
            if (!TryString(fields, "asset", out string? asset) || asset is null) return null;
            if (!TryString(fields, "sha256", out string? sha256) || sha256 is null) return null;
            // displayVersion may be absent or null; any other type is a wrong type and rejects the whole file.
            string? displayVersion = null;
            if (fields.TryGetValue("displayVersion", out JsonElement displayElement) && displayElement.ValueKind != JsonValueKind.Null)
            {
                if (displayElement.ValueKind != JsonValueKind.String) return null;
                displayVersion = displayElement.GetString();
            }

            if (build <= 0 || version != "1.0." + build.ToString(CultureInfo.InvariantCulture) || !string.Equals(asset, expectedAsset, StringComparison.Ordinal)) return null;
            // A display version, when present, must look like 1.2.0 (three short numbers), so the banner never shows odd text.
            if (displayVersion is not null && !IsDottedVersion(displayVersion)) return null;
            if (!IsLowercaseHex(sha256, 64) || !IsLowercaseHex(commit, 40)) return null;
            return new UpdateInfo(version, build, commit, asset, sha256, displayVersion);
        }
        catch (Exception)
        {
            // Bad JSON, a depth limit, or invalid text inside a string: all mean "no usable update info".
            return null;
        }
    }

    /// <summary>Reads a field that must be a JSON string; false when it is missing or has another type (including null).</summary>
    private static bool TryString(Dictionary<string, JsonElement> fields, string name, out string? value)
    {
        value = null;
        if (!fields.TryGetValue(name, out JsonElement element) || element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString();
        return value is not null;
    }

    /// <summary>True when the published build is newer than the installed one. An installed build of 0 (built without git) counts every published build as newer, because a published build is always above 0.</summary>
    public static bool IsNewer(UpdateInfo info, int installedBuild) => info.Build > installedBuild;

    /// <summary>
    /// True when the SHA-256 of the file at <paramref name="filePath"/> equals <paramref name="expected"/>; upper and lower case letters are treated alike.
    /// A file that cannot be read, or an empty or malformed expected value, does not match. The file is read in chunks, so a large file does not have to fit in memory.
    /// </summary>
    public static bool MatchesChecksum(string filePath, string expected)
    {
        if (string.IsNullOrEmpty(expected)) return false;
        try
        {
            using FileStream stream = new(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            string actual = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
            return actual == SwiftText.Lowercased(expected);
        }
        catch (Exception)
        {
            // Missing, locked or unreadable file (or a bad path): it cannot match.
            return false;
        }
    }

    /// <summary>True when the text is three numbers of one to four ASCII digits joined by dots, such as 1.2.0.</summary>
    private static bool IsDottedVersion(string text)
    {
        string[] parts = text.Split('.');
        return parts.Length == 3 && parts.All(part => part.Length is >= 1 and <= 4 && part.All(c => c >= '0' && c <= '9'));
    }

    /// <summary>True when the text is exactly <paramref name="length"/> characters, each a digit or a lowercase letter a to f. Characters from other scripts never pass.</summary>
    private static bool IsLowercaseHex(string text, int length) =>
        text.Length == length && text.All(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
}

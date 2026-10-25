using System.Globalization;
using System.Reflection;

namespace SiteBlock.Core;

/// <summary>
/// The version numbers of this build. Directory.Build.props writes the build number (the release number in version.props), the series (such as 1.0) and the series' first build into every assembly as
/// <see cref="AssemblyMetadataAttribute"/> values, and this class reads them from the SiteBlock.Core assembly, so every program built from one checkout shows the same version.
/// </summary>
public static class BuildInfo
{
    /// <summary>The release number this build was made with (<c>SiteBlockBuildNumber</c> in version.props), or 0 when the value is missing or unreadable.</summary>
    public static int BuildNumber { get; } = ReadInt("SiteBlockBuildNumber");

    /// <summary>The first two parts of the version people see, such as "1.0"; "1.0" when the value is missing.</summary>
    public static string Series { get; } = ReadText("SiteBlockSeries") is { Length: > 0 } series ? series : "1.0";

    /// <summary>The build number of the first build in the current series, which is released as &lt;series&gt;.0; 0 when missing.</summary>
    public static int SeriesFirstBuild { get; } = ReadInt("SiteBlockSeriesFirstBuild");

    /// <summary>
    /// The version people see: the series followed by how far the build number is past the series' first build, so the series starts at .0 and counts up by
    /// one per release. Updates are ordered by the build number, never by this text.
    /// </summary>
    public static string MarketingVersion { get; } = $"{Series}.{Math.Max(0, BuildNumber - SeriesFirstBuild)}";

    /// <summary>The version shown in the app, the CLI and the service's status reply; the same as <see cref="MarketingVersion"/>.</summary>
    public static string Version => MarketingVersion;

    /// <summary>The technical build id written to the version file's <c>version</c> field: 1.0 followed by the build number.</summary>
    public static string BuildId { get; } = $"1.0.{BuildNumber}";

    /// <summary>The version with its build number, for example "1.0.3 (build 59)", as <c>siteblockd --version</c> prints it.</summary>
    public static string VersionWithBuild { get; } = $"{MarketingVersion} (build {BuildNumber})";

    /// <summary>The text of one assembly metadata value, or null when this assembly has none by that name.</summary>
    private static string? ReadText(string key) =>
        typeof(BuildInfo).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(attribute => attribute.Key == key)?.Value;

    /// <summary>One assembly metadata value read as a whole number, or 0 when it is missing or not a whole number.</summary>
    private static int ReadInt(string key) =>
        int.TryParse(ReadText(key), NumberStyles.None, CultureInfo.InvariantCulture, out int value) ? value : 0;
}

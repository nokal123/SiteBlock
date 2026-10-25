using System.Globalization;
using System.Xml.Linq;
using SiteBlock.Core;

namespace SiteBlock.Integration.Tests.Release;

// The hand-kept Windows release number. Expected values: 06-windows.md § Install, Package and Release and the Mac rule it follows (04-infrastructure.md § Version Numbers):
// the build number is `<SiteBlockBuildNumber>` in windows/version.props, a checked-in whole number above 0; no generated BuildNumber.props and no write-build-number script
// exist; the version people see is <WindowsSeries>.<max(0, build - WindowsSeriesFirstBuild)> (series 1.0 starting at 88, so build 94 shows 1.0.6).
public sealed class VersionNumberTests
{
    // The text of every element with that name in a props file.
    private static List<string> Elements(string file, string name) => XDocument.Load(file).Descendants(name).Select(element => element.Value.Trim()).ToList();

    private static int WholeNumber(string text) => int.Parse(text, NumberStyles.None, CultureInfo.InvariantCulture);

    [Fact]
    public void VersionProps_DeclaresTheReleaseNumberOnceAsAWholeNumberAboveZero()
    {
        var values = Elements(Repo.InWindows("version.props"), "SiteBlockBuildNumber");
        Assert.Single(values);
        Assert.Matches("^[0-9]+$", values[0]);
        Assert.True(WholeNumber(values[0]) > 0, $"SiteBlockBuildNumber must be above 0; it is {values[0]}");
    }

    // The library every program reads carries the number written in version.props, and the shown version and build id follow from it.
    [Fact]
    public void BuildInfo_CarriesTheNumberWrittenInVersionProps()
    {
        string props = Repo.InWindows("version.props");
        int build = WholeNumber(Elements(props, "SiteBlockBuildNumber").Single());
        int first = WholeNumber(Elements(props, "WindowsSeriesFirstBuild").Single());
        string series = Elements(props, "WindowsSeries").Single();
        string shown = $"{series}.{Math.Max(0, build - first)}";

        Assert.Equal(build, BuildInfo.BuildNumber);
        Assert.Equal(shown, BuildInfo.MarketingVersion);
        Assert.Equal(shown, BuildInfo.Version);
        Assert.Equal("1.0." + build.ToString(CultureInfo.InvariantCulture), BuildInfo.BuildId);
    }

    // No generated file and no script write the number, and nothing that builds still refers to them.
    [Fact]
    public void NoGeneratedBuildNumberPropsAndNoWriteBuildNumberScriptRemain()
    {
        foreach (string gone in new[] { "BuildNumber.props", "scripts/write-build-number.ps1", "scripts/write-build-number.sh" })
        {
            Assert.False(File.Exists(Repo.InWindows(gone)), $"windows/{gone} must not exist");
        }
        foreach (string file in new[] { "Directory.Build.props", "scripts/build.ps1", "scripts/package.ps1" })
        {
            string text = File.ReadAllText(Repo.InWindows(file));
            Assert.False(text.Contains("BuildNumber.props", StringComparison.Ordinal) || text.Contains("write-build-number", StringComparison.Ordinal), $"windows/{file} still refers to the generated build number");
        }
    }

    // Directory.Build.props evaluated for real by MSBuild, with a version.props whose release number is varied: the program version is <series>.<max(0, build - first build)>.
    // 7 and 88 are at or below the first build (1.0.0); 89 is one past it; 94 is the design's own example. Only the release number changes between cases.
    [Theory]
    [InlineData(7, "1.0.0")]
    [InlineData(88, "1.0.0")]
    [InlineData(89, "1.0.1")]
    [InlineData(94, "1.0.6")]
    public void DirectoryBuildProps_GivesTheSeriesAndHowFarTheBuildIsPastTheSeriesFirstBuild(int build, string shown)
    {
        using var tree = new TempFolder();
        File.Copy(Repo.InWindows("Directory.Build.props"), tree.File("Directory.Build.props"));
        File.WriteAllText(tree.File("version.props"), $"<Project>\n  <PropertyGroup>\n    <WindowsSeries>1.0</WindowsSeries>\n    <WindowsSeriesFirstBuild>88</WindowsSeriesFirstBuild>\n    <SiteBlockBuildNumber>{build}</SiteBlockBuildNumber>\n  </PropertyGroup>\n</Project>\n");
        File.WriteAllText(tree.File("probe.proj"), "<Project>\n  <Import Project=\"Directory.Build.props\" />\n  <Target Name=\"Build\" />\n</Project>\n");

        var result = Processes.Run(Processes.Dotnet, ["msbuild", tree.File("probe.proj"), "-nologo", "-nodeReuse:false", "-getProperty:Version"], workingDirectory: tree.Path);

        Assert.True(result.ExitCode == 0, "dotnet msbuild failed: " + result);
        Assert.Equal(shown, result.StandardOutput.Trim());
    }
}

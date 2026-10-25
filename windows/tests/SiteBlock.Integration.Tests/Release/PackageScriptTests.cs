using System.Text.Json;

namespace SiteBlock.Integration.Tests.Release;

// windows/scripts/package.ps1 run for real with pwsh on a COPY of windows/ in a temporary folder, so the repository's own build/ and dist/ are never touched.
// Expected values: 06-windows.md § Install, Package and Release: the build number is SiteBlockBuildNumber in version.props, kept by hand; the version people see is
// <WindowsSeries>.<max(0, build - WindowsSeriesFirstBuild)> (series 1.0 starting at build 88, so build 94 shows 1.0.6); version-windows.json carries `version` "1.0.<build>",
// `build` (a number) and `displayVersion`; package.ps1 refuses a SiteBlockBuildNumber that is not a whole number above 0.
//
// The real build.ps1 compiles every program for two kinds of PC, which takes minutes, so the copy holds a stand-in build.ps1 that writes placeholder program files. The
// refusal happens before any program is used, so the refusal tests run everywhere. A successful run on Windows also starts the built siteblockd.exe to compare its version,
// which a placeholder cannot answer, so the successful-run tests run only on macOS and Linux; on GitHub's Windows machine the workflow's "Build the package" and "Check the
// build number" steps do the real run.
public sealed class PackageScriptTests
{
    private const string WindowsOnlyRunReason = "package.ps1 starts the built siteblockd.exe on Windows, which the stand-in build cannot provide; the workflow's real package run covers Windows.";

    // A stand-in for build.ps1: placeholder program files for the requested kind of PC, laid out as the real build does, and exit 0 as the real one ends.
    private const string StandInBuild = """
        param([string]$Runtime = '', [string]$Configuration = 'Release')
        $out = Join-Path (Split-Path -Parent $PSScriptRoot) "build/$Runtime"
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        foreach ($name in @('siteblockd.exe', 'siteblock.exe', 'SiteBlockApp.exe')) { Set-Content -LiteralPath (Join-Path $out $name) -Value "stand-in $Runtime $name" }
        exit 0
        """;

    // A copy of windows/ with the real package.ps1 and the files it packs, the stand-in build.ps1, and a version.props whose SiteBlockBuildNumber element holds `buildText`
    // (null leaves the element out). The series is 1.0 starting at build 88, as in the design.
    private static TempFolder MakeTree(string? buildText)
    {
        var tree = new TempFolder();
        Directory.CreateDirectory(tree.File("scripts"));
        foreach (string file in new[] { "scripts/package.ps1", "scripts/install.ps1", "scripts/verify-install.ps1", "Install SiteBlock.cmd", "INSTALL.txt" }) File.Copy(Repo.InWindows(file), tree.File(file));
        File.WriteAllText(tree.File("scripts/build.ps1"), StandInBuild);
        string buildElement = buildText is null ? "" : $"\n    <SiteBlockBuildNumber>{buildText}</SiteBlockBuildNumber>";
        File.WriteAllText(tree.File("version.props"), $"<Project>\n  <PropertyGroup>\n    <WindowsSeries>1.0</WindowsSeries>\n    <WindowsSeriesFirstBuild>88</WindowsSeriesFirstBuild>{buildElement}\n  </PropertyGroup>\n</Project>\n");
        return tree;
    }

    private static ProcessResult Package(TempFolder tree) => Processes.RunPwshScript(tree.File("scripts/package.ps1"));

    // A release number of 7 is far from the repository's own number and from any commit count, so only a number read from the packaged tree's version.props gives 7.
    // 7 and 88 are at or below the series' first build and show 1.0.0; 94 is the design's own example (1.0.6); 1088 shows a four-digit count.
    [PwshTheory(unixOnly: true, unixOnlyReason: WindowsOnlyRunReason)]
    [InlineData(7, "1.0.0")]
    [InlineData(88, "1.0.0")]
    [InlineData(94, "1.0.6")]
    [InlineData(1088, "1.0.1000")]
    public void VersionFile_CarriesTheReleaseNumberFromVersionPropsAndTheShownVersion(int build, string shown)
    {
        using var tree = MakeTree(build.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var result = Package(tree);
        Assert.True(result.ExitCode == 0, "package.ps1 failed: " + result);

        using var json = JsonDocument.Parse(File.ReadAllText(tree.File("dist/version-windows.json")));
        var root = json.RootElement;
        Assert.Equal(JsonValueKind.Number, root.GetProperty("build").ValueKind);
        Assert.Equal(build, root.GetProperty("build").GetInt32());
        Assert.Equal("1.0." + build.ToString(System.Globalization.CultureInfo.InvariantCulture), root.GetProperty("version").GetString());
        Assert.Equal(shown, root.GetProperty("displayVersion").GetString());
        Assert.True(File.Exists(tree.File("dist/SiteBlock-Windows.zip")), "the zip is missing");
    }

    // The number in the tree's version.props decides, not the number these tests were built with: the two differ, and version-windows.json follows the file.
    [PwshFact(unixOnly: true, unixOnlyReason: WindowsOnlyRunReason)]
    public void VersionFile_FollowsTheTreesVersionPropsNotTheBuildTheTestsWereMadeWith()
    {
        Assert.NotEqual(7, SiteBlock.Core.BuildInfo.BuildNumber);
        using var tree = MakeTree("7");
        var result = Package(tree);
        Assert.True(result.ExitCode == 0, "package.ps1 failed: " + result);
        using var json = JsonDocument.Parse(File.ReadAllText(tree.File("dist/version-windows.json")));
        Assert.Equal(7, json.RootElement.GetProperty("build").GetInt32());
    }

    // A SiteBlockBuildNumber that is not a whole number above 0 is refused: exit 1, no version-windows.json and no zip, and the message names the setting (so the refusal is
    // for this reason and not some other failure of the copy). NOELEMENT leaves the element out of version.props.
    [PwshTheory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("abc")]
    [InlineData("9.5")]
    [InlineData("")]
    [InlineData("1e3")]
    [InlineData("NOELEMENT")]
    public void BuildNumberThatIsNotAWholeNumberAboveZero_IsRefused(string buildText)
    {
        using var tree = MakeTree(buildText == "NOELEMENT" ? null : buildText);
        var result = Package(tree);
        Assert.True(result.ExitCode == 1, $"SiteBlockBuildNumber '{buildText}': expected exit 1; {result}");
        Assert.False(File.Exists(tree.File("dist/version-windows.json")), "a refused run must not write version-windows.json");
        Assert.False(File.Exists(tree.File("dist/SiteBlock-Windows.zip")), "a refused run must not write the zip");
        Assert.Contains("SiteBlockBuildNumber", result.StandardOutput + result.StandardError, StringComparison.Ordinal);
    }
}

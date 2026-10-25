namespace SiteBlock.Integration.Tests.Release;

// windows/scripts/release-check.ps1 run for real with pwsh, as the workflow's "Decide whether this is a release" step runs it.
// Expected values: 06-windows.md § Install, Package and Release (the release decision), which follows the Mac's rule in 04-infrastructure.md § Automatic Package Builds:
// `release-check.ps1 <new> <published>` prints `release` (exit 0) when the new file's build is higher, `skip` (exit 0) when it is equal, and exits 1 with an "error: ..."
// line on standard error and nothing on standard output when the new build is lower, or when either file is missing, is not JSON, has no `build`, or has a build that is
// not a JSON whole number (the text "95", 95.5, -1, null and true are all refused). The comparison is numeric (100 > 99, 1000 > 999), not textual.
public sealed class ReleaseCheckScriptTests
{
    private static readonly string Script = Repo.InWindows("scripts/release-check.ps1");

    // Writes a complete version-windows.json (the six fields package.ps1 writes) whose `build` is the given JSON fragment, or with no `build` at all when it is null.
    private static string WriteVersionFile(TempFolder folder, string name, string? build)
    {
        string buildLine = build is null ? "" : $"  \"build\": {build},\n";
        string text = "{\n  \"version\": \"1.0.95\",\n" + buildLine + "  \"displayVersion\": \"1.0.7\",\n  \"commit\": \"" + new string('a', 40) + "\",\n  \"asset\": \"SiteBlock-Windows.zip\",\n  \"sha256\": \"" + new string('b', 64) + "\"\n}\n";
        string path = folder.File(name);
        File.WriteAllText(path, text);
        return path;
    }

    // Runs the script on two complete version files whose `build` fields are the given fragments.
    private static ProcessResult Check(string? newBuild, string? publishedBuild)
    {
        using var folder = new TempFolder();
        return Processes.RunPwshScript(Script, WriteVersionFile(folder, "new.json", newBuild), WriteVersionFile(folder, "published.json", publishedBuild));
    }

    // The decision of an accepted comparison: exit 0 and exactly one line on standard output; anything else gives a text that names what was wrong.
    private static string Decision(ProcessResult result)
    {
        if (result.ExitCode != 0) return "<" + result + ">";
        string[] lines = result.StandardOutput.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
        return lines.Length == 1 ? lines[0] : "<not one line: " + result + ">";
    }

    // The checks every refusal must pass: exit code 1, nothing on standard output, and an "error: ..." line on standard error.
    private static void AssertRefused(ProcessResult result, string context)
    {
        Assert.True(result.ExitCode == 1, $"{context}: expected exit 1; {result}");
        Assert.True(result.StandardOutput.Length == 0, $"{context}: a refusal must print nothing on standard output; {result}");
        Assert.True(result.StandardError.StartsWith("error: ", StringComparison.Ordinal), $"{context}: standard error must start with 'error: '; {result}");
    }

    // Pairs where the new number has more digits (100 > 99, 1000 > 999, 10 > 9) catch a text comparison; 0 is a JSON whole number too; 3000000000 is above the 32-bit range.
    [PwshTheory]
    [InlineData(95L, 94L)]
    [InlineData(100L, 99L)]
    [InlineData(1000L, 999L)]
    [InlineData(10L, 9L)]
    [InlineData(1L, 0L)]
    [InlineData(3_000_000_000L, 2_999_999_999L)]
    public void HigherNewBuild_PrintsReleaseAndExitsZero(long newBuild, long publishedBuild) =>
        Assert.Equal("release", Decision(Check(newBuild.ToString(System.Globalization.CultureInfo.InvariantCulture), publishedBuild.ToString(System.Globalization.CultureInfo.InvariantCulture))));

    [PwshTheory]
    [InlineData(1)]
    [InlineData(94)]
    [InlineData(1000)]
    public void EqualBuild_PrintsSkipAndExitsZero(int build) => Assert.Equal("skip", Decision(Check(build.ToString(System.Globalization.CultureInfo.InvariantCulture), build.ToString(System.Globalization.CultureInfo.InvariantCulture))));

    // A lower new build is refused: installed copies would never take it. 99 against 100 and 999 against 1000 are "higher" as text.
    [PwshTheory]
    [InlineData(93, 94)]
    [InlineData(99, 100)]
    [InlineData(999, 1000)]
    [InlineData(9, 10)]
    [InlineData(0, 1)]
    public void LowerNewBuild_IsRefused(int newBuild, int publishedBuild) =>
        AssertRefused(Check(newBuild.ToString(System.Globalization.CultureInfo.InvariantCulture), publishedBuild.ToString(System.Globalization.CultureInfo.InvariantCulture)), $"new {newBuild}, published {publishedBuild}");

    // A `build` that is not a JSON whole number is refused in either file. The other file holds a valid number (94 published, or 95 new), so the only fault is the one under
    // test. "95.0" comes from the Mac rule in 04 § Automatic Package Builds ("a decimal such as 95.0" is refused). NOBUILD means the field is left out.
    [PwshTheory]
    [InlineData("\"95\"", true)]
    [InlineData("\"95\"", false)]
    [InlineData("95.5", true)]
    [InlineData("95.5", false)]
    [InlineData("95.0", true)]
    [InlineData("95.0", false)]
    // -1 in the new file is refused anyway as lower than the published 94, so that row cannot tell a rejected -1 from an accepted one; the published -1 row
    // (95 against -1, which a type-only check would call "release") is the one that can.
    [InlineData("-1", true)]
    [InlineData("-1", false)]
    [InlineData("null", true)]
    [InlineData("null", false)]
    [InlineData("true", true)]
    [InlineData("true", false)]
    [InlineData("false", true)]
    [InlineData("false", false)]
    [InlineData("{}", true)]
    [InlineData("{}", false)]
    [InlineData("[95]", true)]
    [InlineData("[95]", false)]
    [InlineData("\"\"", true)]
    [InlineData("\"\"", false)]
    [InlineData("NOBUILD", true)]
    [InlineData("NOBUILD", false)]
    public void BuildThatIsNotAJsonWholeNumber_IsRefusedInEitherFile(string fragment, bool inNewFile)
    {
        string? build = fragment == "NOBUILD" ? null : fragment;
        var result = inNewFile ? Check(build, "94") : Check("95", build);
        AssertRefused(result, $"build {fragment} in the {(inNewFile ? "new" : "published")} file");
    }

    // A file that is missing, empty, not JSON, or JSON without a top-level `build` is refused, in either position: the field nested deeper, the key spelled `Build`
    // (JSON keys are case-sensitive, though PowerShell's own property lookup is not), and a top-level array holding the object (which PowerShell would read through).
    // MISSING means no file at that path.
    [PwshTheory]
    [InlineData("MISSING", true)]
    [InlineData("MISSING", false)]
    [InlineData("", true)]
    [InlineData("", false)]
    [InlineData("not json at all\n", true)]
    [InlineData("not json at all\n", false)]
    [InlineData("{\"info\": {\"build\": 95}}\n", true)]
    [InlineData("{\"info\": {\"build\": 95}}\n", false)]
    [InlineData("{\"build\": 95\n", true)]
    [InlineData("{\"build\": 95\n", false)]
    [InlineData("{\"Build\": 95}\n", true)]
    [InlineData("{\"Build\": 95}\n", false)]
    [InlineData("[{\"build\": 95}]\n", true)]
    [InlineData("[{\"build\": 95}]\n", false)]
    public void FileThatIsMissingOrNotAVersionObject_IsRefusedInEitherPosition(string content, bool inNewFile)
    {
        using var folder = new TempFolder();
        string bad = folder.File("bad.json");
        if (content != "MISSING") File.WriteAllText(bad, content);
        string good = WriteVersionFile(folder, "good.json", inNewFile ? "94" : "95");
        var result = inNewFile ? Processes.RunPwshScript(Script, bad, good) : Processes.RunPwshScript(Script, good, bad);
        AssertRefused(result, $"file '{content}' as the {(inNewFile ? "new" : "published")} file");
    }

    // The workflow passes real paths; a folder with spaces, non-ASCII letters and PowerShell wildcard characters ([ ]) must not break the script's file reading.
    [PwshFact]
    public void PathsWithSpacesNonAsciiLettersAndWildcardCharacters_Work()
    {
        using var folder = new TempFolder();
        Directory.CreateDirectory(folder.File("a folder ñ [1]"));
        using var inner = new TempFolder();
        string newFile = Path.Combine(folder.File("a folder ñ [1]"), "new version.json");
        string publishedFile = Path.Combine(folder.File("a folder ñ [1]"), "published [x].json");
        File.Copy(WriteVersionFile(inner, "n.json", "95"), newFile);
        File.Copy(WriteVersionFile(inner, "p.json", "94"), publishedFile);
        Assert.Equal("release", Decision(Processes.RunPwshScript(Script, newFile, publishedFile)));
    }
}

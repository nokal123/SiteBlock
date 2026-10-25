namespace SiteBlock.Integration.Tests.Release;

// windows.yml's release steps run for real with pwsh, with stand-ins for gh and git (see WorkflowStepRun). Expected values: 06-windows.md § Install, Package and Release
// (GitHub workflow):
// - step 3: after package.ps1, the run checks that the packaged windows/dist/version-windows.json does not say build 0 (a build of 0 or less stops the run);
// - step 5: the decide step downloads version-windows.json from the `windows-latest` release and runs windows/scripts/release-check.ps1 <new> <published>; `release` and
//   `skip` both let the run go on, and the publishing steps read the decision from the step's output; on `skip` a notice titled "Not a release" names the number to raise
//   (SiteBlockBuildNumber in windows/version.props); a published file that cannot be downloaded, or a failed check (a lower build, a malformed file), stops the run with
//   an error annotation, so no decision may be written;
// - step 6: a release tagged windows-v<version>, not marked latest, with both files, and the fixed release `windows-latest` gets the same two files; neither release is
//   ever marked latest, because the Mac's updater reads releases/latest.
public sealed class WindowsWorkflowStepRunTests
{
    private static readonly List<WorkflowStep> Steps = Workflow.Steps(File.ReadAllText(Repo.InRoot(".github/workflows/windows.yml")));
    private const string Zip = "windows/dist/SiteBlock-Windows.zip";
    private const string VersionFile = "windows/dist/version-windows.json";

    private static WorkflowStep Named(string name) => Steps.SingleOrDefault(step => step.Name == name) ?? throw new Xunit.Sdk.XunitException($"no single step named '{name}'; steps: {string.Join(" | ", Steps.Select(step => step.Name))}");

    // A complete version-windows.json (the six fields package.ps1 writes) whose `build` is the given JSON fragment.
    private static string Version(string build, string version = "1.0.95", string displayVersion = "1.0.7") =>
        "{\n  \"version\": \"" + version + "\",\n  \"build\": " + build + ",\n  \"displayVersion\": \"" + displayVersion + "\",\n  \"commit\": \"" + new string('a', 40) + "\",\n  \"asset\": \"SiteBlock-Windows.zip\",\n  \"sha256\": \"" + new string('b', 64) + "\"\n}\n";

    private static List<string> StdoutLines(ProcessResult result) => result.StandardOutput.Replace("\r\n", "\n").Split('\n').ToList();

    private static List<string> ErrorLines(ProcessResult result) => StdoutLines(result).Where(line => line.StartsWith("::error", StringComparison.Ordinal)).ToList();

    // The gh calls of one kind ("create", "edit", ...) under `gh release`.
    private static List<string[]> GhRelease(WorkflowStepRun run, string verb) => run.Calls.Where(call => call.Length > 2 && call[0] == "gh" && call[1] == "release" && call[2] == verb).ToList();

    // True when a gh call asks for its release to be marked latest: `--latest` alone or `--latest=true` (gh's `--latest=false` is the only spelling that keeps it unmarked).
    private static bool MarksLatest(string[] call) => call.Any(word => word == "--latest" || word.Equals("--latest=true", StringComparison.OrdinalIgnoreCase));

    private static string Show(IEnumerable<string[]> calls) => string.Join(" || ", calls.Select(call => string.Join(' ', call.Select(word => word.Length > 60 ? word[..60] + "..." : word))));

    // Runs the decide step in a checkout holding the real release-check.ps1 and a new version-windows.json with the given build; the stand-in gh "downloads" a
    // version file with the published build, or fails when `published` is null.
    private static (ProcessResult Result, WorkflowStepRun Run) RunDecide(string newBuild, string? published)
    {
        var run = new WorkflowStepRun();
        run.CopyFromRepository("scripts/release-check.ps1");
        run.WriteInTree(VersionFile, Version(newBuild));
        run.SetPublishedSource(Version(published ?? "94"));
        return (run.Run(Named("Decide whether this is a release"), failDownload: published is null), run);
    }

    // The checks for a download made as the design says: exactly one gh call, `release download windows-latest` with the pattern version-windows.json.
    private static void AssertDownloadFromWindowsLatest(WorkflowStepRun run, string context)
    {
        var calls = run.Calls;
        Assert.True(calls.Count == 1 && calls[0].Length > 2 && calls[0][0] == "gh" && calls[0][1] == "release" && calls[0][2] == "download", $"{context}: calls {Show(calls)}");
        string[] words = calls[0][3..];
        var positional = new List<string>();
        string? pattern = null;
        for (int i = 0; i < words.Length; i++)
        {
            if (words[i] is "--pattern" or "-p") pattern = i + 1 < words.Length ? words[++i] : null;
            else if (words[i] is "--dir" or "-D" or "--repo" or "-R" or "--output" or "-O" or "--archive" or "-A") i++;
            else if (!words[i].StartsWith('-')) positional.Add(words[i]);
        }
        Assert.True(positional.SequenceEqual(["windows-latest"]), $"{context}: the download must name the windows-latest release: {Show(calls)}");
        Assert.True(pattern == "version-windows.json", $"{context}: {Show(calls)}");
    }

    [PwshFact]
    public void DecideStep_HigherBuild_WritesExactlyDecisionReleaseAndExitsZero()
    {
        var (result, run) = RunDecide("95", "94");
        using (run)
        {
            Assert.True(result.ExitCode == 0, result.ToString());
            Assert.Equal(["decision=release"], run.OutputLines);
            Assert.True(ErrorLines(result).Count == 0 && !result.StandardOutput.Contains("Not a release", StringComparison.Ordinal), result.ToString());
            AssertDownloadFromWindowsLatest(run, "release");
        }
    }

    [PwshFact]
    public void DecideStep_EqualBuild_WritesDecisionSkipAndANoticeNamingTheNumberToRaise()
    {
        var (result, run) = RunDecide("94", "94");
        using (run)
        {
            Assert.True(result.ExitCode == 0, result.ToString());
            Assert.Equal(["decision=skip"], run.OutputLines);
            string? notice = StdoutLines(result).FirstOrDefault(line => line.StartsWith("::notice title=Not a release::", StringComparison.Ordinal));
            Assert.True(notice is not null && notice.Contains("SiteBlockBuildNumber", StringComparison.Ordinal) && notice.Contains("windows/version.props", StringComparison.Ordinal), "the notice must name SiteBlockBuildNumber in windows/version.props; " + result);
            Assert.True(ErrorLines(result).Count == 0, result.ToString());
            AssertDownloadFromWindowsLatest(run, "skip");
        }
    }

    // A lower new build, a published build written as text, and a failed download each stop the step with an error annotation and write no decision. NODOWNLOAD makes
    // the stand-in gh fail.
    [PwshTheory]
    [InlineData("93", "94", "a lower build")]
    [InlineData("95", "\"94\"", "a malformed published file")]
    [InlineData("95", "NODOWNLOAD", "a failed download")]
    public void DecideStep_LowerBuildMalformedPublishedFileOrFailedDownload_StopsTheRunWithoutADecision(string newBuild, string published, string context)
    {
        var (result, run) = RunDecide(newBuild, published == "NODOWNLOAD" ? null : published);
        using (run)
        {
            Assert.True(result.ExitCode != 0, $"{context}: the step must fail; {result}");
            Assert.True(ErrorLines(result).Count > 0, $"{context}: the step must write an ::error annotation; {result}");
            Assert.True(!run.OutputLines.Any(line => line.StartsWith("decision=", StringComparison.Ordinal)), $"{context}: no decision may be written: {string.Join(" | ", run.OutputLines)}");
            AssertDownloadFromWindowsLatest(run, context);
        }
    }

    // 06 step 3: the check runs on every push (no `if:`), after package.ps1 and before the release is decided, and stops the run for a packaged build of 0 or less.
    [Fact]
    public void CheckTheBuildNumberStep_RunsOnEveryPushAfterThePackageAndBeforeTheDecision()
    {
        var check = Named("Check the build number");
        Assert.Null(check.Condition);
        int package = Steps.FindIndex(step => step.Text.Contains("windows/scripts/package.ps1", StringComparison.Ordinal));
        int at = Steps.IndexOf(check);
        int decide = Steps.FindIndex(step => step.Name == "Decide whether this is a release");
        Assert.True(package >= 0 && package < at && at < decide, $"order: package {package}, check {at}, decide {decide}");
    }

    [PwshTheory]
    [InlineData("0", false)]
    [InlineData("-1", false)]
    [InlineData("1", true)]
    [InlineData("94", true)]
    public void CheckTheBuildNumberStep_FailsForABuildOfZeroOrLessAndPassesAbove(string build, bool passes)
    {
        using var run = new WorkflowStepRun();
        run.WriteInTree(VersionFile, Version(build));
        var result = run.Run(Named("Check the build number"));
        if (passes) Assert.True(result.ExitCode == 0 && ErrorLines(result).Count == 0, $"build {build} must pass; {result}");
        else Assert.True(result.ExitCode != 0 && ErrorLines(result).Count > 0, $"build {build} must stop the run with an ::error line; {result}");
    }

    // 06 step 6: the new version's release is tagged windows-v<version>, holds both files, and is not marked latest. The design does not say whether <version> is the
    // file's `displayVersion` (1.0.7 here) or its `version` (1.0.95 here), so either is accepted; the two differ, so a tag built from anything else fails.
    [PwshFact]
    public void PublishStep_CreatesAWindowsVReleaseWithBothFilesNotMarkedLatest()
    {
        using var run = new WorkflowStepRun();
        run.WriteInTree(VersionFile, Version("95"));
        var result = run.Run(Named("Publish this version as a release"), releaseExists: false);
        Assert.True(result.ExitCode == 0, result.ToString());
        var creates = GhRelease(run, "create");
        Assert.True(creates.Count == 1, "expected one gh release create: " + Show(run.Calls));
        string[] create = creates[0];
        Assert.True(create.Length > 3 && (create[3] == "windows-v1.0.7" || create[3] == "windows-v1.0.95"), "the tag must be windows-v<version>: " + Show(creates));
        Assert.True(create.Contains(Zip) && create.Contains(VersionFile), "the release must hold both files: " + Show(creates));
        Assert.True(create.Contains("--latest=false") && !MarksLatest(create), "the release must not be marked latest: " + Show(creates));
        Assert.True(!run.Calls.Any(MarksLatest), "no call may mark a release latest: " + Show(run.Calls));
    }

    // 06 step 6: windows-latest gets the same two files, whether the release already exists (its files are replaced) or not (it is created), and is never marked latest.
    [PwshTheory]
    [InlineData(true)]
    [InlineData(false)]
    public void UpdateWindowsLatestStep_GivesWindowsLatestBothFilesAndNeverMarksItLatest(bool releaseExists)
    {
        using var run = new WorkflowStepRun();
        run.WriteInTree(VersionFile, Version("95"));
        var result = run.Run(Named("Update the windows-latest release"), releaseExists: releaseExists);
        Assert.True(result.ExitCode == 0, result.ToString());
        var filed = GhRelease(run, "upload").Concat(GhRelease(run, "create")).Where(call => call.Length > 3 && call[3] == "windows-latest").ToList();
        Assert.True(filed.Count == 1 && filed[0].Contains(Zip) && filed[0].Contains(VersionFile), "windows-latest must get both files in one upload or create: " + Show(run.Calls));
        if (releaseExists) Assert.True(GhRelease(run, "create").Count == 0 && filed[0][2] == "upload", "an existing windows-latest must have its files replaced, not a second release made: " + Show(run.Calls));
        foreach (var call in GhRelease(run, "create").Concat(GhRelease(run, "edit")))
        {
            Assert.True(call.Contains("--latest=false") && !MarksLatest(call), "each create or edit must say --latest=false: " + Show([call]));
        }
        Assert.True(!run.Calls.Any(MarksLatest), "no call may mark a release latest: " + Show(run.Calls));
    }
}

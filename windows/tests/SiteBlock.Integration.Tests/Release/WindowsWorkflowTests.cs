namespace SiteBlock.Integration.Tests.Release;

// .github/workflows/windows.yml read as text. Expected values: 06-windows.md § Install, Package and Release (GitHub workflow): the checkout takes only the newest commit
// (no fetch-depth 0, because the release number is read from version.props); a step named "Decide whether this is a release" with id `decide` runs only on master and runs
// windows/scripts/release-check.ps1 on the freshly built and the published version-windows.json; "Publish this version as a release", "Update the windows-latest release" and
// every other step that changes a release or a tag run only when `steps.decide.outputs.decision == 'release'`; there is no "Check the first release is 1.0.0" step.
public sealed class WindowsWorkflowTests
{
    private const string Gate = "steps.decide.outputs.decision == 'release'";
    private static readonly string Text = File.ReadAllText(Repo.InRoot(".github/workflows/windows.yml"));
    private static readonly List<WorkflowStep> Steps = Workflow.Steps(Text);

    private static WorkflowStep Named(string name) => Steps.SingleOrDefault(step => step.Name == name) ?? throw new Xunit.Sdk.XunitException($"no single step named '{name}'; steps: {string.Join(" | ", Steps.Select(step => step.Name))}");

    private static int IndexOf(string name) => Steps.FindIndex(step => step.Name == name);

    // True when a trimmed workflow line sets fetch-depth to 0 (the full history), quoted or not, with or without a trailing comment.
    private static bool AsksForFullHistory(string line) => System.Text.RegularExpressions.Regex.IsMatch(line, "^fetch-depth:\\s*['\"]?0['\"]?\\s*(#.*)?$");

    // The pattern also catches a quoted 0 and a 0 followed by a comment; the self-check proves it, so a narrower pattern cannot pass by matching nothing.
    [Fact]
    public void Checkout_DoesNotFetchTheFullHistory()
    {
        Assert.Contains(Steps, step => step.Keys.TryGetValue("uses", out string? uses) && uses.StartsWith("actions/checkout@", StringComparison.Ordinal));
        var fullHistory = Text.Replace("\r\n", "\n").Split('\n').Select(line => line.Trim()).Where(AsksForFullHistory).ToList();
        Assert.Empty(fullHistory);
        Assert.All(["fetch-depth: 0", "fetch-depth: '0'", "fetch-depth: \"0\"", "fetch-depth: 0 # x", "fetch-depth:0#x"], spelling => Assert.True(AsksForFullHistory(spelling), "the pattern misses: " + spelling));
        Assert.All(["fetch-depth: 1", "fetch-depth: 10", "fetch-depth: 1 # 0"], spelling => Assert.False(AsksForFullHistory(spelling), "the pattern wrongly matches: " + spelling));
    }

    // 06 step 6: no Windows release is ever marked latest (the Mac's updater reads releases/latest). Every `gh release create` and `gh release edit` line in the workflow,
    // including the branches the step-run tests do not take, says --latest=false and nothing that marks it latest.
    [Fact]
    public void EveryReleaseCreateAndEditLine_SaysLatestFalse()
    {
        var lines = Text.Replace("\r\n", "\n").Split('\n').Where(line => line.Contains("gh release create", StringComparison.Ordinal) || line.Contains("gh release edit", StringComparison.Ordinal)).ToList();
        Assert.True(lines.Count >= 3, "expected the windows-v create and the windows-latest create and edit: " + string.Join(" | ", lines));
        foreach (string line in lines)
        {
            string[] words = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            Assert.True(words.Contains("--latest=false") && !words.Any(word => word == "--latest" || word.Equals("--latest=true", StringComparison.OrdinalIgnoreCase)), "this line must say --latest=false: " + line.Trim());
        }
    }

    // 06 step 6: the new version's release is tagged windows-v<version>: the publish step's create names a tag that is either written as "windows-v..." or held in a
    // variable the step sets to "windows-v...".
    [Fact]
    public void PublishStep_TagsTheReleaseWindowsV()
    {
        var publish = Named("Publish this version as a release");
        string create = publish.Text.Split('\n').Select(line => line.Trim()).FirstOrDefault(line => line.StartsWith("gh release create ", StringComparison.Ordinal)) ?? throw new Xunit.Sdk.XunitException("no gh release create in:\n" + publish.Text);
        string tag = create.Split(' ', StringSplitOptions.RemoveEmptyEntries)[3];
        bool literal = tag.Trim('"').StartsWith("windows-v", StringComparison.Ordinal);
        bool variable = tag.StartsWith('$') && publish.Text.Split('\n').Any(line => System.Text.RegularExpressions.Regex.IsMatch(line.Trim(), "^" + System.Text.RegularExpressions.Regex.Escape(tag) + "\\s*=\\s*\"windows-v\\$"));
        Assert.True(literal || variable, $"the tag must be windows-v<version>; create: {create}");
    }

    // The decide step: id `decide`, only on master, runs release-check.ps1 with the new file first and the downloaded published file second, and writes `decision=` to
    // $GITHUB_OUTPUT (that output is what the publishing steps read; without it nothing could ever be published).
    [Fact]
    public void DecideStep_HasIdDecideRunsOnlyOnMasterAndRunsTheReleaseCheck()
    {
        var decide = Named("Decide whether this is a release");
        Assert.Equal("decide", decide.Keys.GetValueOrDefault("id"));
        Assert.Equal("github.ref == 'refs/heads/master'", decide.Condition);
        string call = decide.Text.Split('\n').FirstOrDefault(line => line.Contains("windows/scripts/release-check.ps1", StringComparison.Ordinal)) ?? throw new Xunit.Sdk.XunitException("the decide step does not run release-check.ps1:\n" + decide.Text);
        string[] arguments = call[(call.IndexOf("windows/scripts/release-check.ps1", StringComparison.Ordinal) + "windows/scripts/release-check.ps1".Length)..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Assert.True(arguments.Length >= 2 && arguments[0] == "windows/dist/version-windows.json", "the new file must be the first argument: " + call);
        Assert.True(arguments[1].EndsWith("version-windows.json", StringComparison.Ordinal) && arguments[1] != arguments[0], "the published file must be the second argument: " + call);
        Assert.Contains("decision=", decide.Text, StringComparison.Ordinal);
        Assert.Contains("GITHUB_OUTPUT", decide.Text, StringComparison.Ordinal);
        Assert.Contains("gh release download windows-latest", decide.Text, StringComparison.Ordinal);
    }

    // The decision needs the packaged version-windows.json, so it runs after the package is built and before either publishing step.
    [Fact]
    public void DecideStep_RunsAfterThePackageIsBuiltAndBeforeBothPublishingSteps()
    {
        int package = Steps.FindIndex(step => step.Text.Contains("windows/scripts/package.ps1", StringComparison.Ordinal));
        int decide = IndexOf("Decide whether this is a release");
        int publish = IndexOf("Publish this version as a release");
        int latest = IndexOf("Update the windows-latest release");
        Assert.True(package >= 0 && decide > package && publish > decide && latest > decide, $"order: package {package}, decide {decide}, publish {publish}, windows-latest {latest}");
    }

    [Theory]
    [InlineData("Publish this version as a release")]
    [InlineData("Update the windows-latest release")]
    public void NamedPublishingStep_RunsOnlyWhenTheDecisionIsRelease(string name) => Assert.Equal(Gate, Named(name).Condition);

    // Every step that changes a release or a tag on GitHub (gh release create/delete/upload/edit, git tag, git push) is gated, whatever its name. The decide step's own
    // `gh release download` only reads.
    [Fact]
    public void EveryStepThatPublishes_RunsOnlyWhenTheDecisionIsRelease()
    {
        string[] writes = ["gh release create", "gh release delete", "gh release upload", "gh release edit", "git tag", "git push"];
        var publishing = Steps.Where(step => writes.Any(write => step.Text.Contains(write, StringComparison.Ordinal))).ToList();
        Assert.True(publishing.Count >= 2, "expected at least the two publishing steps: " + string.Join(" | ", publishing.Select(step => step.Name)));
        foreach (var step in publishing) Assert.True(step.Condition == Gate, $"step '{step.Name}' has if: {step.Condition ?? "<none>"}");
    }

    [Fact]
    public void TheFirstReleaseCheckStepIsGone() => Assert.DoesNotContain(Steps, step => step.Name == "Check the first release is 1.0.0");
}

// A check of the step parser itself, so the workflow tests cannot pass because the parser found nothing or read a key from inside a script.
public sealed class WorkflowParserTests
{
    [Fact]
    public void Parser_ReadsStepLevelKeysAndIgnoresKeysInsideScriptsAndComments()
    {
        const string text = """
            jobs:
              a:
                steps:
                  - name: First
                    id: one
                    # if: commented-out
                    run: |
                      echo "if: inside the script"
                      id: also-inside
                  - name: Second
                    if: ${{ steps.one.outputs.x == 'y' }}
                    with:
                      if: nested
              b:
                steps:
                  - uses: actions/checkout@v6
                  - name: Third
                    run: gh release create x
            """;
        var steps = Workflow.Steps(text);
        Assert.Equal(["First", "Second", "", "Third"], steps.Select(step => step.Name));
        Assert.Equal("one", steps[0].Keys["id"]);
        Assert.Null(steps[0].Condition);
        Assert.Equal("steps.one.outputs.x == 'y'", steps[1].Condition);
        Assert.DoesNotContain("b:", steps[1].Text, StringComparison.Ordinal);
        Assert.Equal("actions/checkout@v6", steps[2].Keys["uses"]);
        // RunScript reads the block under `run: |` with its indentation removed, reads an inline `run:`, and finds none in a step without one.
        Assert.Equal("echo \"if: inside the script\"\nid: also-inside\n", steps[0].RunScript);
        Assert.Equal("gh release create x\n", steps[3].RunScript);
        Assert.Null(steps[1].RunScript);
    }
}

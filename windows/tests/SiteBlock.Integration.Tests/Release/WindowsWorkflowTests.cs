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

    [Fact]
    public void Checkout_DoesNotFetchTheFullHistory()
    {
        Assert.Contains(Steps, step => step.Keys.TryGetValue("uses", out string? uses) && uses.StartsWith("actions/checkout@", StringComparison.Ordinal));
        var fullHistory = Text.Replace("\r\n", "\n").Split('\n').Select(line => line.Trim()).Where(line => System.Text.RegularExpressions.Regex.IsMatch(line, "^fetch-depth:\\s*['\"]?0['\"]?$")).ToList();
        Assert.Empty(fullHistory);
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
    }
}

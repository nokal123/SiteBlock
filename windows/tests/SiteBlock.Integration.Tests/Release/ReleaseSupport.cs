using System.Diagnostics;
using System.Text;

namespace SiteBlock.Integration.Tests.Release;

// Where the repository's files are, found from this source file's own location (the build may put the test assembly anywhere, such as an artifacts folder).
internal static class Repo
{
    // The windows/ folder: the first folder above this file that holds version.props and SiteBlock.sln.
    public static string Windows { get; } = FindWindows();

    // The repository root, the folder that holds windows/.
    public static string Root => Path.GetDirectoryName(Windows)!;

    // A path under windows/, written with forward slashes.
    public static string InWindows(string relative) => Path.Combine(Windows, relative.Replace('/', Path.DirectorySeparatorChar));

    // A path under the repository root, written with forward slashes.
    public static string InRoot(string relative) => Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));

    private static string FindWindows([System.Runtime.CompilerServices.CallerFilePath] string sourceFile = "")
    {
        for (var folder = new FileInfo(sourceFile).Directory; folder is not null; folder = folder.Parent)
        {
            if (File.Exists(Path.Combine(folder.FullName, "version.props")) && File.Exists(Path.Combine(folder.FullName, "SiteBlock.sln"))) return folder.FullName;
        }
        throw new InvalidOperationException("could not find the windows/ folder above " + sourceFile);
    }
}

// A fresh empty folder in the system's temporary folder, deleted when disposed.
internal sealed class TempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "sbrel-" + Guid.NewGuid().ToString("N")[..10]);

    public TempFolder() => Directory.CreateDirectory(Path);

    // A path inside the folder, written with forward slashes.
    public string File(string relative) => System.IO.Path.Combine(Path, relative.Replace('/', System.IO.Path.DirectorySeparatorChar));

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

// The result of one finished child process.
internal sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
    public override string ToString() => $"exit {ExitCode}, stdout '{StandardOutput}', stderr '{StandardError}'";
}

// Finds PowerShell 7 (pwsh) on the PATH and runs programs as child processes.
internal static class Processes
{
    // The full path of pwsh (pwsh.exe on Windows) on the PATH, or null when there is none. GitHub's Windows runner has it; a Mac needs it installed and on the PATH.
    public static string? Pwsh { get; } = FindOnPath(OperatingSystem.IsWindows() ? "pwsh.exe" : "pwsh");

    // The dotnet executable that is running this test process (falls back to "dotnet" on the PATH).
    public static string Dotnet
    {
        get
        {
            string? fromEnvironment = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
            if (!string.IsNullOrEmpty(fromEnvironment) && System.IO.File.Exists(fromEnvironment)) return fromEnvironment;
            string? self = Environment.ProcessPath;
            if (self is not null && Path.GetFileNameWithoutExtension(self).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) return self;
            return FindOnPath(OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet") ?? "dotnet";
        }
    }

    // The first PATH folder that holds a file of that name, as a full path, or null.
    private static string? FindOnPath(string name)
    {
        foreach (string folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(folder.Trim('"'), name);
            if (System.IO.File.Exists(candidate)) return candidate;
        }
        return null;
    }

    // Runs a program to completion and returns its exit code and output. Fails the test when it runs longer than the limit. `environment` sets (or, with a null value,
    // removes) variables on top of this process's own environment.
    public static ProcessResult Run(string program, IEnumerable<string> arguments, string? workingDirectory = null, double timeoutSeconds = 120, IReadOnlyDictionary<string, string?>? environment = null)
    {
        var info = new ProcessStartInfo(program) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        if (workingDirectory is not null) info.WorkingDirectory = workingDirectory;
        foreach (var (name, value) in environment ?? new Dictionary<string, string?>())
        {
            if (value is null) info.Environment.Remove(name); else info.Environment[name] = value;
        }
        info.StandardOutputEncoding = Encoding.UTF8;
        info.StandardErrorEncoding = Encoding.UTF8;
        using var process = Process.Start(info) ?? throw new InvalidOperationException("could not start " + program);
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        process.StandardInput.Close();
        if (!process.WaitForExit(TimeSpan.FromSeconds(timeoutSeconds)))
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw new TimeoutException($"{Path.GetFileName(program)} {string.Join(' ', arguments)} did not finish within {timeoutSeconds} s");
        }
        if (!Task.WaitAll([output, error], TimeSpan.FromSeconds(10))) throw new TimeoutException("the program's output did not close after it exited");
        return new ProcessResult(process.ExitCode, output.Result, error.Result);
    }

    // Runs a PowerShell script file with pwsh, without the user's profile, as the workflow does.
    public static ProcessResult RunPwshScript(string script, params string[] arguments) =>
        Run(Pwsh ?? throw new InvalidOperationException("pwsh is not on the PATH"), ["-NoProfile", "-NonInteractive", "-File", script, .. arguments]);
}

// Runs a test only when pwsh is on the PATH, and says so plainly when it is not. With `unixOnly`, it also skips on Windows.
public sealed class PwshFactAttribute : FactAttribute
{
    public PwshFactAttribute(bool unixOnly = false, string unixOnlyReason = "")
    {
        if (Processes.Pwsh is null) Skip = "pwsh (PowerShell 7) is not on the PATH; install it or put it on the PATH to run the Windows script tests.";
        else if (unixOnly && OperatingSystem.IsWindows()) Skip = unixOnlyReason;
    }
}

// The theory form of PwshFactAttribute.
public sealed class PwshTheoryAttribute : TheoryAttribute
{
    public PwshTheoryAttribute(bool unixOnly = false, string unixOnlyReason = "")
    {
        if (Processes.Pwsh is null) Skip = "pwsh (PowerShell 7) is not on the PATH; install it or put it on the PATH to run the Windows script tests.";
        else if (unixOnly && OperatingSystem.IsWindows()) Skip = unixOnlyReason;
    }
}

// One step of a GitHub workflow: its name, its step-level keys (id, if, uses, run, ...) and its whole text.
internal sealed record WorkflowStep(string Name, IReadOnlyDictionary<string, string> Keys, string Text)
{
    // The step's `if:` with an optional ${{ }} wrapper removed, so both spellings of one condition compare equal; null when the step has none.
    public string? Condition
    {
        get
        {
            if (!Keys.TryGetValue("if", out string? value)) return null;
            if (value.StartsWith("${{", StringComparison.Ordinal) && value.EndsWith("}}", StringComparison.Ordinal)) value = value[3..^2];
            return value.Trim();
        }
    }

    // The script of the step's own `run:` key: for `run: |`, the block under it with its common indentation removed (as YAML reads a literal block); otherwise the inline
    // value. Null when the step has no `run:` of its own. Comment lines are already gone from the step's text, which changes nothing a shell runs.
    public string? RunScript
    {
        get
        {
            string[] lines = Text.Split('\n');
            static int Spaces(string line) => line.Length - line.TrimStart(' ').Length;
            int keyColumn = Spaces(lines[0]) + 2;
            int at = Array.FindIndex(lines, 1, line => Spaces(line) == keyColumn && line.Trim().StartsWith("run:", StringComparison.Ordinal));
            if (at < 0) return null;
            string value = lines[at].Trim()[4..].Trim();
            if (value != "|") return value.Length == 0 ? null : value + "\n";
            var body = lines.Skip(at + 1).TakeWhile(line => line.Trim().Length == 0 || Spaces(line) > keyColumn).ToList();
            int indent = body.Where(line => line.Trim().Length > 0).Select(Spaces).DefaultIfEmpty(0).Min();
            return string.Join("\n", body.Select(line => line[Math.Min(indent, Spaces(line))..])).Trim('\n') + "\n";
        }
    }
}

// Runs one `run:` script of windows.yml for real with pwsh, the way GitHub runs a `shell: pwsh` step: the script is saved as a .ps1 file with
// `$ErrorActionPreference = 'stop'` put before it and `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }` after it, and started with
// `pwsh -command ". '<file>'"` in the checkout folder. Stand-ins for `gh` and `git` come first on the PATH; each records its call in a folder (one file per call, the words
// separated by NUL). They are PowerShell scripts (gh.ps1, git.ps1), which pwsh finds on the PATH under the plain names on every system and runs before a real gh.exe or
// git.exe further down the PATH, so the same stand-ins are tested on the Mac and on GitHub's Windows machine.
internal sealed class WorkflowStepRun : IDisposable
{
    // The fixed commit hash put in place of ${{ github.sha }}.
    public const string Sha = "0123456789abcdef0123456789abcdef01234567";

    // The stand-in gh: records the call; `release download` copies $env:STUB_SOURCE into the --dir folder under the --pattern name (or fails like a missing release when
    // $env:STUB_FAIL is set); `release view` succeeds only when $env:STUB_VIEW_EXISTS is 1 (the release exists); every other command succeeds and does nothing.
    private const string GhStub = """
        $n = @(Get-ChildItem -LiteralPath $env:STUB_CALLS).Count
        [System.IO.File]::WriteAllText((Join-Path $env:STUB_CALLS ('{0:D3}.args' -f $n)), ((@('gh') + @($args | ForEach-Object { "$_" })) -join "`0"))
        if ($args[0] -eq 'release' -and $args[1] -eq 'download') {
          if ($env:STUB_FAIL) { [Console]::Error.WriteLine('release not found (stub)'); exit 1 }
          $pattern = $null; $dir = '.'
          for ($i = 2; $i -lt $args.Count; $i++) { if ($args[$i] -in '--pattern', '-p') { $pattern = $args[++$i] } elseif ($args[$i] -in '--dir', '-D') { $dir = $args[++$i] } }
          if (-not $pattern) { exit 98 }
          Copy-Item -LiteralPath $env:STUB_SOURCE -Destination (Join-Path $dir $pattern) -Force
          exit 0
        }
        if ($args[0] -eq 'release' -and $args[1] -eq 'view') { if ($env:STUB_VIEW_EXISTS -eq '1') { exit 0 } else { exit 1 } }
        exit 0
        """;

    // The stand-in git: records the call and succeeds.
    private const string GitStub = """
        $n = @(Get-ChildItem -LiteralPath $env:STUB_CALLS).Count
        [System.IO.File]::WriteAllText((Join-Path $env:STUB_CALLS ('{0:D3}.args' -f $n)), ((@('git') + @($args | ForEach-Object { "$_" })) -join "`0"))
        exit 0
        """;

    private readonly TempFolder tools = new();

    // The checkout folder the step runs in. Tests put windows/scripts/... and windows/dist/... in it.
    public TempFolder Tree { get; } = new();

    public WorkflowStepRun()
    {
        Directory.CreateDirectory(tools.File("bin"));
        Directory.CreateDirectory(tools.File("calls"));
        File.WriteAllText(tools.File("bin/gh.ps1"), GhStub);
        File.WriteAllText(tools.File("bin/git.ps1"), GitStub);
        File.WriteAllText(tools.File("github-output"), "");
    }

    // Copies a real file of the repository (a path under windows/) into the same place in the checkout folder.
    public void CopyFromRepository(string windowsRelative)
    {
        string target = Tree.File("windows/" + windowsRelative);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
        File.Copy(Repo.InWindows(windowsRelative), target, overwrite: true);
    }

    // Writes a file into the checkout folder, making its folder first.
    public void WriteInTree(string relative, string text)
    {
        string target = Tree.File(relative);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
        File.WriteAllText(target, text);
    }

    // The file the stand-in gh copies on `release download`.
    public void SetPublishedSource(string text) => File.WriteAllText(tools.File("published-source.json"), text);

    // Runs the step's real script. `failDownload` makes `gh release download` fail; `releaseExists` makes `gh release view` succeed.
    public ProcessResult Run(WorkflowStep step, bool failDownload = false, bool releaseExists = false)
    {
        string script = step.RunScript ?? throw new Xunit.Sdk.XunitException($"step '{step.Name}' has no run: script");
        script = script.Replace("${{ github.sha }}", Sha, StringComparison.Ordinal).Replace("${{ github.token }}", "stub-token", StringComparison.Ordinal);
        if (script.Contains("${{", StringComparison.Ordinal)) throw new Xunit.Sdk.XunitException($"step '{step.Name}' holds a ${{{{ }}}} expression this test does not fill in:\n{script}");
        string file = tools.File("step.ps1");
        File.WriteAllText(file, "$ErrorActionPreference = 'stop'\n" + script + "\nif ((Test-Path -LiteralPath variable:\\LASTEXITCODE)) { exit $LASTEXITCODE }\n");
        var environment = new Dictionary<string, string?>
        {
            ["PATH"] = tools.File("bin") + System.IO.Path.PathSeparator + Environment.GetEnvironmentVariable("PATH"),
            ["GITHUB_OUTPUT"] = tools.File("github-output"),
            ["GH_TOKEN"] = "stub-token",
            ["STUB_CALLS"] = tools.File("calls"),
            ["STUB_SOURCE"] = tools.File("published-source.json"),
            ["STUB_FAIL"] = failDownload ? "1" : null,
            ["STUB_VIEW_EXISTS"] = releaseExists ? "1" : null,
        };
        string pwsh = Processes.Pwsh ?? throw new InvalidOperationException("pwsh is not on the PATH");
        return Processes.Run(pwsh, ["-NoProfile", "-NonInteractive", "-Command", $". '{file}'"], Tree.Path, environment: environment);
    }

    // The non-empty lines the step wrote to $GITHUB_OUTPUT, with a leading byte-order mark removed (GitHub's reader skips one).
    public List<string> OutputLines => System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(tools.File("github-output"))).TrimStart('﻿').Replace("\r\n", "\n").Split('\n').Where(line => line.Length > 0).ToList();

    // Every recorded call, in order, each as its words with the program name first ("gh" or "git").
    public List<string[]> Calls => Directory.GetFiles(tools.File("calls")).Order(StringComparer.Ordinal).Select(file => File.ReadAllText(file).Split('\0')).ToList();

    public void Dispose()
    {
        Tree.Dispose();
        tools.Dispose();
    }
}

// Splits a GitHub workflow into its steps, in order, across every job.
internal static class Workflow
{
    // A `steps:` line opens a list; each line that starts with "- " at the list's dash column starts a step (named or not); a line at or left of the `steps:` column closes
    // the list. A step's keys are its first line's key and the lines exactly two columns past the dash, so a key that only appears inside a `run:` script or a `with:` block
    // is never mistaken for one. Comment lines are dropped.
    public static List<WorkflowStep> Steps(string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n').Where(line => !line.TrimStart().StartsWith('#')).ToList();
        var raw = new List<(int Indent, List<string> Lines)>();
        int? stepsColumn = null, dashColumn = null;
        bool open = false;
        foreach (string line in lines)
        {
            string trimmed = line.Trim();
            int indent = line.Length - line.TrimStart(' ').Length;
            if (trimmed.Length == 0) { if (open) raw[^1].Lines.Add(line); continue; }
            if (trimmed == "steps:") { stepsColumn = indent; dashColumn = null; open = false; continue; }
            if (stepsColumn is null) continue;
            if (indent <= stepsColumn) { stepsColumn = null; open = false; continue; }
            if (trimmed.StartsWith("- ", StringComparison.Ordinal) && (dashColumn is null || indent == dashColumn))
            {
                dashColumn = indent;
                raw.Add((indent, [line]));
                open = true;
            }
            else if (open) raw[^1].Lines.Add(line);
        }
        return raw.Select(step =>
        {
            var keys = new Dictionary<string, string>(StringComparer.Ordinal);
            void Record(string trimmed)
            {
                int colon = trimmed.IndexOf(':');
                if (colon > 0) keys[trimmed[..colon]] = trimmed[(colon + 1)..].Trim();
            }
            Record(step.Lines[0].Trim()[2..]);
            foreach (string line in step.Lines.Skip(1).Where(line => line.Length - line.TrimStart(' ').Length == step.Indent + 2)) Record(line.Trim());
            return new WorkflowStep(keys.GetValueOrDefault("name", ""), keys, string.Join("\n", step.Lines));
        }).ToList();
    }
}

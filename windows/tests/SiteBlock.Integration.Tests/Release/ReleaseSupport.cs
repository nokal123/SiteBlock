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

    // Runs a program to completion and returns its exit code and output. Fails the test when it runs longer than the limit.
    public static ProcessResult Run(string program, IEnumerable<string> arguments, string? workingDirectory = null, double timeoutSeconds = 120)
    {
        var info = new ProcessStartInfo(program) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        if (workingDirectory is not null) info.WorkingDirectory = workingDirectory;
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

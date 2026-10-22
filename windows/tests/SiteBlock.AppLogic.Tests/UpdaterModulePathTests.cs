using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using SiteBlock.AppLogic;

namespace SiteBlock.AppLogic.Tests;

// The elevated update script's first step: it sets PSModulePath (the folders Windows PowerShell loads commands from) to Windows PowerShell's own two folders,
// %ProgramFiles%\WindowsPowerShell\Modules and %SystemRoot%\System32\WindowsPowerShell\v1.0\Modules, as a fixed list, before anything else runs, and install.ps1 inherits it.
// Expected values come from 06-windows.md § Updater (Installing, step 3).
public sealed class UpdaterModulePathTests
{
    private const string Sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string DownloadedZip = @"C:\Users\Dana\AppData\Local\Temp\SiteBlockUpdate-1a2b\SiteBlock-Windows.zip";
    private const string ProgramFiles = @"C:\Program Files";
    private const string SystemRoot = @"C:\Windows";
    private const string WantedPath = @"C:\Program Files\WindowsPowerShell\Modules;C:\Windows\System32\WindowsPowerShell\v1.0\Modules";

    private static List<string> Lines(string architecture) =>
        [.. UpdatePackage.ElevatedScript(DownloadedZip, Sha, architecture).Split('\n').Select(line => line.TrimEnd('\r').Trim())];

    // The one line that mentions PSModulePath; fails when there is none or more than one, because a second line would change what install.ps1 inherits.
    private static int ModulePathLine(List<string> lines)
    {
        var found = Enumerable.Range(0, lines.Count).Where(i => lines[i].Contains("PSModulePath", StringComparison.OrdinalIgnoreCase)).ToList();
        Assert.True(found.Count == 1, $"expected exactly one line naming PSModulePath, found {found.Count}:\n{string.Join('\n', lines)}");
        return found[0];
    }

    // Works out the value a PowerShell expression gives, for the few forms a path list is written in: 'text', "text with $env:Name", (Join-Path $env:Name 'text') and
    // + between them. Join-Path puts exactly one backslash between its two parts. Any other form fails the test rather than being guessed at.
    internal static string Evaluate(string expression, IReadOnlyDictionary<string, string> env)
    {
        var term = new Regex(@"\G\s*(?:\(Join-Path \$env:(?<jp>\w+) '(?<jl>[^']*)'\)|'(?<lit>[^']*)'|""(?<dq>[^""]*)"")\s*(?:\+|$)");
        var result = new StringBuilder();
        int at = 0;
        while (at < expression.Length)
        {
            Match match = term.Match(expression, at);
            Assert.True(match.Success && match.Length > 0, $"cannot evaluate the PSModulePath value from position {at}: {expression}");
            if (match.Groups["jp"].Success) result.Append(env[match.Groups["jp"].Value].TrimEnd('\\')).Append('\\').Append(match.Groups["jl"].Value.TrimStart('\\'));
            else if (match.Groups["lit"].Success) result.Append(match.Groups["lit"].Value);
            else result.Append(Regex.Replace(match.Groups["dq"].Value, @"\$env:(\w+)", name => env[name.Groups[1].Value]));
            at += match.Length;
        }
        return result.ToString();
    }

    [Theory]
    [InlineData("x64")]
    [InlineData("arm64")]
    public void Script_SetsPSModulePathToExactlyWindowsPowerShellsTwoFolders(string architecture)
    {
        var lines = Lines(architecture);
        string line = lines[ModulePathLine(lines)];

        Match assignment = Regex.Match(line, @"^\$env:PSModulePath\s*=\s*(?<value>.+)$", RegexOptions.IgnoreCase);
        Assert.True(assignment.Success, $"the PSModulePath line is not an assignment: {line}");
        // The value is a fixed list: the machine's own setting (which a PowerShell 7 install may have changed) is never read into it.
        Assert.DoesNotContain("PSModulePath", assignment.Groups["value"].Value, StringComparison.OrdinalIgnoreCase);
        var env = new Dictionary<string, string> { ["ProgramFiles"] = ProgramFiles, ["SystemRoot"] = SystemRoot };
        Assert.Equal(WantedPath, Evaluate(assignment.Groups["value"].Value, env));
    }

    [Fact]
    public void Script_SetsPSModulePathBeforeAnyCommandRuns()
    {
        var lines = Lines("x64");
        int modulePath = ModulePathLine(lines);

        // Everything before it only stores a constant in a variable (such as $ErrorActionPreference = 'Stop'); no command can load a module before the path is fixed.
        var constantAssignment = new Regex(@"^\$\w+\s*=\s*('[^']*'|\$null|\$true|\$false|\d+)$");
        Assert.All(lines.Take(modulePath).Where(line => line.Length > 0 && !line.StartsWith('#')), line => Assert.Matches(constantAssignment, line));
        // The commands the design names, each of which must come after it.
        foreach (string command in new[] { "Get-FileHash", "Add-Type", "icacls", "Copy-Item", "ExtractToDirectory", "-File $installer" })
        {
            int first = lines.FindIndex(line => line.Contains(command, StringComparison.OrdinalIgnoreCase));
            Assert.True(first > modulePath, $"{command} is used at line {first}, not after the PSModulePath line {modulePath}");
        }
    }

    [WindowsOnlyFact]
    public void Script_OnWindows_FirstLinesLeaveExactlyTheTwoFoldersAndGetFileHashWorksFromAPowerShell7Environment()
    {
        var lines = Lines("x64");
        int modulePath = ModulePathLine(lines);
        string file = Path.Combine(Path.GetTempPath(), "sbmodpath-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(file, "SiteBlock module path test");
        try
        {
            // The script's own lines up to the PSModulePath line, then a look at the result and the command the design says breaks without it.
            string probe = string.Join("\n", lines.Take(modulePath + 1)) + "\nWrite-Output $env:PSModulePath\nWrite-Output (Get-FileHash -LiteralPath '" + file.Replace("'", "''") + "' -Algorithm SHA256).Hash\n";
            var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"), "-NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(probe)))
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            // A process started from PowerShell 7 carries 7's module folders first; this is the case the line exists for.
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            start.Environment["PSModulePath"] = Path.Combine(programFiles, @"PowerShell\7\Modules") + ";" + Path.Combine(programFiles, @"PowerShell\Modules");
            using var process = Process.Start(start)!;
            string output = process.StandardOutput.ReadToEnd();
            string errors = process.StandardError.ReadToEnd();
            Assert.True(process.WaitForExit(60_000), "powershell.exe did not finish within 60 s");
            var outputLines = output.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0).ToList();
            string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            Assert.True(outputLines.Count >= 2, $"unexpected output:\n{output}\n{errors}");
            Assert.Equal(Path.Combine(programFiles, @"WindowsPowerShell\Modules") + ";" + Path.Combine(systemRoot, @"System32\WindowsPowerShell\v1.0\Modules"), outputLines[^2]);
            Assert.Equal(Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file))), outputLines[^1], ignoreCase: true);
        }
        finally
        {
            File.Delete(file);
        }
    }

    // Runs a test only on Windows, where powershell.exe exists, with the reason shown elsewhere.
    private sealed class WindowsOnlyFactAttribute : FactAttribute
    {
        public WindowsOnlyFactAttribute()
        {
            if (!OperatingSystem.IsWindows()) Skip = "Windows PowerShell 5.1 (powershell.exe) exists only on Windows";
        }
    }
}

// The script the real Updater hands to the elevated PowerShell (decoded from its -EncodedCommand argument) starts with the same PSModulePath line, for this PC's processor.
public sealed class UpdaterModulePathInstallTests : UpdaterTestBase
{
    [Fact]
    public async Task Install_ElevatedScriptsFirstCommandSetsPSModulePathToTheTwoFolders()
    {
        byte[] package = Fixtures.Zip(Fixtures.PackageEntries());
        Updater updater = await ReadyToInstall(package);

        await updater.InstallAsync();

        var (_, arguments) = Assert.Single(Runner.Runs);
        var lines = FakeElevatedRunner.DecodeScript(arguments).Split('\n').Select(line => line.TrimEnd('\r').Trim()).Where(line => line.Length > 0 && !line.StartsWith('#')).ToList();
        int first = lines.FindIndex(line => !Regex.IsMatch(line, @"^\$\w+\s*=\s*('[^']*'|\$null|\$true|\$false|\d+)$"));
        Assert.True(first >= 0, "the script runs no command at all");
        Assert.StartsWith("$env:PSModulePath", lines[first], StringComparison.OrdinalIgnoreCase);
        Assert.Single(lines, line => line.Contains("PSModulePath", StringComparison.OrdinalIgnoreCase));
        string value = lines[first][(lines[first].IndexOf('=') + 1)..];
        var env = new Dictionary<string, string> { ["ProgramFiles"] = @"D:\Apps", ["SystemRoot"] = @"D:\Win" };
        Assert.Equal(@"D:\Apps\WindowsPowerShell\Modules;D:\Win\System32\WindowsPowerShell\v1.0\Modules", UpdaterModulePathTests.Evaluate(value, env));
    }
}

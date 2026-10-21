using System.Diagnostics;
using System.Reflection;
using System.Text;

namespace SiteBlock.Integration.Tests.Support;

// The output of one finished child process.
internal sealed record ProgramResult(int ExitCode, string StandardOutput, string StandardError);

// Finds the real built siteblockd and siteblock programs and runs them as child processes.
internal static class Programs
{
    // The siteblockd .dll path the build recorded in this test assembly's metadata.
    public static string DaemonDll => Recorded("siteblockd");

    // The siteblock (CLI) .dll path the build recorded in this test assembly's metadata.
    public static string CliDll => Recorded("siteblock");

    // Reads the path the csproj target wrote as "SiteBlockProgram.<name>" and checks that the file exists.
    private static string Recorded(string name)
    {
        string? path = typeof(Programs).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(attribute => attribute.Key == "SiteBlockProgram." + name)?.Value;
        if (path is null || !File.Exists(path)) throw new InvalidOperationException($"The build did not record a usable path for {name} (got '{path}').");
        return path;
    }

    // A start description that runs the program's .dll through the dotnet host that runs these tests, so the same runtime is used on macOS and Windows.
    public static ProcessStartInfo StartInfo(string dll, IEnumerable<string> arguments, IDictionary<string, string?>? environment = null)
    {
        var info = new ProcessStartInfo(DotnetHost()) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add(dll);
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        info.StandardOutputEncoding = Encoding.UTF8;
        info.StandardErrorEncoding = Encoding.UTF8;
        // A sandbox client must never fall back to the real installed service by accident.
        info.Environment.Remove("SITEBLOCK_PIPE");
        if (environment is not null) foreach (var (key, value) in environment) info.Environment[key] = value;
        return info;
    }

    // The dotnet executable that is running this test process (falls back to "dotnet" on the PATH).
    private static string DotnetHost()
    {
        string? fromEnvironment = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
        if (!string.IsNullOrEmpty(fromEnvironment) && File.Exists(fromEnvironment)) return fromEnvironment;
        string? self = Environment.ProcessPath;
        if (self is not null && Path.GetFileNameWithoutExtension(self).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) return self;
        return "dotnet";
    }

    // Runs a program to completion with the given standard input, and returns its exit code and output. Fails the test when it runs longer than the limit.
    public static ProgramResult Run(string dll, IEnumerable<string> arguments, string? standardInput = null, IDictionary<string, string?>? environment = null, double timeoutSeconds = 30)
    {
        using var process = Process.Start(StartInfo(dll, arguments, environment)) ?? throw new InvalidOperationException("could not start " + dll);
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (standardInput is not null) process.StandardInput.Write(standardInput);
        process.StandardInput.Close();
        if (!process.WaitForExit(TimeSpan.FromSeconds(timeoutSeconds)))
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw new TimeoutException($"{Path.GetFileName(dll)} {string.Join(' ', arguments)} did not finish within {timeoutSeconds} s");
        }
        // The process has exited; its output pipes close with it, so these finish promptly.
        bool drained = Task.WaitAll([output, error], TimeSpan.FromSeconds(10));
        if (!drained) throw new TimeoutException("the program's output did not close after it exited");
        return new ProgramResult(process.ExitCode, output.Result, error.Result);
    }

    // Runs the real siteblock CLI against the sandbox pipe at the given path.
    public static ProgramResult Cli(string pipePath, IEnumerable<string> arguments, string? standardInput = null) =>
        Run(CliDll, arguments, standardInput, new Dictionary<string, string?> { ["SITEBLOCK_PIPE"] = pipePath });

    // Runs the real siteblockd with the given flags and waits for it to exit (for flag errors and --version).
    public static ProgramResult Daemon(params string[] arguments) => Run(DaemonDll, arguments);
}

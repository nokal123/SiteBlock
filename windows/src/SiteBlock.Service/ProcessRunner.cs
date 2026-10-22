using System.Diagnostics;

namespace SiteBlock.Service;

/// <summary>How a finished child program ended and what it printed.</summary>
/// <param name="ExitCode">The exit code, 127 when the program could not be started, or 124 when it was stopped for running too long.</param>
/// <param name="Output">Everything it wrote to standard output.</param>
/// <param name="Error">Everything it wrote to standard error.</param>
public sealed record ProcessResult(int ExitCode, string Output, string Error)
{
    /// True when the program exited with code 0.
    public bool Succeeded => ExitCode == 0;
}

/// <summary>
/// Runs an external program (such as sc.exe) with a time limit, and kills it when it runs too long, so a stuck tool can never stall the service.
/// </summary>
public static class ProcessRunner
{
    /// Runs the program with the arguments given one by one (each is quoted for the command line as needed) and waits at most the timeout.
    public static ProcessResult Run(string fileName, IEnumerable<string> arguments, TimeSpan timeout)
    {
        var info = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        return Run(info, timeout);
    }

    /// Runs the program with one ready-made command line, for tools such as sc.exe that need their quotes exactly as written.
    public static ProcessResult RunRaw(string fileName, string commandLine, TimeSpan timeout)
    {
        var info = new ProcessStartInfo(fileName, commandLine)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        return Run(info, timeout);
    }

    /// Starts the program, reads both outputs to the end on their own tasks (so a full pipe can't block the child), and kills the whole process tree on timeout.
    private static ProcessResult Run(ProcessStartInfo info, TimeSpan timeout)
    {
        Process process;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException("no process");
        }
        catch (Exception error)
        {
            return new ProcessResult(127, "", error.Message);
        }
        using (process)
        {
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeout))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                process.WaitForExit(2000);
                return new ProcessResult(124, SafeResult(output), SafeResult(errors));
            }
            // The outputs are read only after the readers finish, so a grandchild that keeps a pipe open cannot leave half-read text. The wait for the streams is capped at 2 seconds,
            // because such a grandchild could otherwise hold this thread for as long as it lives.
            process.WaitForExit(2000);
            return new ProcessResult(process.ExitCode, SafeResult(output), SafeResult(errors));
        }
    }

    /// Returns what a reader task collected, or empty text when it has not finished within a second.
    private static string SafeResult(Task<string> reader)
    {
        try { return reader.Wait(TimeSpan.FromSeconds(1)) ? reader.Result : ""; } catch { return ""; }
    }
}

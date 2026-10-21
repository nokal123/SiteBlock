using System.Text;
using SiteBlock.Core;

namespace SiteBlock.Cli;

/// <summary>The exit codes of the siteblock tool.</summary>
internal static class ExitCode
{
    /// The command worked.
    public const int Success = 0;
    /// The service refused the command (or the input could not be used); the reason is printed to standard error.
    public const int Refused = 1;
    /// The service is not running (the pipe does not exist or refuses the connection).
    public const int NotRunning = 2;
    /// The command line was wrong.
    public const int Usage = 64;
}

/// <summary>Reads passwords: from the console with nothing shown while typing, or, when input is redirected, from lines of standard input (how tests and scripts supply them).</summary>
internal static class PasswordPrompt
{
    /// <summary>True when a person is typing at a console, so the prompts and explanations are shown.</summary>
    public static bool IsInteractive => !Console.IsInputRedirected;

    /// <summary>
    /// Asks for one password. At a console it shows the prompt on standard error and reads keys with <c>Console.ReadKey(intercept: true)</c>, so nothing appears while typing;
    /// Backspace removes the last character, Enter ends the entry, and Ctrl+Z or Ctrl+D at the start gives null (Ctrl+C ends the program, as it does anywhere else). With redirected input it
    /// reads the next line. Spaces are kept.
    /// </summary>
    public static string? Read(string prompt)
    {
        if (!IsInteractive) return Console.In.ReadLine();
        Console.Error.Write(prompt);
        var typed = new StringBuilder();
        while (true)
        {
            ConsoleKeyInfo key;
            try { key = Console.ReadKey(intercept: true); }
            catch (InvalidOperationException) { return null; }
            if (key.Key == ConsoleKey.Enter) break;
            if (key.Key == ConsoleKey.Backspace)
            {
                if (typed.Length > 0) typed.Length--;
                continue;
            }
            // Ctrl+Z or Ctrl+D at the start of the entry means the end of input, which cancels.
            if ((key.KeyChar == '\u001a' || key.KeyChar == '\u0004') && typed.Length == 0)
            {
                Console.Error.WriteLine();
                return null;
            }
            if (!char.IsControl(key.KeyChar)) typed.Append(key.KeyChar);
        }
        Console.Error.WriteLine();
        return typed.ToString();
    }

    /// <summary>
    /// Asks for a new password twice and checks that both match. With redirected input the second line is the confirmation when there is one; a single line is used as it is.
    /// Returns null when nothing could be read; throws <see cref="InvalidOperationException"/> when the two entries differ.
    /// </summary>
    public static string? ReadNew(string prompt, string confirmPrompt)
    {
        string? first = Read(prompt);
        if (first is null) return null;
        string? second = Read(confirmPrompt);
        if (second is null) return IsInteractive ? null : first;
        if (first != second) throw new InvalidOperationException("mismatch");
        return first;
    }
}

/// <summary>
/// The siteblock command-line tool (06-windows.md § siteblock.exe CLI): the same commands, output, options and exit codes as the Mac's siteblock, talking to the service over its named pipe.
/// </summary>
internal static class Program
{
    /// <summary>The usage text shown for <c>siteblock help</c> and after a command-line mistake.</summary>
    internal const string UsageText =
        "usage:\n" +
        "  siteblock status\n" +
        "  siteblock setup                      asks for a new password twice\n" +
        "  siteblock add <site> [<site> ...]    the first time, asks you to choose the password\n" +
        "  siteblock add youtube.com/shorts     a path after the name blocks only that part of the site\n" +
        "  siteblock add --whole-site <link>    block the whole site even though the text has a path\n" +
        "  siteblock unblock <site>             asks for the password; a path unblocks that part of a site\n" +
        "  siteblock unblock <site> --for <duration> [--in <duration>]\n" +
        "                                       unblock for a limited time, for example --for 30m\n" +
        "                                       it opens after the unblock delay (or after --in, which can only be longer)\n" +
        "                                       and is blocked again when --for runs out; asks for the password\n" +
        "  siteblock cancel <site>              cancel a pending unblock, or end a temporary unblock (no password)\n" +
        "  siteblock delay                      show the current unblock delay\n" +
        "  siteblock delay <duration>           for example 45m or 2h; asks for the password\n" +
        "  siteblock delay --cancel\n" +
        "  siteblock passwd                     asks for the old and the new password\n" +
        "  siteblock uninstall                  asks for the password\n" +
        "  siteblock uninstall --cancel\n" +
        "  siteblock recover                    start the 48-hour password reset (from a terminal opened with \"Run as administrator\")\n" +
        "  siteblock recover --cancel\n" +
        "  siteblock version\n\n";

    /// <summary>Runs one command line and returns its exit code.</summary>
    private static int Main(string[] args)
    {
        var utf8 = new UTF8Encoding(false);
        // Piped input is read as UTF-8 and a leading byte-order mark (which Windows PowerShell 5.1 can add) is dropped, so a piped password hashes the same as a typed one.
        if (Console.IsInputRedirected) Console.SetIn(new StreamReader(Console.OpenStandardInput(), utf8, detectEncodingFromByteOrderMarks: true));
        // Sites and messages may hold non-ASCII text (the status line has an em dash), so output is UTF-8. At a console that means switching its code page, which is put back on exit.
        Encoding? previous = null;
        try
        {
            if (!Console.IsOutputRedirected || !Console.IsErrorRedirected)
            {
                previous = Console.OutputEncoding;
                Console.OutputEncoding = utf8;
            }
            if (Console.IsOutputRedirected) Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true });
            if (Console.IsErrorRedirected) Console.SetError(new StreamWriter(Console.OpenStandardError(), utf8) { AutoFlush = true });
        }
        catch (IOException)
        {
        }
        try
        {
            return Run(args);
        }
        finally
        {
            if (previous is not null) try { Console.OutputEncoding = previous; } catch (IOException) { }
        }
    }

    /// <summary>Dispatches one command line (everything after the program name) and returns the exit code.</summary>
    internal static int Run(IReadOnlyList<string> arguments)
    {
        if (arguments.Count == 0) return UsageFailure();
        string command = arguments[0];
        var rest = arguments.Skip(1).ToList();
        return command switch
        {
            "status" => rest.Count == 0 ? RunStatus() : UsageFailure("status takes no arguments"),
            "setup" => rest.Count == 0 ? RunSetup() : UsageFailure("setup takes no arguments"),
            "add" => RunAdd(rest),
            "unblock" => RunUnblock(rest),
            "cancel" => RunCancel(rest),
            "delay" => RunDelay(rest),
            "passwd" => rest.Count == 0 ? RunPasswd() : UsageFailure("passwd takes no arguments"),
            "uninstall" => RunUninstall(rest),
            "recover" => RunRecover(rest),
            "version" or "--version" => rest.Count == 0 ? RunVersion() : UsageFailure("version takes no arguments"),
            "help" or "--help" or "-h" => PrintUsage(),
            _ => UsageFailure($"unknown command '{command}'"),
        };
    }

    /// <summary>Prints the usage text to standard output and succeeds.</summary>
    private static int PrintUsage()
    {
        Console.Write(UsageText);
        return ExitCode.Success;
    }

    /// <summary>Writes a line to standard error.</summary>
    private static void PrintError(string message) => Console.Error.WriteLine(message);

    /// <summary>Prints a usage mistake (when there is one) and the usage text to standard error, and returns the usage exit code.</summary>
    private static int UsageFailure(string? message = null)
    {
        if (message is not null) PrintError($"siteblock: {message}");
        Console.Error.Write(UsageText);
        return ExitCode.Usage;
    }

    /// <summary>
    /// Sends one request. Returns the response when the service accepted it; otherwise prints why and returns null with the exit code to use: 2 when the service is not running,
    /// 1 for a refusal (the service's sentence) or any other connection problem.
    /// </summary>
    private static (Response? Response, int Code) Send(Request request, string prefix = "")
    {
        try
        {
            var response = new DaemonClient().Send(request);
            if (response.Ok) return (response, ExitCode.Success);
            PrintError(prefix + (response.Error ?? "The SiteBlock service refused the command."));
            return (null, ExitCode.Refused);
        }
        catch (DaemonClientException error) when (error.Error == ClientError.NotRunning)
        {
            PrintError(error.Message);
            return (null, ExitCode.NotRunning);
        }
        catch (DaemonClientException error)
        {
            PrintError(error.Message);
            return (null, ExitCode.Refused);
        }
        catch (ArgumentException)
        {
            // Only a sandbox pipe path can cause this: on macOS and Linux a path too long for a socket is refused by .NET before any connection is tried.
            PrintError("siteblock: the pipe path in SITEBLOCK_PIPE is not usable.");
            return (null, ExitCode.Refused);
        }
    }

    /// <summary>A whole number of seconds from the service, clamped into the range the formatting functions take.</summary>
    private static int Seconds(long value) => (int)Math.Clamp(value, 0, int.MaxValue);

    /// <summary>The line printed under a site or rule with a temporary unblock: when it opens and for how long while it waits, or how long until it is blocked again once open.</summary>
    internal static string TemporaryLine(TemporaryUnblockStatus temporary)
    {
        if (temporary.IsOpen) return $"    OPEN — blocks again in {Formatting.Compact(Seconds(temporary.SecondsRemaining))}";
        return $"    opens in {Formatting.Compact(Seconds(temporary.OpensInSeconds ?? 0))}, for {Formatting.Compact(Seconds(temporary.WindowSeconds))}";
    }

    /// <summary>
    /// The text <c>siteblock status</c> prints: the version and delay, each blocked site with its host count and any countdown, each blocked part of a site,
    /// the adult content filter line, then any pending delay change, uninstall, recovery or lockout.
    /// </summary>
    internal static string FormatStatus(StatusSnapshot status)
    {
        var lines = new List<string> { $"SiteBlock {status.Version} — unblock delay: {Formatting.Duration(Seconds(status.DelaySeconds))}" };
        if (!status.PasswordSet) lines.Add("No password yet. You choose it the first time you block a site.");
        var rules = status.BlockedPaths ?? [];
        if (status.Blocked.Count == 0)
        {
            // With only path rules in place, "No sites blocked." would sit right above the list of blocked parts, so it is said only when nothing at all is blocked.
            if (rules.Count == 0) lines.Add("No sites blocked.");
        }
        else
        {
            lines.Add($"Blocked sites ({status.Blocked.Count}):");
            foreach (var site in status.Blocked)
            {
                string line = $"  {site.Domain} ({site.Hosts.Count} {(site.Hosts.Count == 1 ? "host" : "hosts")})";
                if (site.UnblockSecondsRemaining is long seconds) line += $" — unblocks in {Formatting.Clock(Seconds(seconds))}";
                lines.Add(line);
                if (site.TemporaryUnblock is { } temporary) lines.Add(TemporaryLine(temporary));
            }
        }
        if (rules.Count > 0)
        {
            lines.Add($"Blocked parts of sites ({rules.Count}):");
            foreach (var rule in rules)
            {
                string line = $"  {rule.Rule}";
                if (rule.UnblockSecondsRemaining is long seconds) line += $" — unblocks in {Formatting.Clock(Seconds(seconds))}";
                lines.Add(line);
                if (rule.TemporaryUnblock is { } temporary) lines.Add(TemporaryLine(temporary));
            }
        }
        // The filter has no switch: a service that has it always reports it on. A service that sends nothing reads as false, and the line then says so instead of claiming protection.
        lines.Add(status.AdultFilterEnabled == true ? "Adult content filter: always on" : "Adult content filter: not provided by this version of the SiteBlock service");
        if (status.PendingDelay is { } pending) lines.Add($"Unblock delay will change to {Formatting.Duration(Seconds(pending.NewDelaySeconds))} in {Formatting.Clock(Seconds(pending.SecondsRemaining))}.");
        if (status.UninstallSecondsRemaining is long uninstall) lines.Add($"SiteBlock will uninstall in {Formatting.Clock(Seconds(uninstall))}.");
        if (status.RecoverySecondsRemaining is long recovery) lines.Add($"Password recovery: the password will be cleared in {Formatting.Clock(Seconds(recovery))}.");
        if (status.LockoutSecondsRemaining is long lockout) lines.Add($"Password checks are locked for another {Formatting.Clock(Seconds(lockout))}.");
        if (!status.HostsFileHealthy) lines.Add("Warning: the hosts file could not be brought into the right state.");
        return string.Join("\n", lines);
    }

    /// <summary>Prints the tool's own version without contacting the service, so it works when the service is not running.</summary>
    private static int RunVersion()
    {
        Console.WriteLine($"siteblock {BuildInfo.VersionWithBuild}");
        return ExitCode.Success;
    }

    /// <summary>Prints the full status.</summary>
    private static int RunStatus()
    {
        var (response, code) = Send(new Request(Command.Status));
        if (response is null) return code;
        if (response.Status is { } status) Console.WriteLine(FormatStatus(status));
        return ExitCode.Success;
    }

    /// <summary>Prints a command's confirmation sentence, and a warning to standard error when the service could not bring the hosts file into the right state.</summary>
    private static void PrintMessage(Response response)
    {
        if (response.Message is string message) Console.WriteLine(message);
        if (response.Status?.HostsFileHealthy == false) PrintError("Warning: the hosts file could not be updated, so the change may not be active yet.");
    }

    /// <summary>Sends a request and prints the confirmation; returns the exit code for the outcome.</summary>
    private static int SendAndPrint(Request request)
    {
        var (response, code) = Send(request);
        if (response is null) return code;
        PrintMessage(response);
        return ExitCode.Success;
    }

    /// <summary>Reads one password for a command that needs the current password, or prints why and returns null. An empty entry is refused here, so a stray Enter does not use up one of the five tries.</summary>
    private static string? ReadPassword(string prompt = "Password: ")
    {
        string? password = PasswordPrompt.Read(prompt);
        if (string.IsNullOrEmpty(password))
        {
            PrintError("siteblock: no password was entered.");
            return null;
        }
        return password;
    }

    /// <summary>Reads a new password with confirmation. Nothing entered is a usage problem (64); two entries that differ are a refusal (1).</summary>
    private static (string? Password, int Code) ReadNewPassword(string prompt, string confirmPrompt)
    {
        try
        {
            string? password = PasswordPrompt.ReadNew(prompt, confirmPrompt);
            if (string.IsNullOrEmpty(password))
            {
                PrintError("siteblock: no password was entered.");
                return (null, ExitCode.Usage);
            }
            return (password, ExitCode.Success);
        }
        catch (InvalidOperationException)
        {
            PrintError("The two passwords do not match.");
            return (null, ExitCode.Refused);
        }
    }

    /// <summary>Asks for a new SiteBlock password twice, with a short explanation first when a person is at the console. Used by setup and by the first add.</summary>
    private static (string? Password, int Code) ChooseNewPassword()
    {
        if (PasswordPrompt.IsInteractive) PrintError($"Choose a SiteBlock password (at least {PasswordHasher.MinimumLength} characters). It cannot be shown again, and you need it to unblock sites.");
        return ReadNewPassword("New password: ", "Confirm password: ");
    }

    /// <summary>Sets the first password.</summary>
    private static int RunSetup()
    {
        var (password, code) = ChooseNewPassword();
        return password is null ? code : SendAndPrint(new Request(Command.Setup, Password: password));
    }

    /// <summary>Chooses the password at the first block: asks for it twice and sends setup. Returns null when it was set, or the exit code to stop with.</summary>
    private static int? ChooseFirstPassword()
    {
        if (PasswordPrompt.IsInteractive) PrintError("SiteBlock has no password yet. It is chosen with your first block.");
        var (password, code) = ChooseNewPassword();
        if (password is null) return code;
        int sent = SendAndPrint(new Request(Command.Setup, Password: password));
        return sent == ExitCode.Success ? null : sent;
    }

    /// <summary>True when the text names a part of a site (a path after the name), which is a path rule.</summary>
    private static bool HasPath(string text) => PathRuleParser.Split(text).Path is not null;

    /// <summary>
    /// Blocks each given site with one request per site, keeps going after a failure, and exits 1 if any failed (or 2 at once when the service is not running).
    /// A path after the name blocks only that part; --whole-site blocks the whole site. When no password is set yet, it first asks for one and sets it.
    /// </summary>
    private static int RunAdd(List<string> arguments)
    {
        bool wholeSite = arguments.Contains("--whole-site");
        var sites = arguments.Where(argument => argument != "--whole-site").ToList();
        if (sites.Count == 0) return UsageFailure("add needs at least one site");
        if (sites.FirstOrDefault(site => site.StartsWith('-')) is string flag) return UsageFailure($"unknown option '{flag}'");
        // Ask the service first whether a password exists; nothing is prompted for when one does, so scripts that pipe nothing keep working.
        var (status, statusCode) = Send(new Request(Command.Status));
        if (status is null) return statusCode;
        // A response without a status is treated as "password set": the service then refuses each add itself instead of this tool guessing.
        if (status.Status?.PasswordSet == false && ChooseFirstPassword() is int stop) return stop;
        bool anyFailed = false;
        foreach (string site in sites)
        {
            var command = !wholeSite && HasPath(site) ? Command.AddPath : Command.Add;
            // With several sites, each error is prefixed with its site so it is clear which one failed.
            var (response, code) = Send(new Request(command, Domain: site), sites.Count > 1 ? $"{site}: " : "");
            if (response is null)
            {
                // A missing service will not come back during this command.
                if (code == ExitCode.NotRunning) return code;
                anyFailed = true;
            }
            else
            {
                PrintMessage(response);
            }
        }
        return anyFailed ? ExitCode.Refused : ExitCode.Success;
    }

    /// <summary>The single site argument of a command, or null after printing a usage error.</summary>
    private static string? SingleSite(List<string> arguments, string command)
    {
        if (arguments.Count == 1 && !arguments[0].StartsWith('-')) return arguments[0];
        UsageFailure($"{command} needs exactly one site");
        return null;
    }

    /// <summary>Splits the arguments of unblock into the site and the --for and --in values (each once, each followed by its value). Returns null after printing a usage error.</summary>
    private static (string Site, string? For, string? In)? ParseUnblockArguments(List<string> arguments)
    {
        string? site = null, forText = null, inText = null;
        for (int index = 0; index < arguments.Count;)
        {
            string argument = arguments[index];
            if (argument is "--for" or "--in")
            {
                if (index + 1 >= arguments.Count)
                {
                    UsageFailure($"{argument} needs a value");
                    return null;
                }
                bool alreadyGiven = argument == "--for" ? forText is not null : inText is not null;
                if (alreadyGiven)
                {
                    UsageFailure($"{argument} was given twice");
                    return null;
                }
                if (argument == "--for") forText = arguments[index + 1];
                else inText = arguments[index + 1];
                index += 2;
                continue;
            }
            if (argument.StartsWith('-'))
            {
                UsageFailure($"unknown option '{argument}'");
                return null;
            }
            if (site is not null)
            {
                UsageFailure("unblock needs exactly one site");
                return null;
            }
            site = argument;
            index++;
        }
        if (site is null)
        {
            UsageFailure("unblock needs exactly one site");
            return null;
        }
        return (site, forText, inText);
    }

    /// <summary>Turns a duration option's text into seconds, or prints a usage error naming the option and returns null.</summary>
    private static int? ParseDurationOption(string text, string option)
    {
        if (Formatting.ParseDuration(text) is int seconds) return seconds;
        UsageFailure($"'{text}' is not a duration for {option}; try 30m, 2h, 1d or 1h30m");
        return null;
    }

    /// <summary>
    /// Starts the unblock countdown for a site (or a part of a site when the text has a path) after asking for the password. With --for the unblock is temporary: it opens after the
    /// unblock delay (or --in) and is blocked again when --for runs out. Every option is checked before the password is asked for, so a typo costs nothing.
    /// </summary>
    private static int RunUnblock(List<string> arguments)
    {
        if (ParseUnblockArguments(arguments) is not var (site, forText, inText)) return ExitCode.Usage;
        if (forText is null)
        {
            // Without --for this is the permanent unblock; --in only goes with a temporary one.
            if (inText is not null) return UsageFailure("--in goes with --for");
            if (ReadPassword() is not string password) return ExitCode.Usage;
            return SendAndPrint(new Request(HasPath(site) ? Command.UnblockPath : Command.Unblock, Domain: site, Password: password));
        }
        if (ParseDurationOption(forText, "--for") is not int window) return ExitCode.Usage;
        int? start = null;
        if (inText is not null)
        {
            if (ParseDurationOption(inText, "--in") is not int startSeconds) return ExitCode.Usage;
            start = startSeconds;
        }
        if (ReadPassword() is not string temporaryPassword) return ExitCode.Usage;
        return SendAndPrint(new Request(HasPath(site) ? Command.TemporaryUnblockPath : Command.TemporaryUnblock, Domain: site, Password: temporaryPassword, Seconds: window, StartSeconds: start));
    }

    /// <summary>Cancels a pending unblock, or ends a waiting or open temporary unblock, of a site or a part of a site; no password is needed.</summary>
    private static int RunCancel(List<string> arguments)
    {
        if (SingleSite(arguments, "cancel") is not string site) return ExitCode.Usage;
        return SendAndPrint(new Request(HasPath(site) ? Command.CancelUnblockPath : Command.CancelUnblock, Domain: site));
    }

    /// <summary>Shows the current delay, changes it (after asking for the password), or cancels a pending change.</summary>
    private static int RunDelay(List<string> arguments)
    {
        if (arguments.Count == 0)
        {
            var (response, code) = Send(new Request(Command.Status));
            if (response is null) return code;
            if (response.Status is not { } status) return ExitCode.Refused;
            Console.WriteLine($"Unblock delay: {Formatting.Duration(Seconds(status.DelaySeconds))}");
            if (status.PendingDelay is { } pending) Console.WriteLine($"It will change to {Formatting.Duration(Seconds(pending.NewDelaySeconds))} in {Formatting.Clock(Seconds(pending.SecondsRemaining))}.");
            return ExitCode.Success;
        }
        if (arguments.Count != 1) return UsageFailure("delay takes one duration or --cancel");
        if (arguments[0] == "--cancel") return SendAndPrint(new Request(Command.CancelDelayChange));
        // The duration is checked before the password is asked for, so a typo costs nothing.
        if (Formatting.ParseDuration(arguments[0]) is not int seconds) return UsageFailure($"'{arguments[0]}' is not a duration; try 45m, 2h, 1d or 1h30m");
        if (ReadPassword() is not string password) return ExitCode.Usage;
        return SendAndPrint(new Request(Command.SetDelay, Password: password, Seconds: seconds));
    }

    /// <summary>Changes the password after asking for the current one and the new one.</summary>
    private static int RunPasswd()
    {
        if (ReadPassword("Current password: ") is not string oldPassword) return ExitCode.Usage;
        var (newPassword, code) = ReadNewPassword("New password: ", "Confirm new password: ");
        if (newPassword is null) return code;
        return SendAndPrint(new Request(Command.ChangePassword, Password: oldPassword, NewPassword: newPassword));
    }

    /// <summary>Starts the uninstall countdown after asking for the password, or cancels a pending uninstall.</summary>
    private static int RunUninstall(List<string> arguments)
    {
        if (arguments is ["--cancel"]) return SendAndPrint(new Request(Command.CancelUninstall));
        if (arguments.Count > 0) return UsageFailure("uninstall takes no arguments except --cancel");
        if (ReadPassword() is not string password) return ExitCode.Usage;
        return SendAndPrint(new Request(Command.Uninstall, Password: password));
    }

    /// <summary>Starts the forgotten-password reset (the service accepts it only from an elevated terminal), or cancels a running one.</summary>
    private static int RunRecover(List<string> arguments)
    {
        if (arguments.Count == 0) return SendAndPrint(new Request(Command.RecoveryStart));
        if (arguments is ["--cancel"]) return SendAndPrint(new Request(Command.RecoveryCancel));
        return UsageFailure("recover takes no arguments except --cancel");
    }
}

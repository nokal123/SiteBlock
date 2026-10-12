import Foundation
import SiteBlockCore

/// The exit codes of the siteblock tool.
enum ExitCode {
    /// The command worked.
    static let success: Int32 = 0
    /// The daemon refused the command (or the input could not be used); the reason is printed to standard error.
    static let refused: Int32 = 1
    /// The daemon is not running.
    static let notRunning: Int32 = 2
    /// The command line was wrong (the Unix code for "command used incorrectly").
    static let usage: Int32 = 64
}

/// The usage text shown for `siteblock help` and after a command-line mistake.
let usageText = """
usage:
  siteblock status
  siteblock setup                      asks for a new password twice
  siteblock add <site> [<site> ...]    the first time, asks you to choose the password
  siteblock unblock <site>             asks for the password
  siteblock cancel <site>              cancel a pending unblock
  siteblock delay                      show the current unblock delay
  siteblock delay <duration>           for example 45m or 2h; asks for the password
  siteblock delay --cancel
  siteblock passwd                     asks for the old and the new password
  siteblock uninstall                  asks for the password
  siteblock uninstall --cancel
  sudo siteblock recover               start the 48-hour password reset
  siteblock recover --cancel
  siteblock version

"""

/// Writes a line to standard error.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Prints a usage mistake (when there is a message) and the usage text to standard error, and returns the usage exit code.
func usageFailure(_ message: String? = nil) -> Int32 {
    if let message { printError("siteblock: \(message)") }
    printError(usageText)
    return ExitCode.usage
}

/// The outcome of sending one request to the daemon.
enum SendResult {
    /// The daemon accepted the command; carries its response.
    case accepted(Response)
    /// The command did not succeed; the problem has been printed and this is the exit code to use.
    case failed(Int32)
}

/// Sends one request and reports the outcome. A missing daemon prints its message and gives exit code 2. A refusal prints the daemon's error sentence and gives exit code 1. Other connection problems also give exit code 1.
func send(_ request: Request, prefix: String = "") -> SendResult {
    do {
        let response = try DaemonClient().send(request)
        if response.ok { return .accepted(response) }
        printError(prefix + (response.error ?? "The SiteBlock service refused the command."))
        return .failed(ExitCode.refused)
    } catch ClientError.notRunning {
        printError(ClientError.notRunning.localizedDescription)
        return .failed(ExitCode.notRunning)
    } catch {
        printError(error.localizedDescription)
        return .failed(ExitCode.refused)
    }
}

/// Builds the text `siteblock status` prints from a snapshot: the delay, then each blocked site with its host count and any countdown, then the adult content filter line, then any pending delay change, uninstall, recovery or lockout.
func formatStatus(_ status: StatusSnapshot) -> String {
    var lines = ["SiteBlock \(status.version) — unblock delay: \(Formatting.duration(status.delaySeconds))"]
    if !status.passwordSet { lines.append("No password yet. You choose it the first time you block a site.") }
    if status.blocked.isEmpty {
        lines.append("No sites blocked.")
    } else {
        lines.append("Blocked sites (\(status.blocked.count)):")
        for site in status.blocked {
            var line = "  \(site.domain) (\(site.hosts.count) \(site.hosts.count == 1 ? "host" : "hosts"))"
            if let seconds = site.unblockSecondsRemaining { line += " — unblocks in \(Formatting.clock(seconds))" }
            lines.append(line)
        }
    }
    // The filter has no switch: a SiteBlock service that has it always reports it on. A service from before the filter existed sends nothing, which reads as false, and then the line says so instead of claiming protection that is not there.
    lines.append(status.adultFilterEnabled == true ? "Adult content filter: always on" : "Adult content filter: not provided by this version of the SiteBlock service")
    if let pending = status.pendingDelay {
        lines.append("Unblock delay will change to \(Formatting.duration(pending.newDelaySeconds)) in \(Formatting.clock(pending.secondsRemaining)).")
    }
    if let seconds = status.uninstallSecondsRemaining { lines.append("SiteBlock will uninstall in \(Formatting.clock(seconds)).") }
    if let seconds = status.recoverySecondsRemaining { lines.append("Password recovery: the password will be cleared in \(Formatting.clock(seconds)).") }
    if let seconds = status.lockoutSecondsRemaining { lines.append("Password checks are locked for another \(Formatting.clock(seconds)).") }
    if !status.hostsFileHealthy { lines.append("Warning: the hosts file could not be brought into the right state.") }
    return lines.joined(separator: "\n")
}

/// Runs one command line (everything after the program name) and returns the exit code.
func runCLI(_ arguments: [String]) -> Int32 {
    guard let command = arguments.first else { return usageFailure() }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "status": return rest.isEmpty ? runStatus() : usageFailure("status takes no arguments")
    case "setup": return rest.isEmpty ? runSetup() : usageFailure("setup takes no arguments")
    case "add": return runAdd(rest)
    case "unblock": return runUnblock(rest)
    case "cancel": return runCancel(rest)
    case "delay": return runDelay(rest)
    case "passwd": return rest.isEmpty ? runPasswd() : usageFailure("passwd takes no arguments")
    case "uninstall": return runUninstall(rest)
    case "recover": return runRecover(rest)
    case "version", "--version": return rest.isEmpty ? runVersion() : usageFailure("version takes no arguments")
    case "help", "--help", "-h":
        print(usageText, terminator: "")
        return ExitCode.success
    default: return usageFailure("unknown command '\(command)'")
    }
}

/// Prints the tool's own version. It does not contact the daemon, so it works when the daemon is not running.
private func runVersion() -> Int32 {
    print("siteblock \(siteBlockVersion)")
    return ExitCode.success
}

/// Prints the full status.
private func runStatus() -> Int32 {
    switch send(Request(command: .status)) {
    case .failed(let code): return code
    case .accepted(let response):
        if let status = response.status { print(formatStatus(status)) }
        return ExitCode.success
    }
}

/// Prints a command's confirmation sentence, if it has one, and a warning to standard error when the daemon could not bring the hosts file into the right state (so the change may not be active yet).
private func printMessage(_ response: Response) {
    if let message = response.message { print(message) }
    if response.status?.hostsFileHealthy == false { printError("Warning: the hosts file could not be updated, so the change may not be active yet.") }
}

/// Sends a request and prints the daemon's confirmation sentence; returns the exit code for the outcome.
private func sendAndPrint(_ request: Request) -> Int32 {
    switch send(request) {
    case .failed(let code): return code
    case .accepted(let response):
        printMessage(response)
        return ExitCode.success
    }
}

/// Reads one password for a command that needs the current password. Returns nil after printing why when none could be read. An empty entry is refused here rather than sent, so pressing Enter by mistake does not use up one of the five allowed tries.
private func readPassword(prompt: String = "Password: ") -> String? {
    guard let password = PasswordPrompt.read(prompt: prompt) else {
        printError("siteblock: no password was entered.")
        return nil
    }
    if password.isEmpty {
        printError("siteblock: no password was entered.")
        return nil
    }
    return password
}

/// The outcome of asking for a new password.
private enum NewPasswordInput {
    /// A usable password was entered (and confirmed).
    case password(String)
    /// It could not be used; the reason has been printed and this is the exit code.
    case failed(Int32)
}

/// Reads a new password with confirmation. Entering nothing is a usage problem (exit 64); two entries that differ are a refusal (exit 1).
private func readNewPassword(prompt: String, confirmPrompt: String) -> NewPasswordInput {
    do {
        guard let password = try PasswordPrompt.readNew(prompt: prompt, confirmPrompt: confirmPrompt), !password.isEmpty else {
            printError("siteblock: no password was entered.")
            return .failed(ExitCode.usage)
        }
        return .password(password)
    } catch {
        printError("The two passwords do not match.")
        return .failed(ExitCode.refused)
    }
}

/// Asks for a new SiteBlock password twice, with a short explanation first when a person is at the keyboard (piped input needs none). Used by `setup` and by the first `add`, so both ask the same way and read piped input the same way.
private func chooseNewPassword() -> NewPasswordInput {
    if PasswordPrompt.isInteractive {
        printError("Choose a SiteBlock password (at least \(PasswordHasher.minimumLength) characters). It cannot be shown again, and you need it to unblock sites.")
    }
    return readNewPassword(prompt: "New password: ", confirmPrompt: "Confirm password: ")
}

/// Sets the first password.
private func runSetup() -> Int32 {
    let password: String
    switch chooseNewPassword() {
    case .failed(let code): return code
    case .password(let entered): password = entered
    }
    return sendAndPrint(Request(command: .setup, password: password))
}

/// Chooses the SiteBlock password at the first block: asks for it (twice) and sends `setup`. Returns nil when the password was set, or the exit code to stop with when it was not (a mismatch gives 1, an empty entry gives 64, a refusal from the daemon gives 1).
private func chooseFirstPassword() -> Int32? {
    if PasswordPrompt.isInteractive {
        printError("SiteBlock has no password yet. It is chosen with your first block.")
    }
    let password: String
    switch chooseNewPassword() {
    case .failed(let code): return code
    case .password(let entered): password = entered
    }
    let code = sendAndPrint(Request(command: .setup, password: password))
    return code == ExitCode.success ? nil : code
}

/// Blocks each given site with one request per site, carries on after a failure, and exits with 1 if any failed (or 2 as soon as the daemon is found not running). When no password is set yet, it first asks for one and sets it, because the password is chosen at the first block; if that fails, no site is sent.
private func runAdd(_ sites: [String]) -> Int32 {
    if sites.isEmpty { return usageFailure("add needs at least one site") }
    if let flag = sites.first(where: { $0.hasPrefix("-") }) { return usageFailure("unknown option '\(flag)'") }
    // Ask the daemon first whether a password exists. Nothing is prompted for when one does, so scripts that pipe nothing keep working.
    switch send(Request(command: .status)) {
    case .failed(let code): return code
    case .accepted(let response):
        // A response without a status is treated as "password set": the daemon then gives its own refusal for each add instead of this tool guessing.
        if response.status?.passwordSet == false, let code = chooseFirstPassword() { return code }
    }
    var anyFailed = false
    for site in sites {
        // With several sites, each error is prefixed with the site so it is clear which one failed.
        switch send(Request(command: .add, domain: site), prefix: sites.count > 1 ? "\(site): " : "") {
        case .failed(let code):
            // A missing daemon will not come back during this command, so stop instead of repeating the same message.
            if code == ExitCode.notRunning { return code }
            anyFailed = true
        case .accepted(let response):
            printMessage(response)
        }
    }
    return anyFailed ? ExitCode.refused : ExitCode.success
}

/// Returns the single site argument of a command, or nil after printing a usage error.
private func singleSite(_ arguments: [String], command: String) -> String? {
    guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
        _ = usageFailure("\(command) needs exactly one site")
        return nil
    }
    return arguments[0]
}

/// Starts the unblock countdown for one site after asking for the password.
private func runUnblock(_ arguments: [String]) -> Int32 {
    guard let site = singleSite(arguments, command: "unblock") else { return ExitCode.usage }
    guard let password = readPassword() else { return ExitCode.usage }
    return sendAndPrint(Request(command: .unblock, domain: site, password: password))
}

/// Cancels a pending unblock; no password is needed.
private func runCancel(_ arguments: [String]) -> Int32 {
    guard let site = singleSite(arguments, command: "cancel") else { return ExitCode.usage }
    return sendAndPrint(Request(command: .cancelUnblock, domain: site))
}

/// Shows the current delay, changes it to a given duration (after asking for the password), or cancels a pending change.
private func runDelay(_ arguments: [String]) -> Int32 {
    if arguments.isEmpty {
        switch send(Request(command: .status)) {
        case .failed(let code): return code
        case .accepted(let response):
            guard let status = response.status else { return ExitCode.refused }
            print("Unblock delay: \(Formatting.duration(status.delaySeconds))")
            if let pending = status.pendingDelay {
                print("It will change to \(Formatting.duration(pending.newDelaySeconds)) in \(Formatting.clock(pending.secondsRemaining)).")
            }
            return ExitCode.success
        }
    }
    guard arguments.count == 1 else { return usageFailure("delay takes one duration or --cancel") }
    if arguments[0] == "--cancel" {
        return sendAndPrint(Request(command: .cancelDelayChange))
    }
    // The duration is checked before the password is asked for, so a typo costs nothing.
    guard let seconds = Formatting.parseDuration(arguments[0]) else {
        return usageFailure("'\(arguments[0])' is not a duration; try 45m, 2h, 1d or 1h30m")
    }
    guard let password = readPassword() else { return ExitCode.usage }
    return sendAndPrint(Request(command: .setDelay, password: password, seconds: seconds))
}

/// Changes the password after asking for the old one and the new one.
private func runPasswd() -> Int32 {
    guard let oldPassword = readPassword(prompt: "Current password: ") else { return ExitCode.usage }
    let newPassword: String
    switch readNewPassword(prompt: "New password: ", confirmPrompt: "Confirm new password: ") {
    case .failed(let code): return code
    case .password(let entered): newPassword = entered
    }
    return sendAndPrint(Request(command: .changePassword, password: oldPassword, newPassword: newPassword))
}

/// Starts the uninstall countdown after asking for the password, or cancels a pending uninstall.
private func runUninstall(_ arguments: [String]) -> Int32 {
    if arguments == ["--cancel"] {
        return sendAndPrint(Request(command: .cancelUninstall))
    }
    guard arguments.isEmpty else { return usageFailure("uninstall takes no arguments except --cancel") }
    guard let password = readPassword() else { return ExitCode.usage }
    return sendAndPrint(Request(command: .uninstall, password: password))
}

/// Starts the forgotten-password reset (the daemon accepts it only from root, so run it with sudo), or cancels a running one.
private func runRecover(_ arguments: [String]) -> Int32 {
    let command: Command
    if arguments.isEmpty {
        command = .recoveryStart
    } else if arguments == ["--cancel"] {
        command = .recoveryCancel
    } else {
        return usageFailure("recover takes no arguments except --cancel")
    }
    return sendAndPrint(Request(command: command))
}

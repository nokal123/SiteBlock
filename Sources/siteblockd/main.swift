import Foundation
import SiteBlockCore

// Entry point of siteblockd: reads the command-line flags and starts the daemon or the watchdog, or prints something and exits.

// A client that vanishes mid-write must not kill the process with SIGPIPE; the write call reports an error instead.
signal(SIGPIPE, SIG_IGN)

/// What the program was asked to do.
enum Mode {
    case daemon
    case watchdog
    case version
    case printPlist(LaunchdPlists.Job)
    case printDNSPlan
}

/// The parsed command line.
struct Options {
    var mode: Mode?
    var sandboxRoot: String?
    var tickSeconds: Double?
    var policyFast = false
}

/// The usage text printed after a command-line mistake.
let usageText = """
usage: siteblockd --daemon [--sandbox <dir> [--tick <seconds>] [--policy-fast]]
       siteblockd --watchdog
       siteblockd --version
       siteblockd --print-plist <daemon|watchdog|app> [--sandbox <dir>]
       siteblockd --print-dns-plan [--sandbox <dir>]

"""

/// Prints a message (if any) and the usage text to standard error, then exits with code 64, the Unix code for "command used incorrectly".
func usageError(_ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("siteblockd: \(message)\n".utf8)) }
    FileHandle.standardError.write(Data(usageText.utf8))
    exit(64)
}

/// Reads the flags by hand. Any unknown flag, repeated flag, missing value, or forbidden combination is a usage error, and so is --sandbox when the process runs as root.
func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var seen: Set<String> = []
    var index = 0
    /// Returns the value that follows a flag, or stops with a usage error when it is missing or looks like another flag.
    func value(for flag: String) -> String {
        index += 1
        guard index < arguments.count, !arguments[index].hasPrefix("--") else { usageError("\(flag) needs a value") }
        return arguments[index]
    }
    /// Records that a mode flag was seen; exactly one mode is allowed.
    func setMode(_ mode: Mode, flag: String) {
        if options.mode != nil { usageError("only one of --daemon, --watchdog, --version, --print-plist and --print-dns-plan may be given") }
        options.mode = mode
    }
    while index < arguments.count {
        let flag = arguments[index]
        if !seen.insert(flag).inserted { usageError("\(flag) was given more than once") }
        switch flag {
        case "--daemon": setMode(.daemon, flag: flag)
        case "--watchdog": setMode(.watchdog, flag: flag)
        case "--version": setMode(.version, flag: flag)
        case "--print-dns-plan": setMode(.printDNSPlan, flag: flag)
        case "--print-plist":
            let name = value(for: flag)
            guard let job = LaunchdPlists.Job(argument: name) else { usageError("--print-plist needs daemon, watchdog or app") }
            setMode(.printPlist(job), flag: flag)
        case "--sandbox":
            let directory = value(for: flag)
            // A relative folder would resolve differently for the daemon and for clients started elsewhere, so it is made absolute here.
            options.sandboxRoot = URL(fileURLWithPath: directory).standardizedFileURL.path
        case "--tick":
            let text = value(for: flag)
            guard let seconds = Double(text), seconds.isFinite, seconds > 0 else { usageError("--tick needs a positive number of seconds") }
            options.tickSeconds = seconds
        case "--policy-fast": options.policyFast = true
        default: usageError("unknown option \(flag)")
        }
        index += 1
    }
    guard options.mode != nil else { usageError("one of --daemon, --watchdog, --version, --print-plist or --print-dns-plan is required") }
    // Short waits and fast ticks are only for sandbox runs, so the installed daemon can never be started with them.
    if options.sandboxRoot == nil && options.tickSeconds != nil { usageError("--tick is only accepted together with --sandbox") }
    if options.sandboxRoot == nil && options.policyFast { usageError("--policy-fast is only accepted together with --sandbox") }
    // A sandbox run as root could be pointed at the real /etc, where a second daemon would fight the installed one over the hosts file, so root may never use --sandbox. Exit code 64 comes from usageError.
    if options.sandboxRoot != nil && geteuid() == 0 { usageError("--sandbox cannot be used while running as root") }
    return options
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let paths = options.sandboxRoot.map { Paths.sandbox(root: $0) } ?? Paths.production
let logger = Logger()

switch options.mode! {
case .version:
    // The build scripts read both numbers from this line, so it carries the build number too: "siteblockd 1.2.0 (build 51)".
    print("siteblockd \(siteBlockVersion) (build \(siteBlockBuildNumber))")
case .printPlist(let job):
    // The install script writes the plist files from this output, so the plist text has a single source.
    print(LaunchdPlists.xml(for: job, paths: paths), terminator: "")
case .printDNSPlan:
    // A read-only diagnostic: it lists the network services, what DNS servers each has, and what SiteBlock would set, without changing anything. It needs no root, and (without --sandbox) it reads the real network settings.
    do {
        print(try DNSPlanReport.text(paths: paths), terminator: "")
    } catch {
        FileHandle.standardError.write(Data("siteblockd: cannot read the network settings: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case .watchdog:
    // The watchdog's whole job is to call launchctl, which sandbox mode forbids, so the combination is refused instead of silently doing nothing.
    if options.sandboxRoot != nil { usageError("--watchdog cannot be combined with --sandbox") }
    // The installed jobs run as root; anything else would only fail halfway, so refuse up front with exit code 77 (the Unix code for "permission denied").
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("siteblockd: the watchdog must run as root\n".utf8))
        exit(77)
    }
    runWatchdog(paths: paths, log: logger)
case .daemon:
    if options.sandboxRoot == nil && geteuid() != 0 {
        FileHandle.standardError.write(Data("siteblockd: the installed daemon must run as root (use --sandbox <dir> for a test run)\n".utf8))
        exit(77)
    }
    let policy = options.policyFast ? Policy.fastForTests : Policy.production
    DaemonRuntime(paths: paths, policy: policy, tickInterval: options.tickSeconds ?? 2, log: logger).run()
}

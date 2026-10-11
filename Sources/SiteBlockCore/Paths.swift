import Foundation

/// Every file and folder location SiteBlock uses, either the real system locations or a set of locations under a temporary folder for sandbox runs.
public struct Paths: Sendable {
    /// True when every path lives under a sandbox folder and nothing touches the real system.
    public let isSandbox: Bool
    /// The menu bar app bundle.
    public let appBundle: String
    /// The program inside the app bundle that the app LaunchAgent starts.
    public let appExecutable: String
    /// The installed command-line tool (a copy, not a link).
    public let cliPath: String
    /// The backup copy of the daemon program that the guard restores from.
    public let backupDaemon: String
    /// The daemon program that the LaunchDaemons run.
    public let daemonProgram: String
    /// The folder holding the state file and the program. The watchdog recreates it when it is missing.
    public let stateDir: String
    /// The persisted state file.
    public let stateFile: String
    /// A second copy of the state file, kept outside the state folder so deleting or wiping one location cannot lose the block list.
    public let stateBackup: String
    /// The Unix socket clients connect to.
    public let socket: String
    /// The hosts file that gets edited.
    public let hosts: String
    /// The folder holding the log files.
    public let logDir: String
    /// The daemon's log file.
    public let daemonLog: String
    /// The watchdog's log file.
    public let watchdogLog: String
    /// The daemon's launchd configuration file.
    public let daemonPlist: String
    /// The watchdog's launchd configuration file.
    public let watchdogPlist: String
    /// The app's launchd configuration file (a LaunchAgent).
    public let appAgentPlist: String
    /// The log rotation settings file that tells macOS's newsyslog how to rotate the two log files.
    public let newsyslogConf: String
    /// The folder where macOS keeps mandatory app settings that only root can change. Chrome's block list is written here.
    public let managedPreferencesDir: String

    /// Builds the layout shared by production and sandbox: each location is a fixed spot under the given folders.
    private init(isSandbox: Bool, appBundle: String, cliPath: String, backupDaemon: String, stateDir: String, socket: String, hosts: String, logDir: String, launchDaemonsDir: String, launchAgentsDir: String, newsyslogConf: String, managedPreferencesDir: String) {
        self.isSandbox = isSandbox
        self.appBundle = appBundle
        self.appExecutable = appBundle + "/Contents/MacOS/SiteBlock"
        self.cliPath = cliPath
        self.backupDaemon = backupDaemon
        self.stateDir = stateDir
        self.daemonProgram = stateDir + "/bin/siteblockd"
        self.stateFile = stateDir + "/state.json"
        // The state backup sits next to the backup daemon program, so both live in the same folder that the installer creates.
        self.stateBackup = URL(fileURLWithPath: backupDaemon).deletingLastPathComponent().path + "/state.backup.json"
        self.socket = socket
        self.hosts = hosts
        self.logDir = logDir
        self.daemonLog = logDir + "/siteblockd.log"
        self.watchdogLog = logDir + "/watchdog.log"
        self.daemonPlist = launchDaemonsDir + "/com.nokal.siteblock.daemon.plist"
        self.watchdogPlist = launchDaemonsDir + "/com.nokal.siteblock.watchdog.plist"
        self.appAgentPlist = launchAgentsDir + "/com.nokal.siteblock.app.plist"
        self.newsyslogConf = newsyslogConf
        self.managedPreferencesDir = managedPreferencesDir
    }

    /// The name of Chrome's settings file inside the managed preferences folder (Chrome's app identifier plus ".plist").
    private static let chromePolicyFileName = "com.google.Chrome.plist"

    /// The machine-wide Chrome policy file, which macOS reports to Chrome as mandatory for every user.
    public var chromePolicyMachinePlist: String {
        managedPreferencesDir + "/" + Paths.chromePolicyFileName
    }

    /// The Chrome policy file for one user, which lives in a folder named after that user. Chrome watches this exact path and reloads its policies within seconds of a change.
    public func chromePolicyUserPlist(forUser name: String) -> String {
        managedPreferencesDir + "/" + name + "/" + Paths.chromePolicyFileName
    }

    /// The real system locations used by the installed service.
    public static let production = Paths(
        isSandbox: false, appBundle: "/Applications/SiteBlock.app", cliPath: "/usr/local/bin/siteblock",
        backupDaemon: "/usr/local/libexec/siteblock/siteblockd", stateDir: "/Library/Application Support/SiteBlock",
        socket: "/var/run/siteblock.sock", hosts: "/etc/hosts", logDir: "/Library/Logs/SiteBlock",
        launchDaemonsDir: "/Library/LaunchDaemons", launchAgentsDir: "/Library/LaunchAgents",
        newsyslogConf: "/etc/newsyslog.d/siteblock.conf", managedPreferencesDir: "/Library/Managed Preferences"
    )

    /// Puts every location under the given folder, for tests and manual checks. A Unix socket path must be shorter than 104 bytes, so callers should pick a short root such as one under /tmp.
    public static func sandbox(root: String) -> Paths {
        // Drop a trailing slash so joined paths never contain a double slash.
        var base = root
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        return Paths(
            isSandbox: true, appBundle: base + "/Applications/SiteBlock.app", cliPath: base + "/bin/siteblock",
            backupDaemon: base + "/libexec/siteblock/siteblockd", stateDir: base + "/state",
            socket: base + "/siteblock.sock", hosts: base + "/hosts", logDir: base + "/logs",
            launchDaemonsDir: base + "/LaunchDaemons", launchAgentsDir: base + "/LaunchAgents",
            newsyslogConf: base + "/newsyslog.d/siteblock.conf", managedPreferencesDir: base + "/ManagedPreferences"
        )
    }
}

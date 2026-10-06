import Foundation
import SiteBlockCore

/// Builds the launchd configuration files (plists) for SiteBlock's three jobs. The text is generated in code rather than read from disk, so the guard can always recreate a deleted plist and the install script has one source for it (`siteblockd --print-plist`).
enum LaunchdPlists {
    /// The three launchd jobs SiteBlock installs.
    enum Job: CaseIterable {
        /// The main service (`siteblockd --daemon`), a LaunchDaemon that runs as root.
        case daemon
        /// The guard that keeps the daemon loaded (`siteblockd --watchdog`), a second LaunchDaemon.
        case watchdog
        /// The menu bar app, a LaunchAgent started in each user's login session.
        case app

        /// The launchd label that identifies the job.
        var label: String {
            switch self {
            case .daemon: return "com.nokal.siteblock.daemon"
            case .watchdog: return "com.nokal.siteblock.watchdog"
            case .app: return "com.nokal.siteblock.app"
            }
        }

        /// The location of the job's plist file.
        func plistPath(in paths: Paths) -> String {
            switch self {
            case .daemon: return paths.daemonPlist
            case .watchdog: return paths.watchdogPlist
            case .app: return paths.appAgentPlist
            }
        }

        /// The name used on the command line, as in `--print-plist daemon`.
        init?(argument: String) {
            switch argument {
            case "daemon": self = .daemon
            case "watchdog": self = .watchdog
            case "app": self = .app
            default: return nil
            }
        }
    }

    /// Escapes the three characters that have a special meaning inside XML text, so a path containing them cannot break the plist.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Returns the complete plist XML for a job. The two LaunchDaemons restart whenever they exit (`KeepAlive`), keep running children alive after they exit (`AbandonProcessGroup`, so the uninstall shell is not killed with the daemon), and wait at least 5 seconds between restarts. The app agent starts at login but is not restarted when the user quits it.
    static func xml(for job: Job, paths: Paths) -> String {
        var entries: [(key: String, value: String)] = [("Label", "<string>\(escape(job.label))</string>")]
        switch job {
        case .daemon, .watchdog:
            let flag = job == .daemon ? "--daemon" : "--watchdog"
            let log = job == .daemon ? paths.daemonLog : paths.watchdogLog
            entries.append(("ProgramArguments", "<array>\n\t\t<string>\(escape(paths.daemonProgram))</string>\n\t\t<string>\(flag)</string>\n\t</array>"))
            entries.append(("RunAtLoad", "<true/>"))
            entries.append(("KeepAlive", "<true/>"))
            entries.append(("ProcessType", "<string>Interactive</string>"))
            entries.append(("AbandonProcessGroup", "<true/>"))
            entries.append(("StandardOutPath", "<string>\(escape(log))</string>"))
            entries.append(("StandardErrorPath", "<string>\(escape(log))</string>"))
            entries.append(("ThrottleInterval", "<integer>5</integer>"))
        case .app:
            entries.append(("ProgramArguments", "<array>\n\t\t<string>\(escape(paths.appExecutable))</string>\n\t</array>"))
            // The app runs at login only; quitting it keeps it closed until the next login.
            entries.append(("RunAtLoad", "<true/>"))
            entries.append(("KeepAlive", "<false/>"))
        }
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>",
        ]
        for entry in entries {
            lines.append("\t<key>\(entry.key)</key>")
            lines.append("\t" + entry.value)
        }
        lines.append("</dict>")
        lines.append("</plist>")
        return lines.joined(separator: "\n") + "\n"
    }
}

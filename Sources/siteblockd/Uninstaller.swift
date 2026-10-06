import Foundation
import SiteBlockCore

extension PersistedState {
    /// True only when the saved state describes a real uninstall: the `uninstalling` flag is set and the uninstall countdown has run out. The flag alone is not enough, because anyone who can edit the state file could set it to make the daemon uninstall itself without the password and the wait.
    var hasFinishedUninstall: Bool {
        uninstalling && pendingUninstall?.isFinished == true
    }
}

/// Removes SiteBlock from the Mac once the uninstall countdown has finished.
enum Uninstaller {
    /// Wraps text in single quotes for a shell, so a path with spaces (like "Application Support") stays one word.
    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs the uninstall steps in order. `saveUninstallingState` must write the state with `uninstalling` set, so the watchdog stands down. In sandbox mode the function ends the process with exit code 0 after removing the hosts section, the sandbox's own plist files and its socket. In production it returns after starting the detached cleanup shell, and the caller then waits for launchd to stop the daemon; if the shell cannot be started it exits with code 1, so launchd restarts the daemon and the next start finishes the job.
    static func run(paths: Paths, enforcer: HostsEnforcer, saveUninstallingState: () -> Void, log: Logger) {
        // Step 1: record that an uninstall is under way before anything is removed, so a crash part-way is finished on the next start and the watchdog does not undo the work.
        saveUninstallingState()

        // Step 2: take SiteBlock's lines out of the hosts file (an empty block list) and flush the name cache.
        _ = enforcer.enforce(blockedHosts: [], causedByCommand: true)

        if paths.isSandbox {
            // A sandbox run has no launchd jobs and no installed files, so it only removes its own stand-ins and stops.
            for file in [paths.daemonPlist, paths.watchdogPlist, paths.appAgentPlist, paths.socket] { unlink(file) }
            log.log("uninstall finished (sandbox); exiting")
            exit(0)
        }

        // Safety check before anything is deleted: only the exact production locations are ever removed, and the shell below runs rm -rf on two of them.
        guard paths.stateDir == Paths.production.stateDir, paths.appBundle == Paths.production.appBundle else {
            log.log("uninstall stopped: refusing to delete unexpected paths")
            exit(1)
        }

        // Step 3: stop the menu bar app, so it does not keep running (and showing a dead icon) after its files are gone.
        stopMenuBarApp(log: log)

        // Step 4: delete the files that can be deleted while the daemon is still running.
        let files = [paths.backupDaemon, paths.stateBackup, paths.cliPath, paths.appAgentPlist, paths.daemonPlist, paths.watchdogPlist, paths.socket]
        for file in files { unlink(file) }
        // Remove the backup folder too when nothing else is in it; rmdir refuses a folder that still has files, which is what we want.
        rmdir(URL(fileURLWithPath: paths.backupDaemon).deletingLastPathComponent().path)

        // Step 5: the daemon cannot delete its own program or stop itself cleanly, so a separate shell does it after a short delay.
        let script = [
            "/bin/sleep 1",
            "/bin/launchctl bootout system/com.nokal.siteblock.watchdog",
            // The last bootout stops the daemon itself, which is why this shell has to be detached from it.
            "/bin/launchctl bootout system/com.nokal.siteblock.daemon",
            "/bin/rm -rf \(shellQuote(paths.stateDir)) \(shellQuote(paths.appBundle))",
        ].joined(separator: "; ")
        if startDetachedShell(script) {
            log.log("uninstall: files removed; cleanup shell started")
        } else {
            log.log("uninstall: could not start the cleanup shell; exiting so launchd restarts the daemon and retries")
            exit(1)
        }
    }

    /// Stops the menu bar app for the user who is logged in at the screen. The user is found from the owner of /dev/console; when nobody is logged in the owner is root (user ID 0) and there is nothing to stop. The app's LaunchAgent is booted out first so launchd does not hold it, then any remaining process named SiteBlock is killed (the app may have been opened by hand). Failures are ignored: an app that is not running is not a problem. The `run` closure runs one program and returns its exit code; tests pass a recording closure so no real program is started.
    static func stopMenuBarApp(log: Logger, run: (String, [String]) -> Int32 = { runProcess($0, $1, timeout: 5) }) {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else {
            log.log("uninstall: no console user; not stopping the menu bar app")
            return
        }
        let bootout = run("/bin/launchctl", ["bootout", "gui/\(info.st_uid)/com.nokal.siteblock.app"])
        let kill = run("/usr/bin/pkill", ["-x", "SiteBlock"])
        log.log("uninstall: stopped the menu bar app for uid \(info.st_uid) (bootout exit \(bootout), pkill exit \(kill))")
    }

    /// Starts `/bin/sh -c <script>` in a new session so it keeps running after the daemon is stopped. Returns false when the process could not be started.
    private static func startDetachedShell(_ script: String) -> Bool {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        // POSIX_SPAWN_SETSID gives the shell its own session (the same effect as calling setsid), so stopping the daemon's process group cannot take it down.
        // POSIX_SPAWN_CLOEXEC_DEFAULT closes every other file the daemon has open, so the shell does not hold the socket or the state file.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return false }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // With close-on-exec as the default, the shell's three standard streams must be opened explicitly; they go to /dev/null.
        guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0 else { return false }

        let arguments = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }
        // A minimal environment: the script uses full program paths and needs nothing else.
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { for pointer in environment { free(pointer) } }

        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environment) == 0
    }
}

import Foundation
import SiteBlockCore

/// Removes SiteBlock from the Mac once the uninstall countdown has finished.
enum Uninstaller {
    /// Wraps text in single quotes for a shell, so a path with spaces (like "Application Support") stays one word.
    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs the uninstall steps in order. `saveUninstallingState` must write the state with `uninstalling` set and return false when the write fails. In sandbox mode the function ends the process with exit code 0 after removing the hosts section, SiteBlock's Chrome policy keys, restoring the DNS servers, the sandbox's own plist files, its socket and its app and backup app bundles. In production it returns after starting the detached cleanup shell, and the caller then waits for launchd to stop the daemon. If the state cannot be saved, the watchdog cannot be unloaded, or the cleanup shell cannot be started, it exits with code 1 before (or instead of) deleting anything further, so launchd restarts the daemon and the next start retries from the saved finished countdown.
    static func run(paths: Paths, enforcer: HostsEnforcer, chromeEnforcer: ChromePolicyEnforcer, dnsEnforcer: DNSEnforcer, savedDNS: [String: [String]]?, saveUninstallingState: () -> Bool, log: Logger) {
        // Step 1: record that an uninstall is under way before anything is touched, so a crash part-way is finished on the next start. If the save fails (for example the disk is full), nothing has been changed yet, so stop here; the restarted daemon retries from the saved finished countdown. Going on with an old state file on disk could leave a half-removed install that the next start cannot recognize.
        guard saveUninstallingState() else {
            log.log("uninstall stopped: the uninstall marker could not be saved; exiting so it is retried")
            exit(1)
        }

        if !paths.isSandbox {
            // Safety check before anything is deleted: only the exact production locations are ever removed, and the shell below runs rm -rf on two of them.
            guard paths.stateDir == Paths.production.stateDir, paths.appBundle == Paths.production.appBundle, paths.appBackup == Paths.production.appBackup else {
                log.log("uninstall stopped: refusing to delete unexpected paths")
                exit(1)
            }
            // Step 2: unload the watchdog and wait for it, before any file is deleted. Once the state folder is gone, the watchdog would no longer see a finished uninstall and would restore everything it can.
            unloadWatchdog(log: log)
        }

        // Step 3: take SiteBlock's lines out of the hosts file (an empty block list) and flush the name cache. The same step takes every SiteBlock key out of Chrome's policy files (03 § 9: the block list and the adult-filter keys; a file with nothing else in it is deleted, and a file with other settings keeps them) and puts the original DNS servers back (03 § 11). All of it runs in production and in sandbox mode. A failed DNS restore is logged by the enforcer and does not stop the uninstall: a retry that can never succeed would leave SiteBlock installed for good.
        _ = enforcer.enforce(blockedHosts: [], causedByCommand: true)
        _ = chromeEnforcer.enforce(blockedSites: [], adultFilterActive: false, causedByCommand: true)
        // The saved record is not cleared on disk: the state folder is deleted a moment later, and a retry after a crash restores the same servers again.
        _ = dnsEnforcer.enforce(adultFilterActive: false, savedDNS: savedDNS, familyDNS: nil, persist: { _ in true })

        if paths.isSandbox {
            // A sandbox run has no launchd jobs and no installed files, so it only removes its own stand-ins and stops. That includes the stand-ins for the app and its backup, the same two bundles the production uninstall deletes (03 § 10).
            for file in [paths.daemonPlist, paths.watchdogPlist, paths.appAgentPlist, paths.newsyslogConf, paths.socket] { unlink(file) }
            for bundle in [paths.appBackup, paths.appBundle] { removeBundle(bundle) }
            log.log("uninstall finished (sandbox); exiting")
            exit(0)
        }

        // Step 4: stop the menu bar app, so it does not keep running (and showing a dead icon) after its files are gone.
        stopMenuBarApp(log: log)

        // Step 5: delete the files that can be deleted while the daemon is still running. The backup app bundle goes too, so nothing can restore the app after the uninstall (03 § 10); the guard timer was cancelled and waited for before the uninstaller started, so no guard run can put it back.
        removeBundle(paths.appBackup)
        let files = [paths.backupDaemon, paths.stateBackup, paths.cliPath, paths.appAgentPlist, paths.daemonPlist, paths.watchdogPlist, paths.newsyslogConf, paths.socket]
        for file in files { unlink(file) }
        // Remove the backup folder too when nothing else is in it; rmdir refuses a folder that still has files, which is what we want.
        rmdir(URL(fileURLWithPath: paths.backupDaemon).deletingLastPathComponent().path)

        // Step 6: the daemon cannot delete its own program or stop itself cleanly, so a separate shell does it after a short delay. The watchdog is already unloaded (step 2), so the shell only stops the daemon.
        let script = [
            "/bin/sleep 1",
            // This bootout stops the daemon itself, which is why this shell has to be detached from it.
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

    /// Deletes an app bundle folder (the backup, or in a sandbox the app itself). `removeItem` does not follow a symlink at the top level, so a link at that path is removed as a link and its target is left alone. A bundle that is already gone, or cannot be deleted, is ignored like every other file in the uninstall.
    private static func removeBundle(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Runs `launchctl bootout system/<watchdog label>` and waits for it, at most 10 seconds. A failure of the command itself is fine when the watchdog is not loaded any more (it may already have been unloaded). If the watchdog is still loaded after a failed bootout, the uninstall stops with exit code 1 before anything is deleted, because deleting files under a live watchdog would let it put them back.
    private static func unloadWatchdog(log: Logger) {
        let label = LaunchdPlists.Job.watchdog.label
        let result = runProcessCapturingOutput("/bin/launchctl", ["bootout", "system/\(label)"], timeout: 10)
        if result.status == 0 {
            log.log("uninstall: watchdog unloaded")
        } else if LaunchdGuard.isLoaded(.watchdog) {
            log.log("uninstall stopped: the watchdog could not be unloaded (launchctl bootout exited \(result.status): \(result.output)); exiting so it is retried")
            exit(1)
        } else {
            log.log("uninstall: watchdog was already unloaded (launchctl bootout exited \(result.status))")
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

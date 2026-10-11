import Foundation
import SiteBlockCore

/// Keeps the menu bar app installed and running (03 § 10). Every 5 seconds the daemon's guard timer calls `check()`, which puts the app bundle back from a root-owned backup when it is missing or damaged and, in production, keeps the app's LaunchAgent loaded for the person at the screen. The blocking never depends on the app; this only stops the app from being deleted, trashed or unloaded to make SiteBlock disappear from view. Every call comes from the guard queue, one at a time, so the type keeps plain mutable state and needs no lock.
final class AppGuard {
    // A failure message of the same kind is logged at most this often, so a problem that persists (a full disk, a missing backup) does not write a line every 5 seconds.
    private static let repeatedFailureLogInterval = Duration.seconds(60)
    // The most time ditto may take to copy the app bundle. A real copy takes well under a second; the limit only stops a hung copy from holding up the guard queue.
    private static let copyTimeout: TimeInterval = 30
    // The most time one launchctl call may take.
    private static let launchctlTimeout: TimeInterval = 10

    /// The kinds of failure that are rate-limited separately, so one kind of problem cannot hide another.
    private enum FailureKind {
        /// The backup bundle is missing or incomplete, so nothing can be restored.
        case backupUnusable
        /// The damaged item at the app path could not be removed.
        case removeFailed
        /// ditto could not copy the backup into place.
        case copyFailed
        /// The restored bundle could not be given to root:wheel.
        case ownerFailed
        /// The app's LaunchAgent plist could not be written.
        case plistFailed
        /// launchctl could not load the app's LaunchAgent.
        case bootstrapFailed
    }

    /// What one look at a bundle folder found.
    private enum BundleState {
        /// The bundle has its executable and Info.plist as plain files; the executable's size is kept for comparing with the backup.
        case complete(executableSize: off_t)
        /// The bundle is not complete, with a short reason for the log.
        case incomplete(String)
    }

    /// What the bundle step of a pass ended with.
    private enum BundleOutcome {
        /// The app was already complete and matched the backup.
        case intact
        /// The app was broken and has been copied back from the backup.
        case restored
        /// The backup cannot be used, so nothing was checked or restored.
        case backupUnusable
        /// The app was broken and the restore failed (the reason was logged).
        case failed
    }

    private let paths: Paths
    private let log: Logger
    // Returns true once an uninstall has begun, so a pass that is already running stops before it restores anything.
    private let isCancelled: () -> Bool
    // When each kind of failure was last written to the log.
    private var lastFailureLogged: [FailureKind: ContinuousClock.Instant] = [:]

    /// Creates a guard for the app and backup locations named in the paths. `isCancelled` is asked between the steps of a pass; it must return true once an uninstall has started.
    init(paths: Paths, log: Logger, isCancelled: @escaping () -> Bool) {
        self.paths = paths
        self.log = log
        self.isCancelled = isCancelled
    }

    /// Runs one pass: first the bundle check (production and sandbox), then, in production only, the agent check. Does nothing, and logs nothing, when everything is in order. A missing or unusable backup ends the pass after the bundle step, because there is nothing to restore from.
    func check() {
        if isCancelled() { return }
        let outcome = restoreBundleIfNeeded()
        if outcome == .backupUnusable { return }
        // launchctl, ownership and the console user only exist on a real system, so sandbox runs stop here.
        if paths.isSandbox || isCancelled() { return }
        keepAgentLoaded(startNow: outcome == .restored)
    }

    // MARK: - Bundle check

    /// Compares the app with the backup and copies the backup back when the app is not complete or its executable has a different size. Returns what happened.
    private func restoreBundleIfNeeded() -> BundleOutcome {
        // The backup must itself be a complete bundle. Restoring from a half-empty one would only produce another broken app and repeat every 5 seconds.
        guard case .complete(let backupSize) = inspectBundle(paths.appBackup) else {
            logFailure(.backupUnusable, "cannot check the menu bar app: the backup at \(paths.appBackup) is missing or incomplete")
            return .backupUnusable
        }
        let reason: String
        switch inspectBundle(paths.appBundle) {
        case .incomplete(let why):
            reason = why
        case .complete(let size):
            // The size is the cheap test for "replaced by a different program": a copy of the backup always has the backup's size.
            if size == backupSize { return .intact }
            reason = "the executable differs from the backup"
        }
        return restoreBundle(reason: reason)
    }

    /// Removes whatever is at the app path and copies the backup there with ditto. Returns `.restored` on success and `.failed` (after a rate-limited log line) otherwise. A failed copy removes its own partial result, so the next pass starts clean.
    private func restoreBundle(reason: String) -> BundleOutcome {
        if isCancelled() { return .failed }
        var info = stat()
        // lstat does not follow a link, so a symlink at the app path counts as "something is there" and is removed below.
        if lstat(paths.appBundle, &info) == 0 {
            do {
                // removeItem does not follow a symlink at the top level: a link is deleted as a link, and the folder it points to is left alone.
                try FileManager.default.removeItem(atPath: paths.appBundle)
            } catch {
                logFailure(.removeFailed, "cannot restore the menu bar app: removing \(paths.appBundle) failed: \(error.localizedDescription)")
                return .failed
            }
        }
        // The folder that holds the app is normally /Applications; it is only created if it has gone missing (in a sandbox it starts out absent).
        let parent = URL(fileURLWithPath: paths.appBundle).deletingLastPathComponent().path
        if lstat(parent, &info) != 0 { try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        if isCancelled() { return .failed }

        let copy = runProcessCapturingOutput("/usr/bin/ditto", [paths.appBackup, paths.appBundle], timeout: AppGuard.copyTimeout)
        guard copy.status == 0 else {
            // A half-copied bundle could pass the next check (its executable may already be complete), so it is deleted rather than left behind.
            try? FileManager.default.removeItem(atPath: paths.appBundle)
            logFailure(.copyFailed, "cannot restore the menu bar app: ditto exited \(copy.status): \(copy.output)")
            return .failed
        }
        // A sandbox runs as an ordinary user, who cannot give files to root.
        if !paths.isSandbox, !setOwnerToRootWheel(paths.appBundle) {
            logFailure(.ownerFailed, "restored the menu bar app but could not set \(paths.appBundle) to root:wheel")
        }
        log.log("menu bar app restored (\(reason))")
        return .restored
    }

    /// Looks at a bundle folder without following links: the folder, its `Contents` and `Contents/MacOS` must be real folders, and `Contents/MacOS/SiteBlock` and `Contents/Info.plist` must be plain files. A link anywhere on that route counts as incomplete, so a symlink planted at the app path (even one pointing at a perfect copy) is replaced.
    private func inspectBundle(_ root: String) -> BundleState {
        var info = stat()
        guard lstat(root, &info) == 0 else { return .incomplete("the app is missing") }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .incomplete("the app path is not a plain folder") }
        for folder in ["/Contents", "/Contents/MacOS"] {
            guard lstat(root + folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .incomplete("the app's \(folder) folder is missing or not a plain folder") }
        }
        guard lstat(root + "/Contents/Info.plist", &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .incomplete("Info.plist is missing or not a plain file") }
        guard lstat(root + "/Contents/MacOS/SiteBlock", &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .incomplete("the executable is missing or not a plain file") }
        return .complete(executableSize: info.st_size)
    }

    /// Sets the folder and everything inside it to owner root, group wheel. Uses `lchown`, which changes a link itself and never the file it points to. Returns false when any item could not be changed.
    private func setOwnerToRootWheel(_ root: String) -> Bool {
        var allChanged = lchown(root, 0, 0) == 0
        guard let walker = FileManager.default.enumerator(atPath: root) else { return false }
        for case let relative as String in walker where lchown(root + "/" + relative, 0, 0) != 0 { allChanged = false }
        return allChanged
    }

    // MARK: - Agent check (production only)

    /// Makes sure the app's LaunchAgent is loaded for the person at the screen. When `startNow` is true (the bundle was just restored) it also kick-starts the agent, so the app returns at once instead of after launchd's next retry. Does nothing when nobody is logged in.
    private func keepAgentLoaded(startNow: Bool) {
        guard let uid = AppGuard.consoleUser() else { return }
        let target = "gui/\(uid)/\(LaunchdPlists.Job.app.label)"
        // `launchctl print` exits 0 only for a loaded job. A failure means someone booted the agent out.
        if runProcess("/bin/launchctl", ["print", target], timeout: AppGuard.launchctlTimeout) != 0 { reloadAgent(uid: uid, target: target) }
        // Without -k this only starts a stopped job; a running app is left alone.
        if startNow { _ = runProcess("/bin/launchctl", ["kickstart", target], timeout: AppGuard.launchctlTimeout) }
    }

    /// Rewrites the LaunchAgent plist if it is missing or different, then loads it into the user's session. Logs "menu bar app agent reloaded" on success and a rate-limited failure line otherwise.
    private func reloadAgent(uid: uid_t, target: String) {
        let plist = paths.appAgentPlist
        let expected = Data(LaunchdPlists.xml(for: .app, paths: paths).utf8)
        if FileManager.default.contents(atPath: plist) != expected {
            guard LaunchdGuard.writeFile(expected, to: plist, mode: 0o644, createFolderMode: 0o755) else {
                logFailure(.plistFailed, "cannot reload the menu bar app agent: writing \(plist) failed")
                return
            }
            log.log("restored \(LaunchdPlists.Job.app.label) plist")
        } else {
            // launchd refuses a plist that is not owned by root or that others can write, so owner and mode are checked even when the text is right.
            LaunchdGuard.fixOwnerAndMode(plist, mode: 0o644)
        }
        // `launchctl disable` makes launchd refuse to load the job, and any user can run it on their own session. The mark is cleared first; a failure here is ignored because bootstrap reports the real outcome.
        _ = runProcess("/bin/launchctl", ["enable", target], timeout: AppGuard.launchctlTimeout)
        let result = runProcessCapturingOutput("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist], timeout: AppGuard.launchctlTimeout)
        if result.status == 0 {
            log.log("menu bar app agent reloaded")
        } else {
            logFailure(.bootstrapFailed, "cannot reload the menu bar app agent: launchctl bootstrap exited \(result.status): \(result.output)")
        }
    }

    /// The user ID of the person logged in at the screen: the owner of /dev/console. Returns nil when that is root (nobody is logged in) or when it cannot be read, because there is no session to load the agent into.
    private static func consoleUser() -> uid_t? {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else { return nil }
        return info.st_uid
    }

    // MARK: - Logging

    /// Writes a failure line, but only if a failure of the same kind was not written within the last minute. Successful repairs are logged directly, never through here.
    private func logFailure(_ kind: FailureKind, _ message: String) {
        let now = ContinuousClock.now
        if let last = lastFailureLogged[kind], now - last < AppGuard.repeatedFailureLogInterval { return }
        lastFailureLogged[kind] = now
        log.log(message)
    }
}

import Foundation
import SiteBlockCore

/// Keeps SiteBlock's two background jobs loaded in launchd. The daemon guards the watchdog and the watchdog guards the daemon, so unloading one of them with `launchctl bootout` is undone by the other within five seconds. Nothing here ever runs in sandbox mode.
enum LaunchdGuard {
    /// The two system-level jobs that guard each other.
    enum Job {
        /// The main service.
        case daemon
        /// The guard job.
        case watchdog

        /// The launchd label that identifies the job.
        var label: String { plistJob.label }

        /// The matching entry in the plist generator.
        var plistJob: LaunchdPlists.Job {
            switch self {
            case .daemon: return .daemon
            case .watchdog: return .watchdog
            }
        }

        /// The location of the job's plist file.
        func plistPath(in paths: Paths) -> String { plistJob.plistPath(in: paths) }
    }

    /// True when launchd has the job loaded. Runs `/bin/launchctl print system/<label>`, which exits with code 0 only for a loaded job. Always true in sandbox mode, so nothing is ever "repaired" there.
    static func isLoaded(_ job: Job, paths: Paths = .production) -> Bool {
        guard !paths.isSandbox else { return true }
        return runProcess("/bin/launchctl", ["print", "system/\(job.label)"], timeout: 5) == 0
    }

    /// Makes sure the job's files are intact and the job is loaded. It first puts back a missing or changed plist and a missing program, so a job whose files were deleted can start again even while launchd still has it loaded. When the job is not loaded it then runs `/bin/launchctl bootstrap system <plist>`. Every repair is logged. Does nothing in sandbox mode.
    static func ensureLoaded(_ job: Job, paths: Paths = .production, log: Logger = Logger()) {
        guard !paths.isSandbox else { return }
        restoreFiles(job, paths: paths, log: log)
        if isLoaded(job, paths: paths) { return }

        let plist = job.plistPath(in: paths)
        let result = runProcessCapturingOutput("/bin/launchctl", ["bootstrap", "system", plist], timeout: 10)
        if result.status == 0 {
            log.log("reloaded \(job.label)")
        } else {
            log.log("could not reload \(job.label): launchctl bootstrap exited \(result.status): \(result.output)")
        }
    }

    /// Rewrites the plist if it is missing or different from the one built into this program, fixes its owner and mode, and copies the program back from the backup location if it is missing or not runnable.
    private static func restoreFiles(_ job: Job, paths: Paths, log: Logger) {
        let plistPath = job.plistPath(in: paths)
        let expected = Data(LaunchdPlists.xml(for: job.plistJob, paths: paths).utf8)
        if FileManager.default.contents(atPath: plistPath) != expected {
            if writeFile(expected, to: plistPath, mode: 0o644, createFolderMode: 0o755) {
                log.log("restored \(job.label) plist")
            } else {
                log.log("could not restore \(job.label) plist at \(plistPath)")
            }
        } else {
            // launchd refuses a plist that is not owned by root or that others can write, so the owner and mode are checked even when the text is right.
            fixOwnerAndMode(plistPath, mode: 0o644)
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: paths.daemonProgram, isDirectory: &isDirectory)
        if !exists || isDirectory.boolValue || !FileManager.default.isExecutableFile(atPath: paths.daemonProgram) {
            guard let program = FileManager.default.contents(atPath: paths.backupDaemon) else {
                log.log("cannot restore \(paths.daemonProgram): the backup at \(paths.backupDaemon) is missing")
                return
            }
            if writeFile(program, to: paths.daemonProgram, mode: 0o755, createFolderMode: 0o755) {
                log.log("restored \(paths.daemonProgram) from backup")
            } else {
                log.log("could not restore \(paths.daemonProgram) from \(paths.backupDaemon)")
            }
        }
    }

    /// Sets the file's owner to root:wheel and its mode, but only when they are not already right, so a healthy system sees no writes.
    private static func fixOwnerAndMode(_ path: String, mode: mode_t) {
        var info = stat()
        guard stat(path, &info) == 0 else { return }
        if info.st_uid != 0 || info.st_gid != 0 { _ = chown(path, 0, 0) }
        if info.st_mode & 0o7777 != mode { _ = chmod(path, mode) }
    }

    /// Writes the data to a temp file beside the target, sets mode and root:wheel ownership, and renames it into place, so the target is never half-written. Creates the folder when missing. Returns false on any failure.
    private static func writeFile(_ data: Data, to path: String, mode: mode_t, createFolderMode: mode_t) -> Bool {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: folder) {
            do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(createFolderMode)]) } catch { return false }
        }
        let tempPath = path + ".siteblock.tmp"
        _ = unlink(tempPath)
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        if fd < 0 { return false }
        var ok = true
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                offset += written
            }
        }
        if ok, fchmod(fd, mode) != 0 { ok = false }
        if ok, fchown(fd, 0, 0) != 0 { ok = false }
        if ok, fsync(fd) != 0 { ok = false }
        close(fd)
        if ok, rename(tempPath, path) != 0 { ok = false }
        if !ok { _ = unlink(tempPath) }
        return ok
    }
}

/// Runs the watchdog until it is stopped: every 5 seconds it makes sure the daemon is loaded. It stands down while an uninstall is in progress (the state file says so, or the install folder is gone), and it never touches the hosts file or the socket.
func runWatchdog(paths: Paths, log: Logger) -> Never {
    log.log("watchdog started")
    while true {
        if !uninstallInProgress(paths: paths) { LaunchdGuard.ensureLoaded(.daemon, paths: paths, log: log) }
        sleep(5)
    }
}

/// True when the watchdog must not reload the daemon: the install folder has been removed, or the state file describes a finished uninstall (`uninstalling` set and the uninstall countdown run out). A state file that cannot be read or decoded counts as "not uninstalling", and so does a bare `uninstalling` flag with no finished countdown (hand-editing), so neither can switch the guard off. It decodes the file directly instead of using `StateStore.load`, because loading would rename a damaged file out of the daemon's way.
func uninstallInProgress(paths: Paths) -> Bool {
    if !FileManager.default.fileExists(atPath: paths.stateDir) { return true }
    guard let data = FileManager.default.contents(atPath: paths.stateFile), let state = try? JSONCoding.decoder.decode(PersistedState.self, from: data) else { return false }
    return state.hasFinishedUninstall
}

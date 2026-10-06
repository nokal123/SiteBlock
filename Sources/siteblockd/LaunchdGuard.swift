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

    /// Makes sure the job's files are intact and the job is loaded. It first recreates a missing state folder and its `bin` folder, then puts back a missing or changed plist and a missing program, so a job whose files were deleted can start again even while launchd still has it loaded. When the job is not loaded it clears any "disabled" mark with `/bin/launchctl enable system/<label>` and then runs `/bin/launchctl bootstrap system <plist>`. Every repair is logged. Does nothing in sandbox mode.
    static func ensureLoaded(_ job: Job, paths: Paths = .production, log: Logger = Logger()) {
        guard !paths.isSandbox else { return }
        ensureFolder(paths.stateDir, mode: 0o700, log: log)
        ensureFolder(paths.stateDir + "/bin", mode: 0o755, log: log)
        restoreFiles(job, paths: paths, log: log)
        if isLoaded(job, paths: paths) { return }

        // `launchctl disable` (or switching the item off under "Allow in the Background" in System Settings) makes launchd refuse to load the job, so the mark is cleared first. Failure is ignored: bootstrap below reports the real outcome.
        _ = runProcess("/bin/launchctl", ["enable", "system/\(job.label)"], timeout: 5)
        let plist = job.plistPath(in: paths)
        let result = runProcessCapturingOutput("/bin/launchctl", ["bootstrap", "system", plist], timeout: 10)
        if result.status == 0 {
            log.log("reloaded \(job.label)")
        } else {
            log.log("could not reload \(job.label): launchctl bootstrap exited \(result.status): \(result.output)")
        }
    }

    /// Creates one folder, and only that folder, when it is missing, then sets its owner to root:wheel and its mode explicitly (the process umask would otherwise trim the mode). Parent folders are never created here: the state folder must be made as 0700 on its own, because creating it as a side effect of making `bin` would leave it world-readable. A folder that already exists is left alone.
    private static func ensureFolder(_ path: String, mode: mode_t, log: Logger) {
        var info = stat()
        if lstat(path, &info) == 0 { return }
        // The folder is created with the final mode up front, so it is never wider than intended, even for an instant.
        guard mkdir(path, mode) == 0 else {
            log.log("could not create \(path): \(String(cString: strerror(errno)))")
            return
        }
        _ = chown(path, 0, 0)
        _ = chmod(path, mode)
        log.log("recreated \(path)")
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

    /// Writes the data to a temp file beside the target, sets mode and root:wheel ownership, and renames it into place, so the target is never half-written. Creates the target's own folder (but never its parents) when missing. Returns false on any failure.
    private static func writeFile(_ data: Data, to path: String, mode: mode_t, createFolderMode: mode_t) -> Bool {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: folder) {
            // Only the folder itself is created, never its parents, so a missing state folder cannot be made with the wrong mode as a side effect.
            do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: Int(createFolderMode)]) } catch { return false }
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

/// Runs the watchdog until it is stopped: every 5 seconds it makes sure the daemon is loaded. It stands down only when the state file records a finished uninstall (see `UninstallRule`), and it never touches the hosts file or the socket. A missing install folder or state file is not an uninstall, so deleting the folder is repaired instead.
func runWatchdog(paths: Paths, log: Logger) -> Never {
    log.log("watchdog started")
    while true {
        if !UninstallRule.watchdogShouldStandDown(stateFileData: FileManager.default.contents(atPath: paths.stateFile)) { LaunchdGuard.ensureLoaded(.daemon, paths: paths, log: log) }
        sleep(5)
    }
}

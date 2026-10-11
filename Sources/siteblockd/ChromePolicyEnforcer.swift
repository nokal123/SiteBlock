import Foundation
import SiteBlockCore

/// Keeps Chrome's mandatory `URLBlocklist` policy equal to the block list, so Chrome refuses blocked sites even in windows whose traffic goes through a proxy and never reads the hosts file. The text rules (which names, how to merge with other settings) live in `ChromePolicy`; this class finds the files, reads them, writes them safely, and reports whether they are right.
final class ChromePolicyEnforcer {
    // A failure message that repeats is logged at most this often, so a persistent problem (such as a read-only disk) does not write a line every tick.
    private static let repeatedFailureLogInterval = Duration.seconds(60)
    // A policy file bigger than this is not read. Real ones are a few kilobytes; a huge one is treated as damaged and replaced.
    private static let maxPolicyFileBytes = 4 * 1024 * 1024
    // The mode a policy file must have so that Chrome, which runs as the logged-in user, can read it.
    private static let policyFileMode: mode_t = 0o644

    private let paths: Paths
    private let log: Logger
    private var lastFailure: (message: String, at: ContinuousClock.Instant)?
    // The console user's name from the last successful lookup, kept with the user ID it was found for. The user database is asked again only when a different user ID owns the console, so a slow lookup cannot delay every tick.
    private var cachedConsoleUser: (uid: uid_t, name: String)?

    /// Creates an enforcer for the managed preferences folder named in the paths. In sandbox mode it never changes file ownership.
    init(paths: Paths, log: Logger) {
        self.paths = paths
        self.log = log
    }

    /// What one pass did to one policy file.
    private enum FileOutcome {
        /// The file was already right, or was absent and should be.
        case unchanged
        /// The file was written or deleted.
        case changed
        /// The file could not be made right (the reason was logged).
        case failed
    }

    /// What was found at a policy file path.
    private struct ExistingFile {
        /// True when anything exists at the path.
        var exists = false
        /// The settings in the file, or nil when it is missing, not a property list, not a dictionary, or too big.
        var contents: [String: Any]?
        /// False when the file is not a plain file with Chrome-readable mode (and, in production, owner root:wheel), so it must be rewritten even if its settings are right.
        var attributesCorrect = false
    }

    /// Makes the machine-wide file and the console user's file hold the block list. Returns true when both are correct after the pass. `causedByCommand` should be true when the caller just changed the block list on purpose (a command, or a countdown that finished), so the rewrite is expected and is not logged.
    func enforce(blockedSites: [BlockedSite], causedByCommand: Bool = false) -> Bool {
        let blocklist = ChromePolicy.urlBlocklist(for: blockedSites)
        var targets = [paths.chromePolicyMachinePlist]
        // The per-user copy is what Chrome reloads within seconds of a change, so it is kept next to the machine-wide one.
        if let user = consoleUserName() { targets.append(paths.chromePolicyUserPlist(forUser: user)) }

        var healthy = true
        var changedAny = false
        for target in targets {
            switch enforceFile(at: target, blocklist: blocklist) {
            case .unchanged: break
            case .changed: changedAny = true
            case .failed: healthy = false
            }
        }
        if healthy { lastFailure = nil }
        // A rewrite nobody asked for means someone (or another program) changed the policy files, so it goes in the log.
        if changedAny && !causedByCommand { log.log("Chrome policy repaired") }
        return healthy
    }

    /// The name of the person logged in at the screen: the owner of /dev/console, looked up in the user database. Returns nil when nobody is logged in (the owner is root, user ID 0), when the owner cannot be read, or when the name cannot be looked up or could not be a single folder name. In those cases only the machine-wide copy is written.
    private func consoleUserName() -> String? {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else { return nil }
        if let cached = cachedConsoleUser, cached.uid == info.st_uid { return cached.name }
        guard let entry = getpwuid(info.st_uid) else { return nil }
        let name = String(cString: entry.pointee.pw_name)
        // The name becomes a folder name under root's managed preferences folder, so one that could point somewhere else is refused.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        // Only a successful lookup is remembered, so a lookup that failed for a moment (for example early in boot) is tried again on the next pass.
        cachedConsoleUser = (info.st_uid, name)
        return name
    }

    /// Brings one policy file in line with the block list: leaves it alone when its settings and attributes are right, deletes it when nothing should remain in it, and otherwise rewrites it with the block list merged into its other settings.
    private func enforceFile(at path: String, blocklist: [String]) -> FileOutcome {
        let existing = readExisting(path)
        guard let wanted = ChromePolicy.merged(existing: existing.contents, blocklist: blocklist) else {
            // Nothing should remain in the file, so a leftover file (or a symlink or damaged file in its place) is deleted. An absent file is already right.
            guard existing.exists else { return .unchanged }
            if unlink(path) == 0 || errno == ENOENT { return .changed }
            logFailure("Chrome policy file could not be deleted: \(path): \(String(cString: strerror(errno)))")
            return .failed
        }
        // Compared as property list dictionaries, so the order of keys and the file format (XML or binary) do not matter.
        if existing.attributesCorrect, let current = existing.contents, NSDictionary(dictionary: current).isEqual(to: wanted) { return .unchanged }

        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
        } catch {
            logFailure("Chrome policy could not be encoded: \(error.localizedDescription)")
            return .failed
        }
        if let failure = ensureFolder(folder) ?? writeAtomically(Array(data), to: path, folder: folder) {
            logFailure("Chrome policy file could not be updated: \(path): \(failure)")
            return .failed
        }
        return .changed
    }

    /// Opens the file without following a symlink, checks that it is a plain file of reasonable size, and reads its settings. A missing file gives `exists == false`. A file that cannot be opened, is not a plain file, is too big, is not a property list, or is not a dictionary gives `exists == true` and no contents, so it is replaced as if it were empty.
    private func readExisting(_ path: String) -> ExistingFile {
        // O_NONBLOCK keeps a named pipe planted at this path from freezing the daemon: without it, open() waits forever for a writer. The fstat check below then sees it is not a plain file and has it replaced.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return ExistingFile(exists: errno != ENOENT, contents: nil, attributesCorrect: false) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return ExistingFile(exists: true, contents: nil, attributesCorrect: false) }

        // Mode must let Chrome read the file; in production the owner must also be root:wheel, so a file that a program running as the user could replace is rewritten.
        var attributesCorrect = (info.st_mode & 0o7777) == ChromePolicyEnforcer.policyFileMode
        if !paths.isSandbox, info.st_uid != 0 || info.st_gid != 0 { attributesCorrect = false }

        guard info.st_size <= ChromePolicyEnforcer.maxPolicyFileBytes,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return ExistingFile(exists: true, contents: nil, attributesCorrect: false) }
        return ExistingFile(exists: true, contents: dictionary, attributesCorrect: attributesCorrect)
    }

    /// Makes sure the folder exists. In production a missing folder is created with mode 0755 and owner root:wheel; in sandbox mode it is a plain `createDirectory`. Something that is not a folder (a file or a dangling symlink planted at the folder's path) is removed first. Returns nil on success, or the reason it failed.
    private func ensureFolder(_ folder: String) -> String? {
        var info = stat()
        if stat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { return nil }
        // lstat does not follow a link, so this removes whatever is at the path (a file, or a link that points nowhere) and leaves nothing in the way of the mkdir below.
        if lstat(folder, &info) == 0, unlink(folder) != 0 { return "cannot remove \(folder), which is not a folder: \(String(cString: strerror(errno)))" }

        if paths.isSandbox {
            do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch { return "cannot create \(folder): \(error.localizedDescription)" }
            return nil
        }
        // The managed preferences folder itself already exists on macOS; a per-user folder inside it may not. mkdir is subject to the umask, so the mode is set again explicitly.
        if mkdir(folder, 0o755) != 0 && errno != EEXIST { return "cannot create \(folder): \(String(cString: strerror(errno)))" }
        if chmod(folder, 0o755) != 0 { return "cannot set permissions on \(folder): \(String(cString: strerror(errno)))" }
        if chown(folder, 0, 0) != 0 { return "cannot set owner root:wheel on \(folder): \(String(cString: strerror(errno)))" }
        return nil
    }

    /// Creates a new empty temp file in the folder with a random name, using O_CREAT, O_EXCL (fail if anything already exists there) and O_NOFOLLOW (never follow a symlink), so a file or link planted at a guessed name cannot redirect the write. Returns the open descriptor and the path, or a descriptor of -1 and the reason.
    private func createTempFile(in folder: String) -> (fd: Int32, path: String, failure: String) {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var failure = "no free temp file name"
        // A few tries, because a random name can in rare cases already exist; any other error is final.
        for _ in 0..<8 {
            let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
            let path = "\(folder)/.chrome.siteblock.\(suffix)"
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { return (fd, path, "") }
            failure = String(cString: strerror(errno))
            if errno != EEXIST { break }
        }
        return (-1, "", failure)
    }

    /// Writes every byte to the descriptor, retrying after interrupts and partial writes. Returns nil on success, or the reason it failed.
    private func writeAll(_ bytes: [UInt8], to fd: Int32) -> String? {
        var failure: String?
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = "write failed: \(String(cString: strerror(errno)))"
                    return
                }
                offset += written
            }
        }
        return failure
    }

    /// Writes the bytes to a randomly named temp file in the folder and renames it over the target, so Chrome always sees either the old or the new file, never a half-written one. The rename replaces a symlink at the target instead of following it. Returns nil on success, or the reason it failed.
    private func writeAtomically(_ bytes: [UInt8], to path: String, folder: String) -> String? {
        let temp = createTempFile(in: folder)
        if temp.fd < 0 { return "cannot create a temp file in \(folder): \(temp.failure)" }
        var failure: String?
        // The mode is set on the open file, so it is 0644 whatever the process umask is.
        if fchmod(temp.fd, ChromePolicyEnforcer.policyFileMode) != 0 { failure = "cannot set permissions: \(String(cString: strerror(errno)))" }
        // Only the installed daemon changes ownership: a sandbox run is not root and must not try.
        if failure == nil, !paths.isSandbox, fchown(temp.fd, 0, 0) != 0 { failure = "cannot set owner root:wheel: \(String(cString: strerror(errno)))" }
        if failure == nil { failure = writeAll(bytes, to: temp.fd) }
        if failure == nil, fsync(temp.fd) != 0 { failure = "cannot flush to disk: \(String(cString: strerror(errno)))" }
        close(temp.fd)
        if failure == nil, rename(temp.path, path) != 0 { failure = "cannot replace \(path): \(String(cString: strerror(errno)))" }
        // After a successful rename the temp file is already gone, so this removes only a temp file left behind by a failure.
        _ = unlink(temp.path)
        return failure
    }

    /// Logs a failure message, unless the same message was already logged within the last minute.
    private func logFailure(_ message: String) {
        let now = ContinuousClock.now
        if let last = lastFailure, last.message == message, now - last.at < ChromePolicyEnforcer.repeatedFailureLogInterval { return }
        lastFailure = (message, now)
        log.log(message)
    }
}

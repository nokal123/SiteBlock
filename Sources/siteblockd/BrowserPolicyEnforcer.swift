import Foundation
import SiteBlockCore

/// Keeps the mandatory policy files of Chrome, Edge, Brave and Firefox equal to what SiteBlock wants: each browser's block list (so the browser refuses blocked sites and path rules even in windows whose traffic goes through a proxy and never reads the hosts file) and its adult content filter and DNS settings. Which keys and values each browser gets, and how they are merged with other settings, live in `BrowserTarget` and `BrowserPolicy`; this class finds the files, reads them, writes them safely, and reports whether they are right.
final class BrowserPolicyEnforcer {
    // A failure message that repeats is logged at most this often, so a persistent problem (such as a read-only disk) does not write a line every tick.
    private static let repeatedFailureLogInterval = Duration.seconds(60)
    // A policy file bigger than this is not read. Real ones are a few kilobytes; a huge one is treated as damaged and replaced.
    private static let maxPolicyFileBytes = 4 * 1024 * 1024
    // The mode a policy file must have so that the browser, which runs as the logged-in user, can read it.
    private static let policyFileMode: mode_t = 0o644

    private let paths: Paths
    private let log: Logger
    // When each failure message was last logged. Several files can fail in one pass, so each message is tracked on its own; a single slot would be overwritten by the next file's message and every message would be logged again on every tick.
    private var lastFailures: [String: ContinuousClock.Instant] = [:]
    // The browsers whose list was too long on the last pass and has already been reported, so the cut is logged once and not on every tick.
    private var reportedCuts: Set<BrowserTarget> = []
    // The console user's name from the last successful lookup, kept with the user ID it was found for. The user database is asked again only when a different user ID owns the console, so a slow lookup cannot delay every tick.
    private var cachedConsoleUser: (uid: uid_t, name: String)?

    /// Creates an enforcer for the managed preferences folders named in the paths. In sandbox mode it never changes file ownership.
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
        /// False when the file is not a plain file with browser-readable mode (and, in production, owner root:wheel), so it must be rewritten even if its settings are right.
        var attributesCorrect = false
    }

    /// The policy files of one browser: the machine-wide file, the console user's file when somebody is logged in, and for Firefox the third file in the machine-wide preferences folder.
    private func files(for target: BrowserTarget, consoleUser: String?) -> [String] {
        var files = [paths.browserPolicyMachinePlist(bundleID: target.bundleID)]
        // The per-user copy is what the browser reloads within seconds of a change, so it is kept next to the machine-wide one.
        if let user = consoleUser { files.append(paths.browserPolicyUserPlist(bundleID: target.bundleID, user: user)) }
        if target.alsoUsesLibraryPreferencesFile { files.append(paths.firefoxPreferencesPlist) }
        return files
    }

    /// Makes every browser's policy files hold the block lists and, while `adultFilterActive` is true, the adult content filter and DNS settings. Returns true when every file is correct after the pass. `causedByCommand` should be true when the caller just changed the block list on purpose (a command, or a countdown that finished), so the rewrite is expected and is not logged. The uninstaller passes empty lists and `adultFilterActive: false`, which takes every SiteBlock key out of every file.
    func enforce(blockLists: BrowserBlockLists, adultFilterActive: Bool, causedByCommand: Bool = false) -> Bool {
        let consoleUser = consoleUserName()
        var healthy = true
        var wroteAnyFile = false
        defer { if wroteAnyFile { refreshPreferencesCache() } }
        for target in BrowserTarget.allCases {
            let parts = target.lists(from: blockLists)
            // Browsers ignore entries past 1,000, so a longer list is cut here, with whole sites kept before path rules.
            let capped = BrowserPolicy.capped(sites: parts.sites, paths: parts.paths)
            reportCut(target, droppedCount: capped.droppedCount)
            let managed = target.managedValues(blockList: capped.list, adultFilter: adultFilterActive)
            var changedAny = false
            for path in files(for: target, consoleUser: consoleUser) {
                switch enforceFile(at: path, target: target, managed: managed) {
                case .unchanged: break
                case .changed: changedAny = true; wroteAnyFile = true
                case .failed: healthy = false
                }
            }
            // A rewrite nobody asked for means someone (or another program) changed the policy files, so it goes in the log.
            if changedAny && !causedByCommand { log.log("browser policy repaired (\(target.displayName))") }
        }
        if healthy { lastFailures = [:] }
        return healthy
    }

    /// Makes macOS hand the browsers the policy files' new contents. Browsers do not read these files themselves: they ask cfprefsd, the macOS service that reads and caches app settings, and cfprefsd is not told when a file under /Library/Managed Preferences is rewritten directly, so it keeps serving the copy it read first. Stopping the person-at-the-screen's cfprefsd makes launchd start a fresh one on the next request, which reads the files again; running browsers then pick the change up on their next policy reload. Production only, and a failure is ignored (nothing worse than the old behaviour follows).
    private func refreshPreferencesCache() {
        guard !paths.isSandbox else { return }
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else { return }
        _ = runProcess("/usr/bin/pkill", ["-x", "-U", String(info.st_uid), "cfprefsd"], timeout: 5)
    }

    /// Logs once when a browser's list had to be cut to the 1,000 entries the browser reads, and forgets the report when the list is short enough again.
    private func reportCut(_ target: BrowserTarget, droppedCount: Int) {
        if droppedCount == 0 {
            reportedCuts.remove(target)
        } else if reportedCuts.insert(target).inserted {
            log.log("browser block list for \(target.displayName) cut to \(BrowserPolicy.maxListEntries) entries; \(droppedCount) path rules or sites are not enforced in that browser")
        }
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

    /// Brings one policy file in line with what SiteBlock wants: leaves it alone when its settings and attributes are right, deletes it when nothing should remain in it, and otherwise rewrites it with SiteBlock's keys merged into its other settings. Any SiteBlock key with a different value, a different type, or no value at all makes the file differ, so it is rewritten.
    private func enforceFile(at path: String, target: BrowserTarget, managed: [String: Any]) -> FileOutcome {
        let existing = readExisting(path)
        guard let wanted = BrowserPolicy.merged(existing: existing.contents, managedKeys: target.managedKeys, managed: managed) else {
            // Nothing should remain in the file, so a leftover file (or a symlink or damaged file in its place) is deleted. An absent file is already right.
            guard existing.exists else { return .unchanged }
            if unlink(path) == 0 || errno == ENOENT { return .changed }
            logFailure("browser policy file could not be deleted (\(target.displayName)): \(path): \(String(cString: strerror(errno)))")
            return .failed
        }
        // Compared as property list dictionaries, so the order of keys and the file format (XML or binary) do not matter, but the kind of each value does.
        if existing.attributesCorrect, let current = existing.contents, BrowserPolicy.sameSettings(current, wanted, managedKeys: target.managedKeys) { return .unchanged }

        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
        } catch {
            logFailure("browser policy could not be encoded (\(target.displayName)): \(error.localizedDescription)")
            return .failed
        }
        if let failure = ensureFolder(folder) ?? writeAtomically(Array(data), to: path, folder: folder) {
            logFailure("browser policy file could not be updated (\(target.displayName)): \(path): \(failure)")
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

        // Mode must let the browser read the file; in production the owner must also be root:wheel, so a file that a program running as the user could replace is rewritten.
        var attributesCorrect = (info.st_mode & 0o7777) == BrowserPolicyEnforcer.policyFileMode
        if !paths.isSandbox, info.st_uid != 0 || info.st_gid != 0 { attributesCorrect = false }

        guard info.st_size <= BrowserPolicyEnforcer.maxPolicyFileBytes,
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
            let path = "\(folder)/.browser.siteblock.\(suffix)"
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

    /// Writes the bytes to a randomly named temp file in the folder and renames it over the target, so the browser always sees either the old or the new file, never a half-written one. The rename replaces a symlink at the target instead of following it. Returns nil on success, or the reason it failed.
    private func writeAtomically(_ bytes: [UInt8], to path: String, folder: String) -> String? {
        let temp = createTempFile(in: folder)
        if temp.fd < 0 { return "cannot create a temp file in \(folder): \(temp.failure)" }
        var failure: String?
        // The mode is set on the open file, so it is 0644 whatever the process umask is.
        if fchmod(temp.fd, BrowserPolicyEnforcer.policyFileMode) != 0 { failure = "cannot set permissions: \(String(cString: strerror(errno)))" }
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
        if let last = lastFailures[message], now - last < BrowserPolicyEnforcer.repeatedFailureLogInterval { return }
        lastFailures[message] = now
        log.log(message)
    }
}

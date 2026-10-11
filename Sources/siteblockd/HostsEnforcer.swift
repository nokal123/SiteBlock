import Foundation
import SiteBlockCore

/// Makes the real hosts file match the block list, and reports whether it does. All the text editing is done by `HostsFileEditor`; this class only reads the file, clears the flags that could freeze it, writes it safely, and clears the name cache.
final class HostsEnforcer {
    // A failure message that repeats is logged at most this often, so a persistent problem (such as a read-only disk) does not write a line every tick.
    private static let repeatedFailureLogInterval = Duration.seconds(60)

    private let paths: Paths
    private let log: Logger
    private var lastFailure: (message: String, at: ContinuousClock.Instant)?

    /// Creates an enforcer for the hosts file named in the paths. In sandbox mode it never touches the system name cache or file ownership.
    init(paths: Paths, log: Logger) {
        self.paths = paths
        self.log = log
    }

    /// Reads the hosts file, computes what it should contain for the blocked host names, and rewrites it when it differs. Returns true when the file is correct after the pass. `causedByCommand` should be true when the caller just changed the block list on purpose (a command, or a countdown that finished), so the rewrite is expected and is not logged.
    func enforce(blockedHosts: [String], causedByCommand: Bool = false) -> Bool {
        let current: String
        switch readHostsFile() {
        case .failed(let reason):
            logFailure("hosts file could not be read: \(paths.hosts): \(reason)")
            return false
        case .contents(let data):
            // Decode leniently: a stray non-UTF-8 byte in a comment must not stop blocking forever. Such bytes become U+FFFD when the file is rewritten.
            current = String(decoding: data, as: UTF8.self)
        case .missingOrNotPlain:
            // A missing hosts file, or something that is not a plain file (a symlink, a named pipe), is treated as empty, so the write below replaces it with a real file.
            current = ""
        }

        let wanted = HostsFileEditor.render(original: current, blockedHosts: blockedHosts)
        if wanted == current {
            lastFailure = nil
            return true
        }

        // In production, `chflags uchg /etc/hosts` (or on /etc) must not be able to freeze the file, so the flags that make a file or folder unchangeable are cleared before anything is written.
        if !paths.isSandbox { clearProtectionFlags() }
        guard writeAtomically(wanted) else { return false }
        lastFailure = nil
        flushNameCache()
        // A rewrite nobody asked for means someone (or another program) changed the file, so it goes in the log.
        if !causedByCommand { log.log(describeChange(from: current, to: wanted)) }
        return true
    }

    /// Picks the log message for a rewrite that no command caused. It is "blocks removed from hosts file" only when the pass did nothing but take managed lines away (the block list is now empty or shorter, for example after the daemon started with lost state). Any other change (block lines put back, a bypass line stripped, or a section moved or edited) is "hosts file repaired".
    private func describeChange(from current: String, to wanted: String) -> String {
        let currentLines = Set(current.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) })
        let wantedLines = wanted.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        // A line the new text has that the old text did not means block lines were put back, or a user line was rewritten after a blocked name was cut out of it.
        if wantedLines.contains(where: { !currentLines.contains($0) }) { return "hosts file repaired" }
        // With the managed sections taken out of both texts, any difference is in the user's own lines, so a bypass line was removed.
        if HostsFileEditor.render(original: current, blockedHosts: []) != HostsFileEditor.render(original: wanted, blockedHosts: []) { return "hosts file repaired" }
        // Nothing was added and the user's lines are unchanged, so lines that are no longer wanted went away. If none did, the pass only changed the layout.
        let removedSomething = !currentLines.isSubset(of: Set(wantedLines))
        return removedSomething ? "blocks removed from hosts file" : "hosts file repaired"
    }

    /// The flags that make a file or folder unchangeable: user and system immutable, and user and system append-only.
    private static let protectionFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)

    /// Clears the protection flags on the hosts file and on the folder that holds it. The folder is cleared first, because an immutable folder would not let the temp file be created. Root may clear these flags at macOS's normal security level. Production only.
    private func clearProtectionFlags() {
        let folder = URL(fileURLWithPath: paths.hosts).deletingLastPathComponent().path
        // On macOS /etc is a symlink to /private/etc. lchflags on the symlink would change the link and not the folder, so the real folder is looked up first.
        var resolvedFolder = folder
        if let resolved = realpath(folder, nil) {
            resolvedFolder = String(cString: resolved)
            free(resolved)
        }
        clearProtectionFlags(at: resolvedFolder)
        clearProtectionFlags(at: paths.hosts)
    }

    /// Reads the flags of one path with lstat (which does not follow a symlink at the end of the path) and, when any protection flag is set, writes the flags back with those bits removed using lchflags. A failure is logged and the write is still attempted.
    private func clearProtectionFlags(at path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_flags & HostsEnforcer.protectionFlags != 0 else { return }
        if lchflags(path, info.st_flags & ~HostsEnforcer.protectionFlags) != 0 {
            logFailure("cannot clear the immutable flags on \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Creates a new empty temp file beside the hosts file with a random name. It uses mkstemp first, and if that fails it makes its own random name and creates the file with O_CREAT, O_EXCL (fail if anything already exists there) and O_NOFOLLOW (never follow a symlink). Returns the open descriptor and the path, or a descriptor of -1 and the reason the file could not be created.
    private func createTempFile(in folder: String) -> (fd: Int32, path: String, failure: String) {
        var template = Array("\(folder)/.hosts.siteblock.XXXXXX".utf8CString)
        let first = mkstemp(&template)
        if first >= 0 {
            _ = fcntl(first, F_SETFD, FD_CLOEXEC)
            return (first, String(cString: template), "")
        }
        var failure = String(cString: strerror(errno))
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        // A few tries, because a random name can in rare cases already exist; any other error is final.
        for _ in 0..<8 {
            let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
            let path = "\(folder)/.hosts.siteblock.\(suffix)"
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

    /// What reading the hosts file found: its bytes, nothing usable (missing, a symlink, a named pipe or another non-file), or a real read failure.
    private enum HostsRead {
        case contents(Data)
        case missingOrNotPlain
        case failed(String)
    }

    /// Reads the hosts file without ever waiting on it. It opens with O_NONBLOCK, so a named pipe planted at the path cannot freeze the daemon, and O_NOFOLLOW, so a symlink is not followed; anything that is not a plain file counts as unusable and gets replaced. Files over 16 MB are refused as a failure rather than read into memory.
    private func readHostsFile() -> HostsRead {
        let fd = open(paths.hosts, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            // ENOENT is a missing file; ELOOP is a symlink refused by O_NOFOLLOW. Both are replaced by the write that follows.
            if errno == ENOENT || errno == ELOOP { return .missingOrNotPlain }
            return .failed(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed(String(cString: strerror(errno))) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .missingOrNotPlain }
        guard info.st_size <= 16 * 1024 * 1024 else { return .failed("the file is larger than 16 MB") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .failed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return .contents(data)
    }

    /// Writes the text into the hosts file itself, for when the rename could not replace it. The file is opened with O_WRONLY and O_TRUNC (empty it first), O_NOFOLLOW (refuse a symlink) and O_NONBLOCK (a named pipe planted there fails at once instead of freezing the daemon), and anything that is not a plain file is refused. It is not atomic, but it works in places where a rename does not. Returns nil on success, or the reason it failed.
    private func writeInPlace(_ bytes: [UInt8]) -> String? {
        let fd = open(paths.hosts, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { return "cannot open \(paths.hosts): \(String(cString: strerror(errno)))" }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return "\(paths.hosts) is not a plain file" }
        if let failure = writeAll(bytes, to: fd) { return failure }
        if fsync(fd) != 0 { return "cannot flush to disk: \(String(cString: strerror(errno)))" }
        return nil
    }

    /// Writes the text to a randomly named temp file beside the hosts file and renames it over the hosts file, so readers always see either the old or the new file, never a half-written one. If the temp file cannot be created or the rename fails, it writes into the hosts file itself instead. Returns false (after logging why) only when that also fails.
    private func writeAtomically(_ text: String) -> Bool {
        let folder = URL(fileURLWithPath: paths.hosts).deletingLastPathComponent().path
        let bytes = Array(text.utf8)
        // A random name means a folder or file planted at a fixed temp path cannot block the write.
        let temp = createTempFile(in: folder)
        if temp.fd < 0 {
            // Getting the block written matters more than writing it atomically, so a folder that refuses new files still gets the hosts file itself rewritten.
            guard let inPlaceFailure = writeInPlace(bytes) else { return true }
            logFailure("hosts file could not be updated: cannot create a temp file in \(folder): \(temp.failure); writing in place also failed: \(inPlaceFailure)")
            return false
        }
        var failure: String?
        // The mode is set on the open file, so it is 0644 whatever the process umask is.
        if fchmod(temp.fd, 0o644) != 0 { failure = "cannot set permissions: \(String(cString: strerror(errno)))" }
        // Only the installed daemon changes ownership: a sandbox run is not root and must not try.
        if failure == nil, !paths.isSandbox, fchown(temp.fd, 0, 0) != 0 { failure = "cannot set owner root:wheel: \(String(cString: strerror(errno)))" }
        if failure == nil { failure = writeAll(bytes, to: temp.fd) }
        if failure == nil, fsync(temp.fd) != 0 { failure = "cannot flush to disk: \(String(cString: strerror(errno)))" }
        close(temp.fd)
        if failure == nil, rename(temp.path, paths.hosts) != 0 {
            // The rename can fail where writing the file itself still works (for example when the folder does not allow replacing files). Try that before giving up.
            let renameFailure = "cannot replace \(paths.hosts): \(String(cString: strerror(errno)))"
            if let inPlaceFailure = writeInPlace(bytes) {
                failure = "\(renameFailure); writing in place also failed: \(inPlaceFailure)"
            }
        }
        // After a successful rename the temp file is already gone, so this removes only a temp file left behind by a failure or by the in-place fallback.
        _ = unlink(temp.path)
        if let failure {
            logFailure("hosts file could not be updated: \(failure)")
            return false
        }
        return true
    }

    /// Logs a failure message, unless the same message was already logged within the last minute.
    private func logFailure(_ message: String) {
        let now = ContinuousClock.now
        if let last = lastFailure, last.message == message, now - last.at < HostsEnforcer.repeatedFailureLogInterval { return }
        lastFailure = (message, now)
        log.log(message)
    }

    /// Clears the macOS name cache so a recently visited site cannot keep working from its cached address. Does nothing in sandbox mode.
    private func flushNameCache() {
        guard !paths.isSandbox else { return }
        let flush = runProcess("/usr/bin/dscacheutil", ["-flushcache"], timeout: 5)
        let signal = runProcess("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 5)
        if flush != 0 || signal != 0 { log.log("name cache flush reported errors (dscacheutil \(flush), mDNSResponder \(signal))") }
    }
}

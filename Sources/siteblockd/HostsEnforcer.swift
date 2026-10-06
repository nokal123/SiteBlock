import Foundation
import SiteBlockCore

/// Makes the real hosts file match the block list, and reports whether it does. All the text editing is done by `HostsFileEditor`; this class only reads the file, writes it safely, and clears the name cache.
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

    /// Reads the hosts file, computes what it should contain for the blocked host names, and rewrites it when it differs. Returns true when the file is correct after the pass. `causedByCommand` should be true when the caller just changed the block list on purpose, so the rewrite is expected and is not logged as tampering.
    func enforce(blockedHosts: [String], causedByCommand: Bool = false) -> Bool {
        let current: String
        if FileManager.default.fileExists(atPath: paths.hosts) {
            guard let data = FileManager.default.contents(atPath: paths.hosts) else {
                logFailure("hosts file could not be read: \(paths.hosts)")
                return false
            }
            // Decode leniently: a stray non-UTF-8 byte in a comment must not stop blocking forever. Such bytes become U+FFFD when the file is rewritten.
            current = String(decoding: data, as: UTF8.self)
        } else {
            // A missing hosts file is treated as an empty one.
            current = ""
        }

        let wanted = HostsFileEditor.render(original: current, blockedHosts: blockedHosts)
        if wanted == current {
            lastFailure = nil
            return true
        }

        guard writeAtomically(wanted) else { return false }
        lastFailure = nil
        flushNameCache()
        // A rewrite nobody asked for means someone (or another program) changed the file, so it goes in the log.
        if !causedByCommand { log.log("hosts file repaired") }
        return true
    }

    /// Writes the text to a temp file beside the hosts file and renames it over the hosts file, so readers always see either the old or the new file, never a half-written one. Returns false (after logging why) on any failure.
    private func writeAtomically(_ text: String) -> Bool {
        let tempPath = paths.hosts + ".siteblock.tmp"
        // Remove a leftover temp file first, so O_EXCL below guarantees a brand-new file and a planted symlink can never be followed.
        _ = unlink(tempPath)
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if fd < 0 {
            logFailure("hosts file could not be updated: cannot create \(tempPath): \(String(cString: strerror(errno)))")
            return false
        }
        var failure: String?
        let bytes = Array(text.utf8)
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
        // The mode is set on the open file, so it is 0644 whatever the process umask is.
        if failure == nil, fchmod(fd, 0o644) != 0 { failure = "cannot set permissions: \(String(cString: strerror(errno)))" }
        // Only the installed daemon changes ownership: a sandbox run is not root and must not try.
        if failure == nil, !paths.isSandbox, fchown(fd, 0, 0) != 0 { failure = "cannot set owner root:wheel: \(String(cString: strerror(errno)))" }
        if failure == nil, fsync(fd) != 0 { failure = "cannot flush to disk: \(String(cString: strerror(errno)))" }
        close(fd)
        if failure == nil, rename(tempPath, paths.hosts) != 0 { failure = "cannot replace \(paths.hosts): \(String(cString: strerror(errno)))" }
        if let failure {
            _ = unlink(tempPath)
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

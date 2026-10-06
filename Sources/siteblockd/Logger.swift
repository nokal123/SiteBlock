import Foundation

/// A tiny logger that writes one line per message to standard error, each starting with an ISO 8601 timestamp. launchd sends standard error to the log file named in the job's plist, so this is how the daemon and watchdog write their logs.
struct Logger {
    /// Writes "<timestamp> <message>" and a newline to standard error. The line is written with one `write` call, so lines from different threads never mix. Callers must never pass a password.
    func log(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        let bytes = Array(line.utf8)
        // A failed log write is ignored on purpose: logging must never stop the daemon from enforcing blocks.
        bytes.withUnsafeBytes { buffer in _ = write(STDERR_FILENO, buffer.baseAddress, buffer.count) }
    }
}

import Foundation

/// The result of a finished child program: how it ended and, when requested, what it printed.
struct ProcessResult {
    /// The exit code, 127 when the program could not be started, or 124 when it was stopped for running too long.
    let status: Int32
    /// Everything the program wrote to standard output and standard error (empty when output was not captured).
    let output: String
}

/// Holds the bytes a background reader collected. The waiting thread reads `data` only after the group wait reports that the reader has finished, which is what keeps the two threads from touching it at the same time.
private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

/// The exit code `runProcess` reports when the program could not be started at all (the same convention a shell uses).
let processLaunchFailedStatus: Int32 = 127
/// The exit code `runProcess` reports when the program was stopped because it ran longer than the timeout (the same convention as `timeout(1)`).
let processTimedOutStatus: Int32 = 124

/// Runs a program and waits for it, for at most `timeout` seconds, and returns its exit code. The program's output is thrown away. A program that overruns the timeout is stopped, so a hung `launchctl` can never freeze the daemon.
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
    runProcessCapturing(path, args, timeout: timeout, capture: false).status
}

/// Like `runProcess`, but also returns what the program printed, so a failed `launchctl bootstrap` can be explained in the log.
func runProcessCapturingOutput(_ path: String, _ args: [String], timeout: TimeInterval) -> ProcessResult {
    runProcessCapturing(path, args, timeout: timeout, capture: true)
}

/// The shared implementation: starts the program, waits up to the timeout, and stops it if it overruns.
private func runProcessCapturing(_ path: String, _ args: [String], timeout: TimeInterval, capture: Bool) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    if capture {
        process.standardOutput = pipe
        process.standardError = pipe
    } else {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch {
        try? pipe.fileHandleForWriting.close()
        return ProcessResult(status: processLaunchFailedStatus, output: "")
    }

    // Read the output on its own thread while the program runs. If we only read after it exits, a program that prints more than the pipe holds (about 64 KB) would block forever on its own write.
    let collected = OutputBox()
    let readerDone = DispatchGroup()
    if capture {
        // The parent's copy of the write end must be closed, or the reader never sees end-of-file.
        try? pipe.fileHandleForWriting.close()
        readerDone.enter()
        DispatchQueue.global().async {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readerDone.leave()
        }
    }

    let status: Int32
    if finished.wait(timeout: .now() + max(0.001, timeout)) == .timedOut {
        // Ask politely first, then force it if it ignores the request for a second.
        process.terminate()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
        }
        status = processTimedOutStatus
    } else {
        status = process.terminationStatus
    }
    // The collected output is read only after the reader thread has finished. If the program started a child of its own that still holds the pipe open, the reader is still blocked and may still write to the box, so the box must not be touched and the output is reported as empty. (The reader thread then ends by itself when that child exits.)
    var output = ""
    if capture, readerDone.wait(timeout: .now() + 1) == .success {
        output = String(decoding: collected.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ProcessResult(status: status, output: output)
}

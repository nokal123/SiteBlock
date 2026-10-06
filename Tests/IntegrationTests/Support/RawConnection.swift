import Foundation
import SiteBlockCore

// What came back from a raw connection.
struct RawReply {
    // Every byte read before the connection ended or the read gave up.
    let data: Data
    // True when the daemon closed its end (end of stream or a connection reset); false when the wait ran out first.
    let closedByPeer: Bool
    // How many seconds the read took.
    let seconds: Double

    // The reply as text.
    var text: String { String(decoding: data, as: UTF8.self) }

    // The reply parsed as one JSON object (the part before the first newline), or nil when it is not one.
    var json: [String: Any]? {
        let line = data.prefix(while: { $0 != 10 })
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    // How many newline characters the reply holds (a well-formed reply holds exactly one, at the end).
    var newlineCount: Int { data.filter { $0 == 10 }.count }

    // The error code of a failed reply, or nil.
    var errorCode: String? { json?["errorCode"] as? String }

    // The ok flag of the reply, or nil when the reply is not a JSON object with one.
    var ok: Bool? { json?["ok"] as? Bool }
}

// A bare Unix-socket connection to the daemon, used to send exactly the bytes a test wants (oversized, malformed, half-finished, or several requests in one connection), which DaemonClient would never send.
final class RawConnection {
    private var fd: Int32

    // Connects to the socket path; throws when nothing is listening.
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure("socket() failed: \(String(cString: strerror(errno)))") }
        // Not inherited by child processes: a daemon started by another test while this connection is open must not keep it alive after the test closes it.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A write to a connection the daemon already closed must return an error, not kill the test process.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A write that would block for more than 5 seconds gives up instead of hanging the test.
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw TestFailure("socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            let reason = String(cString: strerror(errno))
            close(fd)
            fd = -1
            throw TestFailure("connect to \(path) failed: \(reason)")
        }
    }

    deinit { closeNow() }

    // Writes all the bytes. Returns false when the daemon had already closed the connection (so the rest could not be delivered).
    @discardableResult
    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    // Writes text as UTF-8.
    @discardableResult
    func write(_ text: String) -> Bool { write(Data(text.utf8)) }

    // Tells the daemon that no more bytes will come, while keeping the connection open to read the reply.
    func finishWriting() { _ = shutdown(fd, SHUT_WR) }

    // Reads until the daemon closes the connection (or, with `stopAtNewline`, until one full line has arrived) or `timeout` seconds pass.
    func read(timeout: Double, stopAtNewline: Bool = false) -> RawReply {
        let watch = Stopwatch()
        var collected = Data()
        var closed = false
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !closed {
            let remaining = timeout - watch.elapsed
            if remaining <= 0 { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1.0) * 1000) + 1)
            if ready < 0 {
                if errno == EINTR { continue }
                closed = true
                break
            }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                collected.append(contentsOf: chunk[0..<count])
                if stopAtNewline && collected.contains(10) { break }
            } else if count == 0 {
                closed = true
            } else if errno != EINTR {
                // A reset (or any other read error) means the daemon is gone; what was collected before it is still valid.
                closed = true
            }
        }
        return RawReply(data: collected, closedByPeer: closed, seconds: watch.elapsed)
    }

    // Closes the connection from the test's side.
    func closeNow() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

// Opens a connection, sends the bytes, optionally signals the end of the request, and reads the reply until the daemon closes the connection or a full line arrives.
func rawExchange(_ bytes: Data, socketPath: String, finishWriting: Bool = false, timeout: Double = 8) throws -> RawReply {
    let connection = try RawConnection(path: socketPath)
    connection.write(bytes)
    if finishWriting { connection.finishWriting() }
    return connection.read(timeout: timeout, stopAtNewline: !finishWriting)
}

// Text version of rawExchange.
func rawExchange(_ text: String, socketPath: String, finishWriting: Bool = false, timeout: Double = 8) throws -> RawReply {
    try rawExchange(Data(text.utf8), socketPath: socketPath, finishWriting: finishWriting, timeout: timeout)
}

// A well-formed request line for the given JSON fields, written the way a client would (one line, newline at the end). Strings are JSON-escaped by Foundation, so a newline in a value becomes the two characters \n.
func requestLine(_ fields: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}

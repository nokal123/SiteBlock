import Foundation

/// The reasons a request to the daemon can fail before a response is read.
public enum ClientError: Error, LocalizedError, Equatable {
    /// The socket file is missing, the connection was refused, or the socket path is not usable (for example 104 bytes or longer).
    case notRunning
    /// No reply arrived in time.
    case timeout
    /// A reply arrived but was empty or not valid JSON.
    case badResponse
    /// Some other socket failure, with the system's description.
    case ioFailure(String)

    /// The sentence shown to the user for this problem.
    public var errorDescription: String? {
        switch self {
        case .notRunning: return "The SiteBlock service isn't running."
        case .timeout: return "The SiteBlock service did not answer in time."
        case .badResponse: return "The SiteBlock service sent a reply that could not be understood."
        case .ioFailure(let detail): return "Could not talk to the SiteBlock service: \(detail)"
        }
    }
}

/// The client side of the wire protocol, used by both the CLI and the app. Each call opens a fresh connection, sends one request line, and reads one response line.
public struct DaemonClient: Sendable {
    // A Unix socket path (with its ending NUL byte) must fit in sockaddr_un.sun_path, which is 104 bytes on macOS.
    private static let maxPathBytes = 103
    // A reply bigger than this is treated as garbage instead of being buffered without limit.
    private static let maxResponseBytes = 4 * 1024 * 1024

    /// The socket this client connects to.
    public let socketPath: String
    /// How long to wait for the daemon to answer.
    public let timeout: TimeInterval

    /// The socket path to use: the SITEBLOCK_SOCKET environment variable when it is set and not empty (tests and sandbox runs set it), otherwise /var/run/siteblock.sock.
    public static var defaultSocketPath: String {
        if let value = ProcessInfo.processInfo.environment["SITEBLOCK_SOCKET"], !value.isEmpty { return value }
        return Paths.production.socket
    }

    /// Creates a client. The default path honors SITEBLOCK_SOCKET, so a sandbox daemon is reached without extra code in the callers.
    public init(socketPath: String = DaemonClient.defaultSocketPath, timeout: TimeInterval = 10) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// Sends one request and returns the daemon's response, or throws a ClientError.
    public func send(_ request: Request) throws -> Response {
        var line = try JSONCoding.encoder.encode(request)
        line.append(10)
        // Both the read and write loops stop at this moment, so a daemon that trickles bytes cannot keep the client waiting forever.
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.001, timeout) * 1_000_000_000)

        let fd = try connectSocket()
        defer { close(fd) }

        let writeBroke = try writeRequest(line, to: fd, deadline: deadline)
        let reply = try readLine(from: fd, deadline: deadline, writeBroke: writeBroke)
        guard !reply.isEmpty else { throw ClientError.badResponse }
        do {
            return try JSONCoding.decoder.decode(Response.self, from: Data(reply))
        } catch {
            throw ClientError.badResponse
        }
    }

    /// Opens a stream socket with the timeouts set and connects it to the daemon's socket path.
    private func connectSocket() throws -> Int32 {
        // A path that cannot fit in sockaddr_un cannot name a daemon socket, so it is reported as not running.
        guard !socketPath.isEmpty, socketPath.utf8.count <= DaemonClient.maxPathBytes, !socketPath.utf8.contains(0) else { throw ClientError.notRunning }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw ClientError.ioFailure(String(cString: strerror(errno))) }

        // SO_NOSIGPIPE makes a write to a closed connection return an error instead of killing the process.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let clamped = max(0.001, timeout)
        let whole = clamped.rounded(.down)
        var interval = timeval(tv_sec: Int(whole), tv_usec: __darwin_suseconds_t((clamped - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            let code = errno
            close(fd)
            switch code {
            // A missing socket file, a refused connection, or a path through something that is not a folder all mean no daemon is listening.
            case ENOENT, ECONNREFUSED, ENOTDIR: throw ClientError.notRunning
            case EAGAIN, ETIMEDOUT: throw ClientError.timeout
            default: throw ClientError.ioFailure(String(cString: strerror(code)))
            }
        }
        return fd
    }

    /// Writes the whole request line. Returns true when the daemon closed the connection early (for example after rejecting an oversized request), so the caller still tries to read the reply it sent first.
    private func writeRequest(_ bytes: Data, to fd: Int32, deadline: UInt64) throws -> Bool {
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                if DispatchTime.now().uptimeNanoseconds > deadline { throw ClientError.timeout }
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { throw ClientError.timeout }
                    if code == EPIPE || code == ECONNRESET { return true }
                    throw ClientError.ioFailure(String(cString: strerror(code)))
                }
                offset += written
            }
            return false
        }
    }

    /// Reads until a newline or the end of the stream and returns the bytes before the newline.
    private func readLine(from fd: Int32, deadline: UInt64, writeBroke: Bool) throws -> [UInt8] {
        var collected: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if DispatchTime.now().uptimeNanoseconds > deadline { throw ClientError.timeout }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw ClientError.timeout }
                // A reset after a failed write means the daemon hung up without a reply.
                if code == ECONNRESET && writeBroke { return [] }
                if code == ECONNRESET { return collected }
                throw ClientError.ioFailure(String(cString: strerror(code)))
            }
            if count == 0 { break }
            collected.append(contentsOf: chunk[0..<count])
            if collected.contains(10) { break }
            if collected.count > DaemonClient.maxResponseBytes { throw ClientError.badResponse }
        }
        return Array(collected.prefix(while: { $0 != 10 }))
    }
}

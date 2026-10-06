import Foundation
import SiteBlockCore

/// The reasons the socket server cannot start.
enum SocketServerError: Error, LocalizedError {
    /// The socket path is empty or too long to fit in a Unix socket address.
    case invalidPath(String)
    /// Another daemon is already answering on this socket.
    case alreadyRunning(String)
    /// A system call failed; carries what was being done and the system's description.
    case system(String)

    /// The sentence describing the problem.
    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "The socket path is not usable (it must be 1 to 103 bytes): \(path)"
        case .alreadyRunning(let path): return "Another siteblockd is already answering on \(path)."
        case .system(let detail): return detail
        }
    }
}

/// Accepts connections on a Unix domain socket and turns each one into exactly one `Request` and one `Response`. It does no policy work: it passes each decoded request, together with the kernel-reported user ID of the caller, to a handler closure.
final class SocketServer {
    /// The largest request line accepted; anything bigger is answered with badRequest.
    static let maxRequestBytes = 64 * 1024
    /// How long the server waits for a request line, and for a reply to be accepted, before giving up on a client.
    static let clientTimeoutSeconds = 5
    // A Unix socket path (with its ending NUL byte) must fit in sockaddr_un.sun_path, which is 104 bytes on macOS.
    private static let maxPathBytes = 103
    // The most connections served at once. Each one holds a thread while it waits for its request, so a cap keeps a flood of idle connections from using up every thread the system will give the daemon.
    private static let maxConnections = 32

    private let path: String
    private let handler: (Request, uid_t) -> Response
    // One lock guards the three fields below, which the accept thread, the client threads and stop() all touch.
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private var activeConnections = 0
    // Signalled when the accept thread has finished and closed the listening socket.
    private let acceptThreadDone = DispatchSemaphore(value: 0)
    // Each client is handled on this concurrent queue, so one slow client cannot hold up the others.
    private let clientQueue = DispatchQueue(label: "siteblockd.socket.clients", attributes: .concurrent)

    /// Creates a server for the socket path. The handler is called once per valid request with the caller's user ID.
    init(path: String, handler: @escaping (Request, uid_t) -> Response) {
        self.path = path
        self.handler = handler
    }

    /// Builds a socket address for the path, or nil when the path cannot fit.
    private static func makeAddress(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes, !bytes.contains(0) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Connects to the address; returns true when something is listening there.
    private static func isSomeoneListening(_ address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var copy = address
        let result = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    /// Creates the socket, makes it reachable by every user, and starts accepting connections on a dedicated thread. Throws when the path is unusable, another daemon is already listening, or a system call fails.
    func start() throws {
        guard var address = SocketServer.makeAddress(path) else { throw SocketServerError.invalidPath(path) }

        // A socket file left behind by a crashed daemon is stale: nothing listens on it. A live one means a second daemon would steal the socket from the first, so refuse instead of removing it.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            if SocketServer.isSomeoneListening(address) { throw SocketServerError.alreadyRunning(path) }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw SocketServerError.system("Could not create the socket: \(String(cString: strerror(errno)))") }
        // Without close-on-exec, programs the daemon starts (launchctl, the uninstall shell) would inherit the listening socket and keep it open.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if bindResult != 0 {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw SocketServerError.system("Could not bind \(path): \(detail)")
        }
        // Mode 0666 on purpose: the logged-in user's app must be able to connect to a root daemon. Every command that loosens a block still needs the password.
        if chmod(path, 0o666) != 0 {
            let detail = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw SocketServerError.system("Could not set permissions on \(path): \(detail)")
        }
        if listen(fd, 16) != 0 {
            let detail = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw SocketServerError.system("Could not listen on \(path): \(detail)")
        }

        lock.lock()
        listenFD = fd
        stopped = false
        lock.unlock()
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "siteblockd.accept"
        thread.start()
    }

    /// Stops accepting connections, closes the listening socket and removes the socket file. Connections already being served finish on their own.
    func stop() {
        lock.lock()
        let wasRunning = listenFD >= 0 && !stopped
        stopped = true
        lock.unlock()
        guard wasRunning else { return }
        // The accept thread notices the flag within half a second and closes the socket itself; closing it here could race with a pending accept.
        _ = acceptThreadDone.wait(timeout: .now() + 2)
        unlink(path)
    }

    /// True once stop() has been called.
    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Waits for connections and hands each to the client queue, until stop() is called. It waits with poll and a half-second timeout so it can notice the stop flag, because closing a socket does not reliably wake a thread blocked in accept.
    private func acceptLoop(_ fd: Int32) {
        defer {
            close(fd)
            acceptThreadDone.signal()
        }
        while !isStopped {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 500)
            // Zero means the half-second passed with no connection; negative means a signal interrupted the wait. Either way, go round again.
            if ready <= 0 || isStopped { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                // Too many open files or similar: wait a moment instead of spinning.
                if errno != EINTR && errno != ECONNABORTED { usleep(100_000) }
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)

            lock.lock()
            let accepted = activeConnections < SocketServer.maxConnections
            if accepted { activeConnections += 1 }
            lock.unlock()
            if !accepted {
                // Over the cap: hang up at once. The client reports that no usable reply arrived and can try again.
                close(client)
                continue
            }
            clientQueue.async { [self] in
                serve(client)
                lock.lock()
                activeConnections -= 1
                lock.unlock()
            }
        }
    }

    /// Sets a timeout, in seconds, on reads (or writes) of a socket; a read or write that waits longer fails with EAGAIN.
    private func setTimeout(_ fd: Int32, option: Int32, seconds: Double) {
        let clamped = max(0.001, seconds)
        let whole = clamped.rounded(.down)
        var interval = timeval(tv_sec: Int(whole), tv_usec: __darwin_suseconds_t((clamped - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &interval, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Asks the kernel who is on the other end of the connection. Falls back to UInt32.max, a user ID that is never root, so a failure here can never grant a root-only command.
    private func peerUserID(_ fd: Int32) -> uid_t {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length)
        guard result == 0, credentials.cr_version == UInt32(XUCRED_VERSION) else { return UInt32.max }
        return credentials.cr_uid
    }

    /// What reading a request line produced.
    private enum ReadOutcome {
        /// A complete request line (without its newline).
        case line([UInt8])
        /// More than the size limit arrived before any newline.
        case tooLarge
        /// The client sent nothing within the time limit.
        case timedOut
        /// The client closed the connection without sending anything.
        case empty
    }

    /// Reads bytes until a newline, the end of the stream, or the size limit, within five seconds in total. The deadline covers the whole request, so a client that sends one byte at a time cannot hold the connection open.
    private func readRequestLine(_ fd: Int32) -> ReadOutcome {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(SocketServer.clientTimeoutSeconds) * 1_000_000_000
        var collected: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return .timedOut }
            setTimeout(fd, option: SO_RCVTIMEO, seconds: Double(deadline - now) / 1_000_000_000)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                // EAGAIN is the receive timeout. Any other error is treated like a hang-up.
                if errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
                return collected.isEmpty ? .empty : .line(collected)
            }
            // End of stream: the client is done sending. Whatever arrived is the request, even without a newline.
            if count == 0 { return collected.isEmpty ? .empty : .line(collected) }
            collected.append(contentsOf: chunk[0..<count])
            if let newline = collected.firstIndex(of: 10) {
                // Only the first line counts; the size limit applies to the line itself.
                return newline > SocketServer.maxRequestBytes ? .tooLarge : .line(Array(collected[..<newline]))
            }
            if collected.count > SocketServer.maxRequestBytes { return .tooLarge }
        }
    }

    /// Turns a JSON decoding failure into one readable sentence.
    private func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "The request is not valid JSON." }
        switch decoding {
        case .dataCorrupted(let context): return "The request could not be understood: \(context.debugDescription)"
        case .keyNotFound(let key, _): return "The request could not be understood: it is missing '\(key.stringValue)'."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "The request could not be understood: \(context.debugDescription)"
        @unknown default: return "The request is not valid JSON."
        }
    }

    /// Writes every byte to the socket, retrying after interrupts and partial writes; gives up silently if the client has gone, since there is nobody to tell.
    private func writeAll(_ bytes: [UInt8], to fd: Int32) {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Reads and throws away what a client is still sending, for a bounded time and size. It runs after an oversized request has been answered, so the client's own write finishes instead of failing, and the client can read the reply.
    private func drain(_ fd: Int32) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(SocketServer.clientTimeoutSeconds) * 1_000_000_000
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var total = 0
        // The cap stops a client that never stops sending from holding the connection open.
        while total < 8 * 1024 * 1024 {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return }
            setTimeout(fd, option: SO_RCVTIMEO, seconds: Double(deadline - now) / 1_000_000_000)
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            total += count
        }
    }

    /// Serves one connection: reads the request, calls the handler, writes the reply, closes. Every outcome, including garbage input, ends in a reply or a clean close, never a crash.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // SO_NOSIGPIPE makes a write to a vanished client return an error instead of killing the daemon with SIGPIPE.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, option: SO_SNDTIMEO, seconds: Double(SocketServer.clientTimeoutSeconds))

        let response: Response
        var needsDrain = false
        switch readRequestLine(fd) {
        case .empty:
            return
        case .timedOut:
            response = .failure(.badRequest, "No request arrived within \(SocketServer.clientTimeoutSeconds) seconds.")
        case .tooLarge:
            response = .failure(.badRequest, "The request is larger than \(SocketServer.maxRequestBytes / 1024) KB.")
            needsDrain = true
        case .line(let bytes):
            do {
                let request = try JSONCoding.decoder.decode(Request.self, from: Data(bytes))
                // The user ID comes from the kernel, not from the request, so a client cannot claim to be root.
                response = handler(request, peerUserID(fd))
            } catch {
                response = .failure(.badRequest, describe(error))
            }
        }

        // If encoding somehow fails, send a fixed failure line instead of nothing.
        var reply = (try? JSONCoding.encoder.encode(response)) ?? Data(#"{"errorCode":"internal","error":"The reply could not be encoded.","ok":false}"#.utf8)
        reply.append(10)
        writeAll(Array(reply), to: fd)
        if needsDrain {
            // Tell the client no more data is coming from this side, then let it finish its oversized write.
            shutdown(fd, SHUT_WR)
            drain(fd)
        }
    }
}

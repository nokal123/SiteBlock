import Foundation

/// The result of one check of whether the family DNS servers answer.
public struct FamilyDNSCheck: Equatable, Sendable {
    /// True when at least one family server answered.
    public let reachable: Bool
    /// A short sentence about what happened, for the diagnostic output.
    public let detail: String

    /// Creates a result.
    public init(reachable: Bool, detail: String) {
        self.reachable = reachable
        self.detail = detail
    }
}

/// A way to find out whether the family DNS servers answer on the current network. A check may take up to 2 seconds, so it must never be called on the engine queue; `FamilyDNSMonitor` calls it on its own background queue.
public protocol FamilyDNSProbe {
    /// Asks the family servers and returns whether any of them answered.
    func check() -> FamilyDNSCheck
}

/// The real check: sends one DNS query for example.com (type A) by UDP to port 53 of both IPv4 servers of the active family DNS provider (see `FamilyDNSProviders`) at the same time, then waits up to 2 seconds in total for whichever answers first. A server counts as answering only when a packet comes back from it with that query's random ID and the QR (this is an answer) bit set. Because both are asked together, a check takes 2 seconds at the very most.
public final class UDPFamilyDNSProbe: FamilyDNSProbe {
    /// One place a query is sent: an IPv4 address and a UDP port.
    public struct Target: Sendable {
        public let host: String
        public let port: UInt16

        /// Creates a target from an IPv4 address and a UDP port.
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// The two IPv4 servers of the active family DNS provider, on the DNS port 53. Empty when the built-in providers file cannot be read, which makes every check report the servers as unreachable.
    public static let familyTargets = (FamilyDNSProviders.builtIn?.activeProvider.ipv4 ?? []).map { Target(host: $0, port: 53) }
    // How long the servers get to answer, counted from when both queries are sent.
    private static let timeoutSeconds = 2.0

    private let targets: [Target]

    /// Creates the check. The installed service always uses the two family servers; another list (loopback addresses and ports) exists only so the check itself can be tried against stand-in servers.
    public init(targets: [Target] = UDPFamilyDNSProbe.familyTargets) {
        self.targets = targets
    }

    /// One query that has been sent and is waiting for its answer.
    private struct Attempt {
        let host: String
        let descriptor: Int32
        let id: UInt16
    }

    /// Sends the query to both servers and returns as soon as one valid answer arrives, or unreachable when none has arrived after 2 seconds (or both servers refused the query).
    public func check() -> FamilyDNSCheck {
        let all = targets.compactMap { send(to: $0) }
        defer { for attempt in all { close(attempt.descriptor) } }
        var waiting = all
        let deadline = ContinuousClock.now + .seconds(Self.timeoutSeconds)
        var buffer = [UInt8](repeating: 0, count: 512)
        while !waiting.isEmpty {
            let milliseconds = Int32(max(0, min(seconds(deadline - ContinuousClock.now) * 1000, 10_000)).rounded(.up))
            if milliseconds <= 0 { break }
            var watched = waiting.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&watched, nfds_t(watched.count), milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }
            var finished: Set<Int32> = []
            for (index, entry) in watched.enumerated() where entry.revents != 0 {
                let attempt = waiting[index]
                let count = recv(attempt.descriptor, &buffer, buffer.count, 0)
                if count < 0 {
                    // Nothing to read after all (EAGAIN) or an interrupt: keep waiting. Any other error (such as the network refusing the port) ends this server's attempt only.
                    if errno != EINTR && errno != EAGAIN { finished.insert(attempt.descriptor) }
                    continue
                }
                if DNSProbePacket.isAnswer(Array(buffer[0..<count]), toQueryWithID: attempt.id) {
                    return FamilyDNSCheck(reachable: true, detail: "\(attempt.host) answered")
                }
            }
            waiting.removeAll { finished.contains($0.descriptor) }
        }
        return FamilyDNSCheck(reachable: false, detail: "neither \(targets.map(\.host).joined(separator: " nor ")) answered within \(Int(Self.timeoutSeconds)) seconds")
    }

    /// Opens a UDP socket, fixes its other end to the target (so the kernel drops datagrams from any other address) and sends one query with a fresh random ID. Returns nil when any step fails.
    private func send(to target: Target) -> Attempt? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        // A read after poll said "readable" must never wait, even if the packet turns out to be unusable.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = target.port.bigEndian
        guard inet_pton(AF_INET, target.host, &address.sin_addr) == 1 else {
            close(descriptor)
            return nil
        }
        // connect() on a UDP socket sends nothing. It only fixes the other end.
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let id = UInt16.random(in: UInt16.min...UInt16.max)
        let query = DNSProbePacket.query(id: id)
        guard connected == 0, Darwin.send(descriptor, query, query.count, 0) == query.count else {
            close(descriptor)
            return nil
        }
        return Attempt(host: target.host, descriptor: descriptor, id: id)
    }

    /// Turns a Duration into seconds as a Double.
    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

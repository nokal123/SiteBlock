import Foundation
import SiteBlockCore
import Testing

// The socket protocol as the real daemon speaks it: one JSON line in, one JSON line out, limits, bad input, concurrency.
// Design: 01-overview-and-data.md § Wire Protocol; 03-daemon-cli-app.md § SocketServer.
@Suite("Wire protocol and concurrency")
struct WireProtocolTests {
    // MARK: Size limit

    // A request that is `size` bytes of padding inside an otherwise valid add request, ending in a newline.
    static func paddedRequest(size: Int) throws -> Data {
        Data(try requestLine(["command": "add", "domain": String(repeating: "a", count: size)]).utf8)
    }

    // 05 Integration Tests, sixth bullet (first part): a request over 64 KB is answered with badRequest, every time, on a socket exchange with exact JSON field names.
    @Test func aRequestOver64KBGetsBadRequestOnTheRawSocket() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let big = try Self.paddedRequest(size: 70_000)
            for round in 1...10 {
                let reply = try rawExchange(big, socketPath: daemon.socketPath)
                #expect(reply.ok == false, "round \(round): \(reply.text.prefix(200))")
                #expect(reply.errorCode == "badRequest", "round \(round)")
                #expect((reply.json?["error"] as? String)?.isEmpty == false, "a human-readable error sentence is present")
                #expect(reply.newlineCount == 1 && reply.data.last == 10, "the reply is exactly one line")
            }
            let status = try daemon.status()
            #expect(status.blocked.isEmpty, "the oversized add must not have been executed")
        }
    }

    // The same limit seen through the real DaemonClient, which has to cope with the daemon hanging up while the request is still being written.
    @Test func aRequestOver64KBGetsBadRequestThroughTheRealClient() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            for round in 1...10 {
                let reply = try daemon.send(.add, domain: String(repeating: "a", count: 70_000))
                #expect(reply.ok == false && reply.errorCode == .badRequest, "round \(round)")
            }
        }
    }

    // 03 § SocketServer step 5: the daemon stops reading at 64 KB, so a client that never sends a newline gets its answer at once instead of after the 2-second read timeout.
    @Test func bytesWithoutANewlineAreRejectedAt64KBWithoutWaitingForTheTimeout() throws {
        try withDaemon { daemon in
            let connection = try RawConnection(path: daemon.socketPath)
            connection.write(Data(repeating: UInt8(ascii: "x"), count: 70_000))
            let reply = connection.read(timeout: 3, stopAtNewline: true)
            #expect(reply.errorCode == "badRequest", "got: \(reply.text.prefix(200))")
            #expect(reply.seconds < 1.5, "answered after \(reply.seconds) s; the 2 s read timeout must not be needed")
        }
    }

    // 03 § SocketServer step 5: "Over the limit returns badRequest". A client that is still in the middle of writing megabytes must be able to read that reply, so the daemon has to keep reading (and discard) for a while after answering instead of hanging up on the unread data.
    @Test func aMultiMegabyteRequestStillGetsItsBadRequestReply() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let huge = Data(repeating: UInt8(ascii: "x"), count: 3_000_000)
            for round in 1...3 {
                let connection = try RawConnection(path: daemon.socketPath)
                connection.write(huge)
                let reply = connection.read(timeout: 6, stopAtNewline: true)
                #expect(reply.errorCode == "badRequest", "round \(round): got \(reply.text.prefix(150)) after \(reply.seconds) s")
            }
            for round in 1...3 {
                let reply = try daemon.send(.add, domain: String(repeating: "a", count: 3_000_000))
                #expect(reply.errorCode == .badRequest, "round \(round) through the real client")
            }
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
        }
    }

    // 01 § Wire Protocol: only requests LARGER than 64 KB are rejected. A 60,000-byte request is processed (here it fails as an invalid domain, not as a bad request).
    @Test func aRequestUnderTheLimitIsProcessedNormally() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let reply = try rawExchange(try Self.paddedRequest(size: 60_000), socketPath: daemon.socketPath)
            #expect(reply.errorCode == "invalidDomain", "got: \(reply.text.prefix(200))")
        }
    }

    // MARK: Bad input

    // 05 Integration Tests, sixth bullet (second part): input that is not a valid request gets badRequest with the exact wire field names, and the daemon keeps answering.
    @Test func invalidRequestsGetBadRequestAndTheDaemonKeepsAnswering() throws {
        let invalid: [(String, String)] = [
            ("not json at all\n", "plain text"),
            ("{}\n", "empty object, no command"),
            ("[]\n", "array instead of object"),
            ("\n", "empty line"),
            ("   \n", "blanks only"),
            ("{\"command\":\"nope\"}\n", "unknown command"),
            ("{\"command\":42}\n", "command of the wrong type"),
            ("{\"command\":\"add\",\"domain\":[\"a.com\"]}\n", "domain of the wrong type"),
            ("{\"command\":\"setDelay\",\"seconds\":\"ten\"}\n", "seconds of the wrong type"),
            ("{\"command\":\"status\"\n", "truncated JSON"),
            ("{\"command\":\"status\"}}\n", "trailing brace"),
            ("\u{0}\u{0}\n", "NUL bytes"),
        ]
        try withDaemon { daemon in
            for (text, label) in invalid {
                let reply = try rawExchange(text, socketPath: daemon.socketPath)
                #expect(reply.ok == false, "\(label): \(reply.text.prefix(150))")
                #expect(reply.errorCode == "badRequest", "\(label)")
                #expect((reply.json?["error"] as? String)?.isEmpty == false, "\(label): error sentence present")
                #expect(reply.newlineCount == 1, "\(label): one reply line")
            }
            // Raw binary garbage that is not even UTF-8.
            let binary = try rawExchange(Data([0xFF, 0xFE, 0x00, 0x80, 0x0A]), socketPath: daemon.socketPath)
            #expect(binary.errorCode == "badRequest", "binary garbage")
            let status = try daemon.status()
            #expect(status.blocked.isEmpty)
        }
    }

    // 03 § SocketServer step 4: the request ends at end of stream too, so a request without a newline is processed once the client stops writing.
    @Test func aRequestWithoutANewlineIsProcessedWhenTheClientFinishesWriting() throws {
        try withDaemon { daemon in
            let reply = try rawExchange("{\"command\":\"status\"}", socketPath: daemon.socketPath, finishWriting: true)
            #expect(reply.ok == true, "got: \(reply.text.prefix(200))")
            #expect(reply.json?["status"] is [String: Any])
        }
    }

    // 01 § Wire Protocol: one request per connection. A second request line sent on the same connection must not be executed.
    @Test func onlyTheFirstRequestLineOfAConnectionIsExecuted() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let connection = try RawConnection(path: daemon.socketPath)
            connection.write("{\"command\":\"status\"}\n{\"command\":\"add\",\"domain\":\"smuggled.example\"}\n")
            let reply = connection.read(timeout: 3)
            #expect(reply.ok == true)
            #expect(reply.newlineCount == 1, "exactly one response for one request: \(reply.text.prefix(300))")
            pause(0.5)
            let status = try daemon.status()
            #expect(status.blocked.isEmpty, "the smuggled add was executed")
            #expect(!daemon.hosts().blocks("smuggled.example"))
        }
    }

    // 03 § SocketServer step 2: SO_NOSIGPIPE keeps clients that vanish (before or after sending) from crashing the daemon.
    @Test func clientsThatVanishDoNotHurtTheDaemon() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            for round in 1...60 {
                // Sends a status request and hangs up without reading the reply, so the daemon writes to a closed connection.
                let rude = try RawConnection(path: daemon.socketPath)
                rude.write("{\"command\":\"status\"}\n")
                rude.closeNow()
                // Connects and hangs up without sending anything.
                try RawConnection(path: daemon.socketPath).closeNow()
                // Sends half a request and hangs up.
                let partial = try RawConnection(path: daemon.socketPath)
                partial.write("{\"command\":\"ad")
                partial.closeNow()
                if round % 20 == 0 { #expect(daemon.isRunning, "daemon died in round \(round)") }
                // The design's listen backlog is 16, so a burst of hundreds of connections in a few milliseconds would be refused by the kernel. A short pause per round keeps the test about vanishing clients, not about the backlog.
                pause(0.015)
            }
            #expect(daemon.isRunning)
            let answered = waitUntil(timeout: 1.5, interval: 0.05) { (try? daemon.client(timeout: 2).send(Request(command: .status)))?.ok == true }
            #expect(answered != nil, "the daemon stopped answering after the vanishing clients")
            let status = try daemon.status()
            #expect(status.passwordSet)
        }
    }

    // 05 Integration Tests, sixth bullet (third part), with the 2-second read timeout of 01 § Wire Protocol and 03 § SocketServer step 2: a connection that sends nothing is dropped within the timeout, and the daemon answers the next client.
    @Test func anIdleConnectionIsDroppedWithinTheReadTimeoutAndOtherClientsAreStillAnswered() throws {
        try withDaemon { daemon in
            let idle = try RawConnection(path: daemon.socketPath)
            let watch = Stopwatch()
            pause(0.3)
            // A second client must be answered even while the idle one is open (it may have to wait for the timeout, but must not fail).
            let during = try daemon.client(timeout: 8).send(Request(command: .status))
            #expect(during.ok, "a client arriving while another connection is idle must still be answered")
            let reply = idle.read(timeout: 6)
            #expect(reply.closedByPeer, "the daemon never closed the idle connection")
            #expect(watch.elapsed <= 3.5, "the idle connection stayed open for \(watch.elapsed) s; the daemon waits at most 2 s for the request line")
            let after = Stopwatch()
            let next = try daemon.status()
            #expect(next.delaySeconds == 2)
            #expect(after.elapsed < 1.5, "the daemon answers promptly once the idle connection is gone")
        }
    }

    // 01 § Wire Protocol: the 2-second limit also applies to a client that starts a request and stalls. Half a line, then silence, is dropped within the limit.
    @Test func aStalledHalfRequestIsDroppedWithinTheReadTimeout() throws {
        try withDaemon { daemon in
            let stalled = try RawConnection(path: daemon.socketPath)
            stalled.write("{\"command\":\"sta")
            let reply = stalled.read(timeout: 6)
            #expect(reply.closedByPeer, "the daemon kept a stalled connection open")
            #expect(reply.seconds <= 3.5, "dropped after \(reply.seconds) s")
            let status = try daemon.status()
            #expect(status.delaySeconds == 2)
        }
    }

    // MARK: Connection limits (waiting on the source change for 03 § SocketServer step 4 if these fail against today's code)

    // 03 § SocketServer step 4: at most 4 open connections per non-root user ID. A fifth connection is closed at once, without a reply; closing one of the four frees a slot; and once the idle ones time out, all four slots are usable again.
    @Test func aFifthOpenConnectionFromTheSameUserIsClosedAtOnceWithoutAReply() throws {
        try withDaemon { daemon in
            var idle = try (0..<4).map { _ in try RawConnection(path: daemon.socketPath) }
            pause(0.4)
            let fifth = try RawConnection(path: daemon.socketPath)
            fifth.write("{\"command\":\"status\"}\n")
            let rejected = fifth.read(timeout: 1.5)
            #expect(rejected.closedByPeer, "the over-limit connection was not closed")
            #expect(rejected.data.isEmpty, "the over-limit connection must get no reply, got: \(rejected.text.prefix(100))")
            #expect(rejected.seconds < 1.0, "closed after \(rejected.seconds) s; it must be at once")

            // Closing one of the four frees a slot.
            idle.removeFirst().closeNow()
            pause(0.4)
            let admitted = try daemon.client(timeout: 3).send(Request(command: .status))
            #expect(admitted.ok, "a slot was freed but the next client was not answered")

            // The remaining idle connections run into the 2 s read timeout and are dropped; every slot is free again, so four new ones can be held and the fifth is again refused.
            for connection in idle { #expect(connection.read(timeout: 5).closedByPeer) }
            idle = try (0..<4).map { _ in try RawConnection(path: daemon.socketPath) }
            pause(0.4)
            let again = try RawConnection(path: daemon.socketPath)
            again.write("{\"command\":\"status\"}\n")
            let refusedAgain = again.read(timeout: 1.5)
            #expect(refusedAgain.data.isEmpty && refusedAgain.closedByPeer, "after the timeouts the limit must still hold, and no slot may have leaked")
            for connection in idle { connection.closeNow() }
            pause(0.4)
            let status = try daemon.status()
            #expect(status.delaySeconds == 2)
        }
    }

    // 03 § SocketServer step 4: every way a connection can end gives its slot back. With a leak of even one slot per path, a few dozen of these would lock every later client out.
    @Test func everyKindOfConnectionEndGivesItsSlotBack() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let big = try Self.paddedRequest(size: 70_000)
            for round in 1...15 {
                // The replies to these are not the point; a refused connection (slot not released yet) is not an error here.
                _ = try? daemon.send(.status)
                _ = try? rawExchange("not json\n", socketPath: daemon.socketPath)
                _ = try? rawExchange(big, socketPath: daemon.socketPath)
                if let rude = try? RawConnection(path: daemon.socketPath) {
                    rude.write("{\"command\":\"status\"}\n")
                    rude.closeNow()
                }
                try? RawConnection(path: daemon.socketPath).closeNow()
                if let partial = try? RawConnection(path: daemon.socketPath) {
                    partial.write("{\"command\":\"st")
                    partial.closeNow()
                }
                // After a short pause the daemon must answer again: if every slot were taken for good, this would never succeed.
                let answered = waitUntil(timeout: 1.5, interval: 0.05) { (try? daemon.client(timeout: 2).send(Request(command: .status)))?.ok == true }
                #expect(answered != nil, "round \(round): the daemon stopped answering")
            }
        }
    }

    // MARK: Concurrency

    // Runs `body` for every index on separate threads and collects the results in index order. At most `inFlight` calls run at the same moment: the daemon allows only 4 open connections per user (03 § SocketServer step 4), so tests stay at 3 and leave one slot of slack for a connection the daemon has not finished closing.
    static func concurrently<T>(_ count: Int, inFlight: Int = 3, _ body: @escaping (Int) -> T) -> [T] {
        let box = ResultBox<T>(count: count)
        let slots = DispatchSemaphore(value: inFlight)
        let finished = DispatchGroup()
        for index in 0..<count {
            finished.enter()
            slots.wait()
            Thread.detachNewThread {
                box.set(index, body(index))
                slots.signal()
                finished.leave()
            }
        }
        finished.wait()
        return box.values
    }

    // 05 Integration Tests, seventh bullet, adapted to the 4-connections-per-user limit: ten clients, three at a time, each add a different domain; all ten end up blocked, in the hosts file and in the saved state.
    @Test func tenClientsAddingDifferentDomainsAtOnceAllEndUpBlocked() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let domains = (1...10).map { "concurrent\($0).example.org" }
            let client = daemon.client()
            let replies = Self.concurrently(10) { index in (try? client.send(Request(command: .add, domain: domains[index]))) }
            for (index, reply) in replies.enumerated() {
                #expect(reply?.ok == true, "client \(index): \(String(describing: reply?.error))")
            }
            let status = try daemon.status()
            #expect(Set(status.blocked.map(\.domain)) == Set(domains))
            #expect(status.blocked.count == 10)
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: domains)))
            let saved = try #require(daemon.stateObject())
            let savedDomains = (saved["blocked"] as? [[String: Any]])?.compactMap { $0["domain"] as? String } ?? []
            #expect(Set(savedDomains) == Set(domains), "the saved state lists all ten")
        }
    }

    // 01 § Commands: adding a site that is already blocked is alreadyBlocked. In each of five rounds, three clients race to add the same site: exactly one wins and the other two are told alreadyBlocked.
    @Test func clientsRacingToAddTheSameDomainExactlyOneSucceeds() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let client = daemon.client()
            var domains: [String] = []
            for round in 1...5 {
                let domain = "race\(round).example.org"
                domains.append(domain)
                let replies = Self.concurrently(3) { _ in (try? client.send(Request(command: .add, domain: domain))) }
                #expect(replies.filter { $0?.ok == true }.count == 1, "round \(round): exactly one add wins")
                #expect(replies.filter { $0?.errorCode == .alreadyBlocked }.count == 2, "round \(round): the others are alreadyBlocked")
                pause(0.1)
            }
            #expect(daemon.hostsText() == ExpectedHosts.text(blocking: ExpectedHosts.expand(all: domains)))
        }
    }

    // 03 § DaemonRuntime: commands and ticks run on one queue, so status requests made while many adds and the 0.2 s tick are running never fail and never see a half-built state. One thread adds 16 sites while two others poll.
    @Test func statusPollsDuringHeavyAddTrafficAlwaysSucceed() throws {
        try withDaemon { daemon in
            try daemon.setUp()
            let client = daemon.client()
            let outcomes = Self.concurrently(3) { index -> [Bool] in
                if index > 0 { return (0..<60).map { _ in (try? client.send(Request(command: .status)))?.ok == true } }
                return (0..<16).map { n in (try? client.send(Request(command: .add, domain: "load\(n).example.org")))?.ok == true }
            }
            #expect(outcomes.flatMap { $0 }.allSatisfy { $0 }, "some request failed")
            let status = try daemon.status()
            #expect(status.blocked.count == 16)
            #expect(daemon.hosts().beginCount == 1 && daemon.hosts().endCount == 1)
        }
    }

    // MARK: Files the daemon creates

    // 03 § SocketServer step 1 and 04 / 01 § Security: the socket is world-writable (0666), the state folder is root-only (0700), the state files and the hosts file have the modes the design names, and no temp files are left behind.
    @Test func socketStateAndHostsFilesHaveTheDocumentedModesAndLeaveNoTempFiles() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.send(.add, domain: "youtube.com").requireOK()
            pause(0.5)
            #expect(permissions(of: daemon.socketPath) == 0o666)
            #expect(permissions(of: daemon.stateDir) == 0o700)
            #expect(permissions(of: daemon.statePath) == 0o600)
            #expect(permissions(of: daemon.stateBackupPath) == 0o600)
            #expect(permissions(of: daemon.hostsPath) == 0o644)
            for directory in [daemon.root, daemon.stateDir, URL(fileURLWithPath: daemon.stateBackupPath).deletingLastPathComponent().path] {
                let leftovers = daemon.listing(of: directory).filter { $0.contains("tmp") || $0.contains(".siteblock") }
                #expect(leftovers.isEmpty, "temp files left in \(directory): \(leftovers)")
            }
        }
    }
}

// A thread-safe array that threads fill in by index.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T?]

    // Creates an array with room for `count` results.
    init(count: Int) { items = Array(repeating: nil, count: count) }

    // Stores the result for one index.
    func set(_ index: Int, _ value: T) { lock.lock(); items[index] = value; lock.unlock() }

    // Every stored result, in index order.
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items.compactMap { $0 } }
}

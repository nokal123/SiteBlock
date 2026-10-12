import Foundation
import Testing
import SiteBlockCore

// Expected values come from Design Plans/03-daemon-cli-app.md § 11 DNSEnforcer, "Reachability check": one DNS query for example.com (type A, UDP) is sent to
// both family servers at the same time, the wait is up to 2 seconds in total for whichever answers first, and an answer counts only with the same random ID
// and the QR bit set. The real servers are 1.1.1.3 and 1.0.0.3 on port 53; these tests aim the same check at stand-in servers on loopback ports, so no
// network is used. Each stand-in is a real UDP socket on 127.0.0.1 with its own thread.

// How a stand-in server behaves.
private enum Behavior {
    // Receives the query and records it, but never answers.
    case silent
    // Receives the query and, after the delay, answers with the same ID and the QR bit set.
    case answers(after: Double)
    // Answers at once, with the ID changed (a stray or forged packet).
    case answersWithAnotherID
    // Answers at once with the query unchanged, so the QR bit is still clear (a server that echoes).
    case echoesTheQuery
    // Nothing listens on the port, so the network refuses the packet (a "port unreachable" error comes back).
    case refuses
}

// A UDP server on a loopback port. It handles one query, the way the check sends one query.
private final class StandInServer: @unchecked Sendable {
    let port: UInt16
    private var descriptor: Int32 = -1
    private let lock = NSLock()
    private var received: [UInt8]?

    // The query this server received, or nil if none has arrived yet.
    var receivedQuery: [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    // Binds a UDP socket to a free loopback port. For `.refuses` the port is released again at once, so that nothing listens there.
    init(_ behavior: Behavior) {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        if case .refuses = behavior {
            close(socketDescriptor)
            return
        }
        descriptor = socketDescriptor
        Thread.detachNewThread { [self] in serve(behavior) }
    }

    // Closes the socket (which also ends the thread's wait).
    func stop() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    // Waits for one query, records it, and replies as the behavior says.
    private func serve(_ behavior: Behavior) {
        var buffer = [UInt8](repeating: 0, count: 512)
        var sender = sockaddr_in()
        var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &senderLength) } }
        guard count > 0 else { return }
        var reply = Array(buffer[0..<count])
        lock.lock()
        received = reply
        lock.unlock()
        switch behavior {
        case .answers(let delay):
            Thread.sleep(forTimeInterval: delay)
            reply[2] |= 0x80
        case .answersWithAnotherID:
            reply[0] ^= 0xFF
            reply[2] |= 0x80
        case .echoesTheQuery:
            break
        case .silent, .refuses:
            return
        }
        _ = withUnsafePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, reply, reply.count, 0, $0, senderLength) } }
    }
}

// Runs the real check against these stand-in servers and returns its answer and how many seconds it took. The servers are left open.
private func timeCheck(against servers: [StandInServer]) -> (result: FamilyDNSCheck, seconds: Double) {
    let probe = UDPFamilyDNSProbe(targets: servers.map { UDPFamilyDNSProbe.Target(host: "127.0.0.1", port: $0.port) })
    let start = ContinuousClock.now
    let result = probe.check()
    let parts = (ContinuousClock.now - start).components
    return (result, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
}

// Starts two stand-in servers with these behaviors, runs the check against them, and closes them again.
private func runCheck(_ first: Behavior, _ second: Behavior) -> (result: FamilyDNSCheck, seconds: Double) {
    let servers = [StandInServer(first), StandInServer(second)]
    let run = timeCheck(against: servers)
    servers.forEach { $0.stop() }
    return run
}

@Suite("UDPFamilyDNSProbe against stand-in servers")
struct UDPFamilyDNSProbeTests {
    // Both servers are asked at the same time, so when neither answers the wait is the 2 seconds, not 2 + 2. The upper limit is 3 seconds so a slow machine does not fail it, but 4 seconds (one server after the other) does.
    @Test func whenNeitherServerAnswersTheCheckGivesUpAfterTwoSecondsNotFour() {
        let run = runCheck(.silent, .silent)
        #expect(run.result.reachable == false)
        #expect(run.seconds >= 1.9, "gave up after \(run.seconds) s, before the 2 second timeout")
        #expect(run.seconds < 3.0, "took \(run.seconds) s; the servers must be asked at the same time")
    }

    // The query goes to both servers even when the first answers at once: the second server's socket still receives it. And what is sent is the exact RFC 1035 query for example.com, type A, class IN, with the QR bit clear.
    @Test func bothServersReceiveTheExactQueryEvenWhenTheFirstAnswersAtOnce() throws {
        let servers = [StandInServer(.answers(after: 0)), StandInServer(.silent)]
        defer { servers.forEach { $0.stop() } }
        let run = timeCheck(against: servers)
        #expect(run.result.reachable == true)
        #expect(run.seconds < 0.5, "took \(run.seconds) s although the first server answered at once")
        let expectedAfterTheID = Array(DNSProbePacket.query(id: 0)[2...])
        for (index, server) in servers.enumerated() {
            let arrived = waitUntilReceived(server)
            let packet = try #require(arrived, "server \(index) never received a query")
            #expect(packet.count == 29)
            #expect(Array(packet[2...]) == expectedAfterTheID, "server \(index) received different bytes")
        }
    }

    // A server that answers later is enough; the check returns when that answer arrives, not at the 2 second limit.
    @Test func oneServerAnsweringLateMakesTheCheckSucceedAtThatMoment() {
        let run = runCheck(.silent, .answers(after: 0.3))
        #expect(run.result.reachable == true)
        #expect(run.seconds >= 0.25 && run.seconds < 1.0, "took \(run.seconds) s")
    }

    @Test func theSecondServerAnsweringAtOnceIsEnoughToo() {
        let run = runCheck(.silent, .answers(after: 0))
        #expect(run.result.reachable == true)
        #expect(run.seconds < 0.5, "took \(run.seconds) s")
    }

    // An answer with another ID is a stray packet. It is ignored while the wait goes on, so a lone stray packet gives "unreachable" after the full 2 seconds.
    @Test func aReplyWithAnotherIDDoesNotCountAndTheWaitContinues() {
        let run = runCheck(.answersWithAnotherID, .silent)
        #expect(run.result.reachable == false)
        #expect(run.seconds >= 1.9, "gave up after \(run.seconds) s; the stray packet must not end the wait")
    }

    // A wrong-ID packet first, then a right answer from the other server: the right one wins.
    @Test func aRightAnswerStillCountsAfterAStrayPacket() {
        let run = runCheck(.answersWithAnotherID, .answers(after: 0.4))
        #expect(run.result.reachable == true)
        #expect(run.seconds >= 0.35 && run.seconds < 1.2, "took \(run.seconds) s")
    }

    // A packet that is the query itself (QR clear) is not an answer.
    @Test func aServerThatEchoesTheQueryDoesNotCount() {
        let run = runCheck(.echoesTheQuery, .silent)
        #expect(run.result.reachable == false)
        #expect(run.seconds >= 1.9)
    }

    // A port that refuses the packet ends that server's attempt only; the other server still gets its full wait.
    @Test func aRefusingServerDoesNotEndTheWaitForTheOtherOne() {
        let silentRun = runCheck(.refuses, .silent)
        #expect(silentRun.result.reachable == false)
        #expect(silentRun.seconds >= 1.9, "gave up after \(silentRun.seconds) s while the other server was still being waited for")
        let answeringRun = runCheck(.refuses, .answers(after: 0.3))
        #expect(answeringRun.result.reachable == true)
        #expect(answeringRun.seconds >= 0.25 && answeringRun.seconds < 1.0, "took \(answeringRun.seconds) s")
    }

    // When both ports refuse there is nothing left to wait for, so the answer comes at once.
    @Test func whenBothServersRefuseTheCheckEndsAtOnce() {
        let run = runCheck(.refuses, .refuses)
        #expect(run.result.reachable == false)
        #expect(run.seconds < 0.5, "took \(run.seconds) s")
    }

    // Waits up to a second for a stand-in server to have recorded its query.
    private func waitUntilReceived(_ server: StandInServer) -> [UInt8]? {
        let start = ContinuousClock.now
        while true {
            if let packet = server.receivedQuery { return packet }
            let parts = (ContinuousClock.now - start).components
            if Double(parts.seconds) + Double(parts.attoseconds) / 1e18 > 1.0 { return nil }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

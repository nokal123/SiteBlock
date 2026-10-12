import Foundation
import Testing
import SiteBlockCore

// Expected values come from the DNS message format (RFC 1035 § 4.1) and from Design Plans/03-daemon-cli-app.md § 11 DNSEnforcer, "Reachability check":
// "one DNS query for `example.com` (type A, UDP port 53, 2-second timeout)", accepted only for "a response with the same ID and the QR bit set".
// The query bytes are typed out here by hand from the format, not produced by the code: a 12-byte header (ID, flags 0x0100 = recursion desired, one question,
// no other records), then the name as length-prefixed labels (7 "example", 3 "com", 0), then type A (1) and class IN (1).

// The 29 bytes of the query for example.com, A, IN, with the given ID.
private func expectedQuery(id: UInt16) -> [UInt8] {
    [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x63, 0x6F, 0x6D, 0x00, 0x00, 0x01, 0x00, 0x01]
}

// A DNS answer for the query with this ID: the header with the given flags and one answer record (example.com A 93.184.216.34, compressed name pointer), after the question.
private func answer(id: UInt16, flags: UInt16 = 0x8180) -> [UInt8] {
    var packet = expectedQuery(id: id)
    packet[2] = UInt8(flags >> 8)
    packet[3] = UInt8(flags & 0xFF)
    // One answer record.
    packet[7] = 0x01
    packet.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 93, 184, 216, 34])
    return packet
}

@Suite("DNSProbePacket query")
struct DNSProbePacketQueryTests {
    @Test(arguments: [UInt16(0x0000), 0x0001, 0x1234, 0xABCD, 0xFF00, 0xFFFF])
    func theQueryIsExactlyTheRFC1035BytesForExampleComTypeA(id: UInt16) {
        #expect(DNSProbePacket.query(id: id) == expectedQuery(id: id))
    }

    @Test func theQueryIsTwentyNineBytesLong() {
        #expect(DNSProbePacket.query(id: 7).count == 29)
    }

    // The ID goes in the first two bytes, high byte first (network byte order), so an answer carries it back the same way.
    @Test func theIDIsWrittenHighByteFirst() {
        let packet = DNSProbePacket.query(id: 0xABCD)
        #expect(packet[0] == 0xAB && packet[1] == 0xCD)
    }

    @Test func theQueryAsksTheServerToLookTheNameUpAndHasOneQuestionAndNoOtherRecords() {
        let packet = DNSProbePacket.query(id: 1)
        #expect(packet[2] == 0x01 && packet[3] == 0x00, "flags: recursion desired, QR clear, ordinary query")
        #expect(Array(packet[4...11]) == [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func theQueryNameIsExampleDotCom() {
        #expect(DNSProbePacket.queryName == "example.com")
    }

    // A query is not an answer: its QR bit is clear, so the reply check refuses it even though the ID matches. This is what stops a server (or a network) that echoes the query from counting as a DNS server.
    @Test func theQueryItselfIsNotAcceptedAsAnAnswer() {
        #expect(!DNSProbePacket.isAnswer(DNSProbePacket.query(id: 0x1234), toQueryWithID: 0x1234))
    }
}

@Suite("DNSProbePacket answer check")
struct DNSProbePacketAnswerTests {
    @Test func anAnswerWithTheSameIDAndTheQRBitSetIsAccepted() {
        #expect(DNSProbePacket.isAnswer(answer(id: 0x1234), toQueryWithID: 0x1234))
    }

    // Only the ID and the QR bit matter. A server that says the name does not exist (rcode 3), refuses (5), fails (2), or truncated its answer (TC bit) was still reached.
    @Test(arguments: [UInt16(0x8180), 0x8183, 0x8182, 0x8185, 0x8380, 0x8580, 0x8000, 0xFFFF])
    func anyFlagsWithTheQRBitSetAreAccepted(flags: UInt16) {
        #expect(DNSProbePacket.isAnswer(answer(id: 0x0042, flags: flags), toQueryWithID: 0x0042))
    }

    // The smallest possible answer is the 12-byte header alone.
    @Test func aBareHeaderWithTheRightIDAndQRIsAccepted() {
        let header: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(DNSProbePacket.isAnswer(header, toQueryWithID: 0x1234))
    }

    // A packet with another ID is a stray or forged packet, not the answer to this query. Each byte of the ID is checked on its own.
    @Test(arguments: [UInt16(0x1235), 0x1233, 0x1334, 0x0234, 0x4321, 0x3412, 0x0000, 0xFFFF])
    func anAnswerWithAnotherIDIsRefused(otherID: UInt16) {
        #expect(!DNSProbePacket.isAnswer(answer(id: otherID), toQueryWithID: 0x1234))
    }

    // The QR bit is the top bit of the third byte. With it clear the packet is a query, whatever else it says (a response code, an answer count).
    @Test(arguments: [UInt16(0x0100), 0x0180, 0x0000, 0x7FFF, 0x0183, 0x7980])
    func aPacketWithTheQRBitClearIsRefused(flags: UInt16) {
        #expect(!DNSProbePacket.isAnswer(answer(id: 0x1234, flags: flags), toQueryWithID: 0x1234))
    }

    // Anything shorter than the 12-byte header cannot hold the flags and counts, even when the bytes it does have look right. Every length from 0 to 11 is refused, cut from an otherwise good answer.
    @Test(arguments: Array(0...11))
    func aTruncatedPacketIsRefused(length: Int) {
        let good = answer(id: 0x1234)
        #expect(DNSProbePacket.isAnswer(good, toQueryWithID: 0x1234))
        #expect(!DNSProbePacket.isAnswer(Array(good.prefix(length)), toQueryWithID: 0x1234), "a \(length)-byte packet was accepted")
    }

    @Test func anEmptyPacketIsRefused() {
        #expect(!DNSProbePacket.isAnswer([], toQueryWithID: 0))
    }

    @Test func theHeaderLengthIsTwelve() {
        #expect(DNSProbePacket.headerLength == 12)
    }

    // The ID 0 is a legal ID; an all-zero packet has the right ID but QR clear, so it is refused for that reason alone.
    @Test func anAllZeroTwelveBytePacketIsRefusedBecauseQRIsClear() {
        #expect(!DNSProbePacket.isAnswer([UInt8](repeating: 0, count: 12), toQueryWithID: 0))
    }

    // Bytes after the header are not read, so garbage there cannot make a good answer fail or a bad one pass.
    @Test func bytesAfterTheHeaderDoNotMatter() {
        var packet = answer(id: 0x5555)
        for index in 12..<packet.count { packet[index] = 0xFF }
        #expect(DNSProbePacket.isAnswer(packet, toQueryWithID: 0x5555))
        var wrong = packet
        wrong[0] = 0x00
        #expect(!DNSProbePacket.isAnswer(wrong, toQueryWithID: 0x5555))
    }
}

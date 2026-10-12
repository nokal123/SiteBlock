import Foundation

/// The bytes of the one DNS question SiteBlock asks to find out whether the family DNS servers answer on this network, and the rule for accepting an answer. It does no network work, so it can be tested on any input.
public enum DNSProbePacket {
    /// The name that is asked about. `example.com` is a name reserved for examples, so it exists, is never blocked by a family filter, and is not an adult site.
    public static let queryName = "example.com"

    /// The number of bytes in a DNS message header. Every valid message, query or answer, starts with these.
    public static let headerLength = 12

    /// Builds a DNS query for `example.com`, record type A (an IPv4 address), class IN (the internet), as sent over UDP. The message is a 12-byte header followed by the question:
    /// - the 16-bit ID chosen by the caller, which the answer must repeat;
    /// - the flags `0x0100`, meaning an ordinary query that asks the server to look the name up for us (recursion desired);
    /// - one question and no answers, authority records or extra records;
    /// - the name as length-prefixed labels (`7 example 3 com 0`), then type 1 and class 1.
    public static func query(id: UInt16) -> [UInt8] {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in queryName.split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        // A zero length ends the name; then the type (A = 1) and the class (IN = 1), each in two bytes.
        packet.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return packet
    }

    /// True only when the bytes are an answer to the query with this ID: at least a full 12-byte header, the same 16-bit ID as the query, and the QR bit set (the top bit of the flags, which is 1 in an answer and 0 in a query). The answer's contents are not looked at: any server that sends back an answer with the right ID is reachable, even if it says the name does not exist. A packet that is too short, carries another ID (a stray or forged packet), or is itself a query is not accepted.
    public static func isAnswer(_ packet: [UInt8], toQueryWithID id: UInt16) -> Bool {
        guard packet.count >= headerLength else { return false }
        let packetID = (UInt16(packet[0]) << 8) | UInt16(packet[1])
        let isResponse = packet[2] & 0x80 != 0
        return packetID == id && isResponse
    }
}

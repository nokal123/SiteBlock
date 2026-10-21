namespace SiteBlock.Core;

/// <summary>
/// The bytes of the one DNS question SiteBlock asks to find out whether the family DNS servers answer on this network, and the rule for accepting an answer.
/// It does no network work, so it can be tested on any input.
/// </summary>
public static class DNSProbePacket
{
    /// <summary>The name that is asked about. <c>example.com</c> is a name reserved for examples, so it exists, is never blocked by a family filter, and is not an adult site.</summary>
    public const string QueryName = "example.com";

    /// <summary>The number of bytes in a DNS message header. Every valid message, query or answer, starts with these.</summary>
    public const int HeaderLength = 12;

    /// <summary>
    /// Builds a DNS query for <c>example.com</c>, record type A (an IPv4 address), class IN (the internet), as sent over UDP. The message is a 12-byte header followed by the question:
    /// the 16-bit ID chosen by the caller (which the answer must repeat), the flags 0x0100 (an ordinary query that asks the server to look the name up for us),
    /// one question and no other records, then the name as length-prefixed labels (7 example 3 com 0), type 1 and class 1.
    /// </summary>
    public static byte[] Query(ushort id)
    {
        var packet = new List<byte> { (byte)(id >> 8), (byte)(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
        foreach (string label in QueryName.Split('.'))
        {
            packet.Add((byte)label.Length);
            packet.AddRange(System.Text.Encoding.UTF8.GetBytes(label));
        }
        // A zero length ends the name; then the type (A = 1) and the class (IN = 1), each in two bytes.
        packet.AddRange([0x00, 0x00, 0x01, 0x00, 0x01]);
        return packet.ToArray();
    }

    /// <summary>
    /// True only when the bytes are an answer to the query with this ID: at least a full 12-byte header, the same 16-bit ID as the query, and the QR bit set (the top bit of the flags, which is 1 in an answer and 0 in a query).
    /// The answer's contents are not looked at: any server that sends back an answer with the right ID is reachable, even if it says the name does not exist.
    /// A packet that is too short, carries another ID (a stray or forged packet), or is itself a query is not accepted.
    /// </summary>
    public static bool IsAnswer(ReadOnlySpan<byte> packet, ushort id)
    {
        if (packet.Length < HeaderLength) return false;
        ushort packetId = (ushort)((packet[0] << 8) | packet[1]);
        bool isResponse = (packet[2] & 0x80) != 0;
        return packetId == id && isResponse;
    }
}

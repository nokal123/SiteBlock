using System.Text;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// HostsEnforcer.DecodeKeepingBytes / EncodeKeepingBytes keep every byte of the hosts file across a read-and-write, so a stray
// byte in the person's own lines survives and SiteBlock's own UTF-8 lines read back as written. Pure logic, so it runs on the Mac.
// Expected values come from 06-windows.md § HostsEnforcer step 2: valid UTF-8 decodes normally; each stray byte b becomes U+DC00+b.
public sealed class HostsEncodingTests
{
    [Fact]
    public void Decode_PlainAscii_PassesThrough()
    {
        Assert.Equal("hello\n127.0.0.1 x\n", HostsEnforcer.DecodeKeepingBytes(Encoding.ASCII.GetBytes("hello\n127.0.0.1 x\n")));
    }

    [Fact]
    public void Decode_ValidMultiByteUtf8_BecomesItsCharacter()
    {
        // E2 80 94 is the UTF-8 of the em-dash U+2014 that the BEGIN marker holds.
        Assert.Equal("—", HostsEnforcer.DecodeKeepingBytes([0xE2, 0x80, 0x94]));
    }

    [Theory]
    [InlineData(0x80, 0xDC80)]
    [InlineData(0xE9, 0xDCE9)]
    [InlineData(0xFF, 0xDCFF)]
    public void Decode_StrayByte_BecomesItsPlaceholder(int strayByte, int expectedCodePoint)
    {
        string decoded = HostsEnforcer.DecodeKeepingBytes([(byte)strayByte]);

        Assert.Equal(1, decoded.Length);
        Assert.Equal((char)expectedCodePoint, decoded[0]);
    }

    [Fact]
    public void Decode_StrayByteBetweenAscii_KeepsBothSides()
    {
        string decoded = HostsEnforcer.DecodeKeepingBytes([(byte)'a', 0xE9, (byte)'b']);

        Assert.Equal("a\uDCE9b", decoded);
    }

    [Fact]
    public void Encode_Placeholder_BecomesTheExactByte()
    {
        Assert.Equal(new byte[] { 0xE9 }, HostsEnforcer.EncodeKeepingBytes("\uDCE9"));
    }

    [Fact]
    public void Encode_EmDash_BecomesItsUtf8Bytes()
    {
        Assert.Equal(new byte[] { 0xE2, 0x80, 0x94 }, HostsEnforcer.EncodeKeepingBytes("—"));
    }

    [Theory]
    // A low surrogate below the placeholder range maps to byte 0x00, which is real ASCII, never a placeholder.
    [InlineData('\uDC00')]
    // A lone high surrogate also never came from a stray byte.
    [InlineData('\uD800')]
    public void Encode_LoneSurrogateNotFromAStrayByte_BecomesTheReplacementCharacter(char lone)
    {
        // U+FFFD is EF BF BD in UTF-8.
        Assert.Equal(new byte[] { 0xEF, 0xBF, 0xBD }, HostsEnforcer.EncodeKeepingBytes(lone.ToString()));
    }

    [Fact]
    public void DecodeThenEncode_RoundTripsEveryByte()
    {
        // A mix of ASCII, a valid UTF-8 em-dash, a stray byte and a newline.
        byte[] original = [(byte)'a', 0xE2, 0x80, 0x94, 0xE9, (byte)'\n'];

        byte[] roundTripped = HostsEnforcer.EncodeKeepingBytes(HostsEnforcer.DecodeKeepingBytes(original));

        Assert.Equal(original, roundTripped);
    }
}

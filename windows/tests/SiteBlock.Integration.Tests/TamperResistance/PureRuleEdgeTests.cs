using System.Text;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// Edge cases the existing ServiceConfigReaderTests do not cover. Expected values come from 06-windows.md § ServiceGuard and the watchdog: a service marked for
// deletion (DeleteFlag set) counts as missing; the start codes 2, 3 and 4 are automatic, manual and disabled (the registry's own codes; any other code is unknown); the
// dependencies on services and on service groups both count; a setting that could not be read is left alone (null).
public sealed class ServiceConfigReaderEdgeTests
{
    [Theory]
    // 0 and 1 are the boot and system start codes, which a SiteBlock service never has, and a negative or larger number is no start code at all.
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(5)]
    [InlineData(-1)]
    public void FromValues_StartCodeOtherThanTwoThreeOrFour_IsUnknown(int code)
    {
        var config = ServiceConfigReader.FromValues(code, 0x10, "path", "LocalSystem", null, null, 0);

        Assert.True(config.Exists);
        Assert.Equal(ServiceStartType.Unknown, config.StartType);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    // A DWORD of 0xFFFFFFFF comes back from the registry as the int -1; it is still a set flag.
    [InlineData(-1)]
    public void FromValues_AnyNonZeroDeleteFlag_CountsAsMissing(int flag)
    {
        var config = ServiceConfigReader.FromValues(2, 0x10, "path", "LocalSystem", new[] { "Tcpip" }, null, flag);

        Assert.False(config.Exists);
    }

    [Fact]
    public void FromValues_DeleteFlagZero_StillExists()
    {
        Assert.True(ServiceConfigReader.FromValues(2, 0x10, "path", "LocalSystem", null, null, 0).Exists);
    }

    [Fact]
    public void FromValues_OnlyAGroupDependency_IsReported()
    {
        // A made-up group dependency can keep the service from starting just as a service dependency can, so it must not be dropped.
        var config = ServiceConfigReader.FromValues(2, 0x10, "path", "LocalSystem", null, new[] { "MadeUpGroup" }, 0);

        Assert.Equal(new[] { "MadeUpGroup" }, config.Dependencies!);
    }

    [Fact]
    public void FromValues_DependencyListsOfOnlyBlanks_GiveAnEmptyList()
    {
        var config = ServiceConfigReader.FromValues(2, 0x10, "path", "LocalSystem", new[] { "", " " }, new[] { "\t" }, 0);

        Assert.NotNull(config.Dependencies);
        Assert.Empty(config.Dependencies!);
    }

    [Fact]
    public void FromValues_EveryValueMissing_LeavesTypeAccountAndPathUnknownAndNoDependencies()
    {
        var config = ServiceConfigReader.FromValues(null, null, null, null, null, null, null);

        Assert.True(config.Exists);
        Assert.False(config.ReadFailed);
        Assert.Null(config.TypeCode);
        Assert.Null(config.Account);
        Assert.Null(config.BinaryPath);
        Assert.NotNull(config.Dependencies);
        Assert.Empty(config.Dependencies!);
    }
}

// Edge cases the existing AclSddlTests do not cover. Expected values come from 06-windows.md § Installed Paths and Permissions: two lists match when both are protected
// or both are not and they hold the same entries in any order, with the auto-inherited flags (AI, AR) Windows adds on its own ignored (step 3); a file "that has access-list
// entries of its own, or that is protected from inheriting" is reset to inherit only (step 4). SDDL entry flags are two-letter codes, and ID marks an inherited entry.
public sealed class AclSddlEdgeTests
{
    [Theory]
    // ID anywhere in the entry's flags, read as two-letter codes.
    [InlineData("D:AI(A;IDOICI;FA;;;SY)", true)]
    [InlineData("D:AI(A;OIIOID;FA;;;BU)", true)]
    // The letters I and D next to each other across two codes (OI followed by a made-up DA) are not the ID code.
    [InlineData("D:AI(A;OIDA;FA;;;SY)", false)]
    // AR (auto-inherit required) is not protection, so a list with it still inherits only when every entry is inherited.
    [InlineData("D:AR(A;ID;FA;;;SY)", true)]
    // P together with AR or AI is protected.
    [InlineData("D:PAR(A;ID;FA;;;SY)", false)]
    public void SddlInheritsOnly_ReadsFlagsAsTwoLetterCodes(string sddl, bool expected)
    {
        Assert.Equal(expected, AclGuard.SddlInheritsOnly(sddl));
    }

    [Fact]
    public void SddlMatches_TwoListsWithNoEntries_MatchWhenProtectionMatches()
    {
        Assert.True(AclGuard.SddlMatches("D:P", "D:P"));
        Assert.True(AclGuard.SddlMatches("D:", "D:AI"));
        Assert.False(AclGuard.SddlMatches("D:P", "D:"));
    }

    [Fact]
    public void SddlMatches_AutoInheritRequiredFlagIgnoredOnEitherSide()
    {
        Assert.True(AclGuard.SddlMatches("D:PAR(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", "D:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)"));
        Assert.True(AclGuard.SddlMatches("D:P(A;OICI;FA;;;SY)", "D:PARAI(A;OICI;FA;;;SY)"));
    }

    [Fact]
    public void SddlMatches_ExtraEntryOnEitherSide_IsFalse()
    {
        const string wanted = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
        // "Users may read" added by hand must count as a difference, whichever side holds it.
        Assert.False(AclGuard.SddlMatches(wanted + "(A;OICI;0x1200a9;;;BU)", wanted));
        Assert.False(AclGuard.SddlMatches(wanted, wanted + "(A;OICI;0x1200a9;;;BU)"));
        Assert.False(AclGuard.SddlMatches("D:PAI(A;OICI;FA;;;SY)", wanted));
    }

    [Fact]
    public void SddlMatches_SameEntryWithDifferentInheritanceFlags_IsFalse()
    {
        // The folder's entries must reach new files and subfolders (OICI); an entry that applies to the folder alone is a different list.
        Assert.False(AclGuard.SddlMatches("D:PAI(A;;FA;;;SY)(A;OICI;FA;;;BA)", "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"));
    }

    [Fact]
    public void SddlMatches_DenyInPlaceOfAllow_IsFalse()
    {
        Assert.False(AclGuard.SddlMatches("D:PAI(D;OICI;FA;;;SY)(A;OICI;FA;;;BA)", "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"));
    }

    [Fact]
    public void SddlMatches_ThreeEntriesInEveryOrder_AllMatch()
    {
        string[] entries = ["(A;OICI;FA;;;SY)", "(A;OICI;FA;;;BA)", "(A;OICI;0x1200a9;;;BU)"];
        string wanted = "D:PAI" + string.Concat(entries);
        int[][] orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        foreach (int[] order in orders) Assert.True(AclGuard.SddlMatches("D:PAI" + string.Concat(order.Select(i => entries[i])), wanted), string.Join(",", order));
    }
}

// Round trips of HostsEnforcer.DecodeKeepingBytes and EncodeKeepingBytes that the existing HostsEncodingTests do not cover. Expected values come from 06-windows.md
// § HostsEnforcer step 2: every valid UTF-8 sequence becomes its character, each byte that is not part of valid UTF-8 becomes U+DC00 plus the byte, and writing reverses
// this, so the person's stray bytes go back exactly as they were and a second pass reads the same text. A lone surrogate that no decode produces is written as U+FFFD.
public sealed class HostsEncodingRoundTripTests
{
    private static byte[] RoundTrip(byte[] bytes) => HostsEnforcer.EncodeKeepingBytes(HostsEnforcer.DecodeKeepingBytes(bytes));

    [Fact]
    public void EveryOneAndTwoByteArray_RoundTripsExactly()
    {
        for (int a = 0; a < 256; a++)
        {
            Assert.Equal(new[] { (byte)a }, RoundTrip([(byte)a]));
            for (int b = 0; b < 256; b++)
            {
                byte[] pair = [(byte)a, (byte)b];
                byte[] back = RoundTrip(pair);
                if (!back.AsSpan().SequenceEqual(pair)) Assert.Fail($"{a:X2} {b:X2} came back as {Convert.ToHexString(back)}");
            }
        }
    }

    [Fact]
    public void RandomByteArraysWithManyHighBytes_RoundTripExactly()
    {
        var random = new Random(1022);
        for (int i = 0; i < 20_000; i++)
        {
            var bytes = new byte[random.Next(0, 40)];
            // Mostly bytes from 0x80 up, so broken, cut-off and overlong sequences are common, with some ASCII between them.
            for (int k = 0; k < bytes.Length; k++) bytes[k] = random.Next(4) == 0 ? (byte)random.Next(0x20, 0x7F) : (byte)random.Next(0x80, 0x100);
            byte[] back = RoundTrip(bytes);
            if (!back.AsSpan().SequenceEqual(bytes)) Assert.Fail($"{Convert.ToHexString(bytes)} came back as {Convert.ToHexString(back)}");
        }
    }

    [Fact]
    public void ValidFourByteSequence_BecomesOneCharacterAndRoundTrips()
    {
        // F0 9F 98 80 is U+1F600, which .NET text holds as two UTF-16 code units (a surrogate pair), not as placeholders.
        byte[] bytes = [0xF0, 0x9F, 0x98, 0x80];

        Assert.Equal("\U0001F600", HostsEnforcer.DecodeKeepingBytes(bytes));
        Assert.Equal(bytes, RoundTrip(bytes));
    }

    // The expected text is written as UTF-16 code units in hex, because a theory's text arguments are passed through a serializer that may not keep a lone surrogate.
    [Theory]
    // A cut-off three-byte sequence at the end of the file.
    [InlineData(new byte[] { 0x61, 0xE2, 0x80 }, "0061 DCE2 DC80")]
    // UTF-8 for the surrogate U+D800 is not valid UTF-8, so its three bytes are three stray bytes.
    [InlineData(new byte[] { 0xED, 0xA0, 0x80 }, "DCED DCA0 DC80")]
    // An overlong encoding of "/" (C0 AF) is not valid UTF-8 either.
    [InlineData(new byte[] { 0xC0, 0xAF }, "DCC0 DCAF")]
    // A four-byte sequence above U+10FFFF is not valid.
    [InlineData(new byte[] { 0xF4, 0x90, 0x80, 0x80 }, "DCF4 DC90 DC80 DC80")]
    // A lead byte followed by ASCII keeps the ASCII as itself.
    [InlineData(new byte[] { 0xE9, 0x0A }, "DCE9 000A")]
    public void InvalidSequences_BecomeOnePlaceholderPerByteAndRoundTrip(byte[] bytes, string expectedCodeUnits)
    {
        string expected = new(expectedCodeUnits.Split(' ').Select(unit => (char)Convert.ToInt32(unit, 16)).ToArray());

        Assert.Equal(expected, HostsEnforcer.DecodeKeepingBytes(bytes));
        Assert.Equal(bytes, RoundTrip(bytes));
    }

    [Fact]
    public void ValidUtf8Text_DecodesExactlyAsAnOrdinaryUtf8Read()
    {
        string text = "# Café ünïcode — 日本語 \U0001F600\n127.0.0.1 localhost\n";
        byte[] bytes = new UTF8Encoding(false).GetBytes(text);

        Assert.Equal(text, HostsEnforcer.DecodeKeepingBytes(bytes));
        Assert.Equal(bytes, HostsEnforcer.EncodeKeepingBytes(text));
    }

    [Fact]
    public void EveryPlaceholderCharacter_EncodesToItsOwnByte()
    {
        for (int b = 0x80; b <= 0xFF; b++) Assert.Equal(new[] { (byte)b }, HostsEnforcer.EncodeKeepingBytes(((char)(0xDC00 + b)).ToString()));
    }

    [Theory]
    // Just below and just above the placeholder range, and the highest low surrogate.
    [InlineData(0xDC7F)]
    [InlineData(0xDD00)]
    [InlineData(0xDFFF)]
    // A lone high surrogate, the highest one.
    [InlineData(0xDBFF)]
    public void LoneSurrogateOutsideThePlaceholderRange_EncodesToTheReplacementCharacter(int codeUnit)
    {
        Assert.Equal(new byte[] { (byte)'x', 0xEF, 0xBF, 0xBD, (byte)'y' }, HostsEnforcer.EncodeKeepingBytes("x" + (char)codeUnit + "y"));
    }

    [Fact]
    public void DecodedTextEncodedAndDecodedAgain_IsTheSameText()
    {
        // A second pass reads the same text: decode, write, read again.
        byte[] bytes = [0x23, 0x20, 0xE9, 0x74, 0xE9, 0x0A, 0xE2, 0x80, 0x94, 0xFF, 0xFE, 0x0A];
        string first = HostsEnforcer.DecodeKeepingBytes(bytes);

        Assert.Equal(first, HostsEnforcer.DecodeKeepingBytes(HostsEnforcer.EncodeKeepingBytes(first)));
    }
}

using System.Text;
using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// RegistryPol: the Registry.pol ("PReg") file format. Expected bytes come from 06-windows.md § SiteBlock.Core (Local Group Policy rules: the letters PReg, a version number, then one
// bracketed entry per setting; Parse throws PolFormatException for a file that is not valid) and the published Registry Policy File Format, which the design names: the header is
// "PReg" and the version 1 as a 32-bit little-endian number, and each entry is [key;value;type;size;data] with "[", ";" and "]" and the key and value name in UTF-16LE, the key and
// name each ending with a zero character, type and size as 32-bit little-endian numbers, and size bytes of data.
public sealed class RegistryPolTests
{
    private static byte[] U(string text) => Encoding.Unicode.GetBytes(text);

    private static byte[] Le(uint number) => BitConverter.GetBytes(number);

    private static readonly byte[] Header = [.. "PReg"u8, .. Le(1)];

    // One entry exactly as the format writes it, built by hand from the format rules.
    private static byte[] EntryBytes(string key, string name, uint type, byte[] data) => [.. U("["), .. U(key + "\0"), .. U(";"), .. U(name + "\0"), .. U(";"), .. Le(type), .. U(";"), .. Le((uint)data.Length), .. U(";"), .. data, .. U("]")];

    private static readonly byte[] OffText = [.. U("off"), 0, 0];

    [Fact]
    public void Serialize_NoEntries_IsTheEightByteHeader()
    {
        Assert.Equal(Header, RegistryPol.Serialize([]));
    }

    [Fact]
    public void Serialize_TwoEntries_WritesTheExactFormatBytes()
    {
        var entries = new[] { PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome", "DnsOverHttpsMode", "off"), PolEntry.Number(@"SOFTWARE\Policies\Google\Chrome", "SafeSitesFilterBehavior", 1) };
        byte[] expected = [.. Header, .. EntryBytes(@"SOFTWARE\Policies\Google\Chrome", "DnsOverHttpsMode", 1, OffText), .. EntryBytes(@"SOFTWARE\Policies\Google\Chrome", "SafeSitesFilterBehavior", 4, [1, 0, 0, 0])];
        Assert.Equal(expected, RegistryPol.Serialize(entries));
    }

    [Fact]
    public void Parse_HandBuiltFile_GivesTheEntriesInOrder()
    {
        byte[] file = [.. Header, .. EntryBytes(@"Software\Policies\Microsoft\Windows\WindowsUpdate\AU", "NoAutoUpdate", 4, [1, 0, 0, 0]), .. EntryBytes(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist", "1", 1, [.. U("reddit.com"), 0, 0])];
        var entries = RegistryPol.Parse(file);
        Assert.Equal(2, entries.Count);
        Assert.Equal(@"Software\Policies\Microsoft\Windows\WindowsUpdate\AU", entries[0].Key);
        Assert.Equal("NoAutoUpdate", entries[0].Name);
        Assert.Equal(4u, entries[0].Type);
        Assert.Equal([1, 0, 0, 0], entries[0].Data);
        Assert.Equal(PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist", "1", "reddit.com"), entries[1]);
    }

    [Fact]
    public void ParseAfterSerialize_KeepsEveryEntryIncludingAwkwardTextAndCase()
    {
        var entries = new List<PolEntry>
        {
            PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist", "**delvals.", " "),
            PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist", "1", "bücher.de/straße;]x[y"),
            PolEntry.Number(@"software\policies\mozilla\firefox\DNSOverHTTPS", "Enabled", 0),
            PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome", "Empty", ""),
            new(@"SOFTWARE\Vendor;odd]key", "name;with]marks", 3, [0x00, 0xFF, 0x5D, 0x00, 0x3B]),
            new(@"SOFTWARE\Vendor", "NoData", 0, []),
        };
        var back = RegistryPol.Parse(RegistryPol.Serialize(entries));
        Assert.Equal(entries, back);
        // Equality ignores letter case in keys, so the exact spelling is checked on its own.
        Assert.Equal(entries.Select(entry => entry.Key), back.Select(entry => entry.Key));
        Assert.Equal(entries.Select(entry => entry.Name), back.Select(entry => entry.Name));
    }

    [Fact]
    public void Parse_EmptyFile_HasNoEntries()
    {
        Assert.Empty(RegistryPol.Parse([]));
    }

    [Fact]
    public void Parse_HeaderOnly_HasNoEntries()
    {
        Assert.Empty(RegistryPol.Parse(Header));
    }

    public static TheoryData<string, byte[]> Malformed()
    {
        byte[] good = EntryBytes(@"SOFTWARE\Policies\Google\Chrome", "DnsOverHttpsMode", 1, OffText);
        // The offset of the size number in the good entry: after "[", the key and its zero, ";", the name and its zero, ";", the type and ";".
        int sizeAt = U("[" + @"SOFTWARE\Policies\Google\Chrome" + "\0;" + "DnsOverHttpsMode" + "\0;").Length + 4 + 2;
        byte[] WithSize(uint size)
        {
            byte[] copy = [.. good];
            Le(size).CopyTo(copy, sizeAt);
            return [.. Header, .. copy];
        }
        return new()
        {
            { "bad signature", [.. "PRex"u8, .. Le(1), .. good] },
            { "lowercase signature", [.. "preg"u8, .. Le(1)] },
            { "version 2", [.. "PReg"u8, .. Le(2), .. good] },
            { "version 0", [.. "PReg"u8, .. Le(0)] },
            { "signature only", [.. "PReg"u8] },
            { "header cut short", [.. "PReg"u8, 1, 0] },
            { "entry cut in the middle", [.. Header, .. good[..(good.Length / 2)]] },
            { "entry without closing bracket", [.. Header, .. good[..^2]] },
            { "key without closing zero", [.. Header, .. U("[SOFTWARE\\Policies")] },
            { "name without closing zero", [.. Header, .. U("[SOFTWARE\\Policies\0;Name")] },
            { "size past the end", WithSize(1000) },
            { "size of four gigabytes", WithSize(uint.MaxValue) },
            { "size one byte too large", WithSize((uint)OffText.Length + 1) },
            { "stray byte after the last entry", [.. Header, .. good, 0x5B] },
            { "text that is not an entry", [.. Header, .. U("garbage!")] },
            { "comma instead of semicolon", [.. Header, .. U("[K\0,N\0;"), .. Le(1), .. U(";"), .. Le(0), .. U(";]")] },
            { "missing opening bracket", [.. Header, .. good[2..]] },
        };
    }

    [Theory]
    [MemberData(nameof(Malformed))]
    public void Parse_MalformedFile_ThrowsPolFormatException(string what, byte[] bytes)
    {
        _ = what;
        Assert.Throws<PolFormatException>(() => RegistryPol.Parse(bytes));
    }
}

// LocalGroupPolicy: expected values from 06-windows.md § SiteBlock.Core (Windows browser policy rules: the four keys, the owned values per browser, the list subkeys, Firefox's
// WebsiteFilter\Exceptions not owned; Local Group Policy rules: IsOwned, Wanted writes each owned list as a **delvals. entry then the values 1 to N, Merged keeps every entry SiteBlock
// does not own where it is and puts SiteBlock's entries at the end, UpdatedGptIni raises the computer half of Version and lists the registry extension) and § BrowserPolicyEnforcer
// (an unchanged file is not rewritten; the uninstall pass's empty lists with the filter off leave only entries SiteBlock does not own). The `**del.<name>` prefix is the Registry.pol
// instruction that deletes one named value.
public sealed class LocalGroupPolicyTests
{
    private const string ChromeKey = @"SOFTWARE\Policies\Google\Chrome";
    private const string EdgeKey = @"SOFTWARE\Policies\Microsoft\Edge";
    private const string BraveKey = @"SOFTWARE\Policies\BraveSoftware\Brave";
    private const string FirefoxKey = @"SOFTWARE\Policies\Mozilla\Firefox";
    private const string Registry = "{35378EAC-683F-11D2-A89A-00C04FBBCFA2}";
    private const string AdminTemplates = "{D02B1F72-3407-48AE-BA88-E8213C6761F1}";

    private static readonly BrowserBlockLists Lists = new(["reddit.com"], ["youtube.com/shorts"], ["*://*.reddit.com/*"], ["*://*.youtube.com/shorts*"]);

    private static List<RegistryPolicy> Policies(BrowserBlockLists lists, bool adultFilter) => [.. Enum.GetValues<BrowserTarget>().Select(target => WindowsBrowserPolicy.Desired(target, lists, adultFilter))];

    private static List<RegistryPolicy> Normal => Policies(Lists, true);

    private static List<RegistryPolicy> Uninstall => Policies(BrowserBlockLists.Empty, false);

    // Entries the owner of the PC set, none of which SiteBlock owns.
    private static readonly PolEntry WindowsUpdate = PolEntry.Number(@"Software\Policies\Microsoft\Windows\WindowsUpdate\AU", "NoAutoUpdate", 1);
    private static readonly PolEntry Homepage = PolEntry.Text(ChromeKey, "HomepageLocation", "https://intranet.example");
    private static readonly PolEntry FirefoxException = PolEntry.Text(FirefoxKey + @"\WebsiteFilter\Exceptions", "1", "*://*.school.example/*");

    [Theory]
    [InlineData(ChromeKey + @"\URLBlocklist", "1")]
    [InlineData(ChromeKey + @"\URLBlocklist", "1001")]
    [InlineData(ChromeKey + @"\URLBlocklist", "**delvals.")]
    [InlineData(ChromeKey, "DnsOverHttpsMode")]
    [InlineData(ChromeKey, "**del.DnsOverHttpsMode")]
    [InlineData(ChromeKey, "SafeSitesFilterBehavior")]
    [InlineData(ChromeKey, "ForceGoogleSafeSearch")]
    [InlineData(EdgeKey, "ForceBingSafeSearch")]
    [InlineData(EdgeKey + @"\URLBlocklist", "3")]
    [InlineData(BraveKey, "TorDisabled")]
    [InlineData(BraveKey, "**del.TorDisabled")]
    [InlineData(FirefoxKey + @"\DNSOverHTTPS", "Enabled")]
    [InlineData(FirefoxKey + @"\DNSOverHTTPS", "Locked")]
    [InlineData(FirefoxKey + @"\WebsiteFilter\Block", "1")]
    [InlineData(@"software\policies\google\chrome\urlblocklist", "2")]
    [InlineData(@"SOFTWARE\POLICIES\GOOGLE\CHROME", "dnsoverhttpsmode")]
    public void IsOwned_SiteBlocksValuesAndListEntries_AreOwned(string key, string name)
    {
        Assert.True(LocalGroupPolicy.IsOwned(PolEntry.Text(key, name, "x"), Normal));
        // What SiteBlock owns does not depend on the lists or the filter, so the uninstall pass still recognizes every one of these.
        Assert.True(LocalGroupPolicy.IsOwned(PolEntry.Text(key, name, "x"), Uninstall));
    }

    [Theory]
    [InlineData(ChromeKey, "HomepageLocation")]
    [InlineData(ChromeKey, "**del.HomepageLocation")]
    [InlineData(ChromeKey, "TorDisabled")]
    [InlineData(ChromeKey, "ForceBingSafeSearch")]
    [InlineData(ChromeKey + @"\URLAllowlist", "1")]
    [InlineData(EdgeKey, "SafeSitesFilterBehavior")]
    [InlineData(FirefoxKey + @"\WebsiteFilter\Exceptions", "1")]
    [InlineData(FirefoxKey + @"\WebsiteFilter", "Block")]
    [InlineData(FirefoxKey + @"\DNSOverHTTPS", "ProviderURL")]
    [InlineData(FirefoxKey, "Enabled")]
    [InlineData(@"SOFTWARE\Policies\Google\Chromium\URLBlocklist", "1")]
    [InlineData(@"Software\Policies\Microsoft\Windows\WindowsUpdate\AU", "NoAutoUpdate")]
    public void IsOwned_OtherValuesInTheSameKeysAndOtherKeys_AreNotOwned(string key, string name)
    {
        Assert.False(LocalGroupPolicy.IsOwned(PolEntry.Text(key, name, "x"), Normal));
    }

    [Fact]
    public void Wanted_Chrome_NamedValuesThenTheListAsDelvalsAndOneToN()
    {
        var wanted = LocalGroupPolicy.Wanted([WindowsBrowserPolicy.Desired(BrowserTarget.Chrome, Lists, true)]);
        int delvals = wanted.FindIndex(entry => entry.Name == "**delvals.");
        Assert.True(delvals >= 0);
        var named = wanted[..delvals];
        Assert.Equal(new HashSet<PolEntry> { PolEntry.Text(ChromeKey, "DnsOverHttpsMode", "off"), PolEntry.Number(ChromeKey, "ForceGoogleSafeSearch", 1), PolEntry.Number(ChromeKey, "SafeSitesFilterBehavior", 1) }, named.ToHashSet());
        Assert.Equal(3, named.Count);
        Assert.Equal(ChromeKey + @"\URLBlocklist", wanted[delvals].Key, ignoreCase: true);
        Assert.Equal([PolEntry.Text(ChromeKey + @"\URLBlocklist", "1", "reddit.com"), PolEntry.Text(ChromeKey + @"\URLBlocklist", "2", "youtube.com/shorts")], wanted[(delvals + 1)..]);
    }

    [Fact]
    public void Wanted_ValueBytes_AreUtf16TextWithItsZeroAndLittleEndianDwords()
    {
        var wanted = LocalGroupPolicy.Wanted([WindowsBrowserPolicy.Desired(BrowserTarget.Chrome, Lists, true)]);
        var doh = wanted.Single(entry => entry.Name == "DnsOverHttpsMode");
        Assert.Equal(1u, doh.Type);
        Assert.Equal([(byte)'o', 0, (byte)'f', 0, (byte)'f', 0, 0, 0], doh.Data);
        var safeSites = wanted.Single(entry => entry.Name == "SafeSitesFilterBehavior");
        Assert.Equal(4u, safeSites.Type);
        Assert.Equal([1, 0, 0, 0], safeSites.Data);
    }

    [Fact]
    public void Wanted_EdgeBraveAndFirefox_HoldTheirOwnValuesAndLists()
    {
        var wanted = LocalGroupPolicy.Wanted(Normal);
        Assert.Contains(PolEntry.Number(EdgeKey, "ForceBingSafeSearch", 2), wanted);
        Assert.DoesNotContain(wanted, entry => entry.Key.Equals(EdgeKey, StringComparison.OrdinalIgnoreCase) && entry.Name == "SafeSitesFilterBehavior");
        Assert.Contains(PolEntry.Number(BraveKey, "TorDisabled", 1), wanted);
        Assert.Contains(PolEntry.Number(FirefoxKey + @"\DNSOverHTTPS", "Enabled", 0), wanted);
        Assert.Contains(PolEntry.Number(FirefoxKey + @"\DNSOverHTTPS", "Locked", 1), wanted);
        int ffDelvals = wanted.FindIndex(entry => entry.Key.Equals(FirefoxKey + @"\WebsiteFilter\Block", StringComparison.OrdinalIgnoreCase) && entry.Name == "**delvals.");
        Assert.True(ffDelvals >= 0);
        Assert.Equal([PolEntry.Text(FirefoxKey + @"\WebsiteFilter\Block", "1", "*://*.reddit.com/*"), PolEntry.Text(FirefoxKey + @"\WebsiteFilter\Block", "2", "*://*.youtube.com/shorts*")], wanted.Skip(ffDelvals + 1).Take(2));
        // Every list of the four browsers starts with its own delete-all entry, so a site dropped from a list is dropped when Windows applies the file.
        Assert.Equal(4, wanted.Count(entry => entry.Name == "**delvals."));
        Assert.All(wanted, entry => Assert.True(LocalGroupPolicy.IsOwned(entry, Normal), entry.ToString()));
    }

    [Fact]
    public void Wanted_Uninstall_IsEmpty()
    {
        Assert.Empty(LocalGroupPolicy.Wanted(Uninstall));
    }

    [Fact]
    public void Merged_EmptyFile_IsExactlyTheWantedEntries()
    {
        Assert.Equal(LocalGroupPolicy.Wanted(Normal), LocalGroupPolicy.Merged([], Normal));
    }

    [Fact]
    public void Merged_FileAlreadyRight_IsNull()
    {
        Assert.Null(LocalGroupPolicy.Merged(LocalGroupPolicy.Wanted(Normal), Normal));
    }

    [Fact]
    public void Merged_AlreadyRightWithOtherEntriesBeforeAndAfter_IsNull()
    {
        List<PolEntry> file = [WindowsUpdate, .. LocalGroupPolicy.Wanted(Normal), Homepage, FirefoxException];
        Assert.Null(LocalGroupPolicy.Merged(file, Normal));
    }

    [Fact]
    public void Merged_AlreadyRightWithKeysInAnotherLetterCase_IsNull()
    {
        var file = LocalGroupPolicy.Wanted(Normal).Select(entry => new PolEntry(entry.Key.ToLowerInvariant(), entry.Name.ToUpperInvariant(), entry.Type, entry.Data)).ToList();
        Assert.Null(LocalGroupPolicy.Merged(file, Normal));
    }

    [Fact]
    public void Merged_StaleOwnedEntries_AreRemovedAndOthersKeepTheirOrderBeforeTheWantedOnes()
    {
        List<PolEntry> file =
        [
            WindowsUpdate,
            PolEntry.Text(ChromeKey + @"\URLBlocklist", "**delvals.", " "),
            PolEntry.Text(ChromeKey + @"\URLBlocklist", "1", "old.example"),
            Homepage,
            PolEntry.Text(ChromeKey + @"\URLBlocklist", "1001", "added-by-hand.example"),
            PolEntry.Number(ChromeKey, "**del.DnsOverHttpsMode", 0),
            FirefoxException,
        ];
        Assert.Equal([WindowsUpdate, Homepage, FirefoxException, .. LocalGroupPolicy.Wanted(Normal)], LocalGroupPolicy.Merged(file, Normal));
    }

    [Fact]
    public void Merged_OwnedValueOfTheWrongType_IsRewritten()
    {
        var file = LocalGroupPolicy.Wanted(Normal).Select(entry => entry.Name == "SafeSitesFilterBehavior" && entry.Key == ChromeKey ? PolEntry.Text(ChromeKey, "SafeSitesFilterBehavior", "1") : entry).ToList();
        Assert.Equal(LocalGroupPolicy.Wanted(Normal), LocalGroupPolicy.Merged(file, Normal));
    }

    [Fact]
    public void Merged_ListMissingOneSite_IsRewrittenWithTheWholeList()
    {
        var wanted = LocalGroupPolicy.Wanted(Normal);
        var file = wanted.Where(entry => !(entry.Key.EndsWith(@"Chrome\URLBlocklist", StringComparison.OrdinalIgnoreCase) && entry.Name == "2")).ToList();
        Assert.Equal(wanted, LocalGroupPolicy.Merged(file, Normal));
    }

    [Fact]
    public void Merged_DelvalsAfterTheListValues_IsRewrittenInTheWantedOrder()
    {
        // Windows applies the entries in file order, so a delete-all entry after the values would empty the list it should refill.
        var wanted = LocalGroupPolicy.Wanted(Normal);
        int delvals = wanted.FindIndex(entry => entry.Key.Equals(ChromeKey + @"\URLBlocklist", StringComparison.OrdinalIgnoreCase) && entry.Name == "**delvals.");
        int values = wanted.Skip(delvals + 1).TakeWhile(entry => entry.Key.Equals(ChromeKey + @"\URLBlocklist", StringComparison.OrdinalIgnoreCase)).Count();
        Assert.Equal(2, values);
        List<PolEntry> file = [.. wanted[..delvals], .. wanted.Skip(delvals + 1).Take(values), wanted[delvals], .. wanted.Skip(delvals + 1 + values)];
        Assert.Equal(wanted.Count, file.Count);
        var merged = LocalGroupPolicy.Merged(file, Normal);
        Assert.NotNull(merged);
        Assert.Equal(wanted, merged);
    }

    [Fact]
    public void Merged_StrayOwnedListValueBesideTheWantedOnes_IsRemoved()
    {
        var wanted = LocalGroupPolicy.Wanted(Normal);
        int afterChromeList = wanted.FindLastIndex(entry => entry.Key.Equals(ChromeKey + @"\URLBlocklist", StringComparison.OrdinalIgnoreCase)) + 1;
        List<PolEntry> file = [.. wanted[..afterChromeList], PolEntry.Text(ChromeKey + @"\URLBlocklist", "1001", "added-by-hand.example"), .. wanted[afterChromeList..]];
        Assert.Equal(wanted, LocalGroupPolicy.Merged(file, Normal));
    }

    [Fact]
    public void Merged_Uninstall_LeavesOnlyTheOwnersEntriesInTheirOrder()
    {
        List<PolEntry> file = [WindowsUpdate, .. LocalGroupPolicy.Wanted(Normal), Homepage, FirefoxException];
        Assert.Equal([WindowsUpdate, Homepage, FirefoxException], LocalGroupPolicy.Merged(file, Uninstall));
    }

    [Fact]
    public void Merged_UninstallOfAFileWithOnlySiteBlocksEntries_IsEmptyNotNull()
    {
        var merged = LocalGroupPolicy.Merged(LocalGroupPolicy.Wanted(Normal), Uninstall);
        Assert.NotNull(merged);
        Assert.Empty(merged);
    }

    [Fact]
    public void Merged_UninstallOfAFileWithNoSiteBlockEntries_IsNull()
    {
        Assert.Null(LocalGroupPolicy.Merged([WindowsUpdate, Homepage], Uninstall));
    }

    // The [General] section of a gpt.ini text as key → value (names compared without letter case), checking along the way that every line ends with CRLF.
    private static Dictionary<string, string> General(string text)
    {
        Assert.EndsWith("\r\n", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\r\r", text, StringComparison.Ordinal);
        Assert.Equal(text.Count(c => c == '\n'), text.Count(c => c == '\r'));
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        bool inGeneral = false;
        foreach (string line in text.Split("\r\n"))
        {
            if (line.StartsWith('[') && line.EndsWith(']') && !line.Contains('=', StringComparison.Ordinal)) { inGeneral = line.Equals("[General]", StringComparison.OrdinalIgnoreCase); continue; }
            int equals = line.IndexOf('=', StringComparison.Ordinal);
            if (inGeneral && equals > 0) Assert.True(result.TryAdd(line[..equals].Trim(), line[(equals + 1)..].Trim()), "duplicate key in [General]: " + line);
        }
        return result;
    }

    private const string RegistryGroup = "[" + Registry + AdminTemplates + "]";

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void UpdatedGptIni_MissingOrEmptyFile_StartsAtVersionOneWithTheRegistryExtension(string? text)
    {
        var general = General(LocalGroupPolicy.UpdatedGptIni(text));
        Assert.Equal("1", general["Version"]);
        Assert.Equal(RegistryGroup, general["gPCMachineExtensionNames"]);
        Assert.Equal(2, general.Count);
    }

    [Fact]
    public void UpdatedGptIni_NoGeneralSection_AddsOneAndKeepsTheOtherSectionsLines()
    {
        string updated = LocalGroupPolicy.UpdatedGptIni("[Other]\r\nfoo=bar\r\n");
        var general = General(updated);
        Assert.Equal("1", general["Version"]);
        Assert.Equal(RegistryGroup, general["gPCMachineExtensionNames"]);
        Assert.False(general.ContainsKey("foo"));
        Assert.Contains("[Other]\r\nfoo=bar\r\n", updated, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(0u, 1u)]
    [InlineData(5u, 6u)]
    [InlineData(0x00030005u, 0x00030006u)]
    [InlineData(0x0002FFFFu, 0x00020001u)]
    [InlineData(0x0000FFFFu, 0x00000001u)]
    [InlineData(0xFFFFFFFFu, 0xFFFF0001u)]
    [InlineData(0x00010000u, 0x00010001u)]
    public void UpdatedGptIni_RaisesTheComputerHalfByOneKeepingTheUserHalfAndWrappingToOne(uint before, uint after)
    {
        string text = "[General]\r\nVersion=" + before + "\r\ngPCMachineExtensionNames=" + RegistryGroup + "\r\n";
        Assert.Equal(after.ToString(System.Globalization.CultureInfo.InvariantCulture), General(LocalGroupPolicy.UpdatedGptIni(text))["Version"]);
    }

    [Fact]
    public void UpdatedGptIni_OtherExtensionGroups_AreKeptAndSortedWithTheRegistryGroup()
    {
        const string security = "[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]";
        const string wireless = "[{0ACDD40C-75AC-47AB-BAA0-BF6DE7E7FE63}{2BFCC2CF-F1F3-4C33-8B9D-8C3B0B1F6D3A}]";
        string text = "[General]\r\nVersion=7\r\ngPCMachineExtensionNames=" + security + wireless + "\r\n";
        Assert.Equal(wireless + RegistryGroup + security, General(LocalGroupPolicy.UpdatedGptIni(text))["gPCMachineExtensionNames"]);
    }

    [Fact]
    public void UpdatedGptIni_RegistryGroupWithAnotherTool_GainsTheAdministrativeTemplatesToolInSortedOrder()
    {
        const string otherTool = "{0F6B957E-509E-11D1-A7CC-0000F87571E3}";
        string text = "[General]\r\nVersion=7\r\ngPCMachineExtensionNames=[" + Registry + otherTool + "]\r\n";
        Assert.Equal("[" + Registry + otherTool + AdminTemplates + "]", General(LocalGroupPolicy.UpdatedGptIni(text))["gPCMachineExtensionNames"]);
    }

    [Fact]
    public void UpdatedGptIni_RegistryGroupAlreadyThereInLowercase_IsNotListedTwice()
    {
        string text = "[General]\r\nVersion=7\r\ngPCMachineExtensionNames=" + RegistryGroup.ToLowerInvariant() + "\r\n";
        string names = General(LocalGroupPolicy.UpdatedGptIni(text))["gPCMachineExtensionNames"];
        Assert.Equal(RegistryGroup, names, ignoreCase: true);
    }

    [Fact]
    public void UpdatedGptIni_OtherLinesAreKeptInOrderAndLineEndsBecomeCrlf()
    {
        string text = "[General]\ndisplayName=Local Group Policy\nVersion=65541\noptions=0\n[Extra]\nkeep=me\n";
        string updated = LocalGroupPolicy.UpdatedGptIni(text);
        var general = General(updated);
        Assert.Equal("65542", general["Version"]);
        Assert.Equal("Local Group Policy", general["displayName"]);
        Assert.Equal("0", general["options"]);
        Assert.Equal(RegistryGroup, general["gPCMachineExtensionNames"]);
        Assert.True(updated.IndexOf("displayName=", StringComparison.Ordinal) < updated.IndexOf("options=0", StringComparison.Ordinal));
        Assert.EndsWith("[Extra]\r\nkeep=me\r\n", updated, StringComparison.Ordinal);
    }

    [Fact]
    public void UpdatedGptIni_KeysOfTheSameNameInAnotherSection_AreLeftAlone()
    {
        const string userNames = "gPCUserExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{0F6B957F-509E-11D1-A7CC-0000F87571E3}]";
        string text = "[General]\r\nVersion=3\r\n" + userNames + "\r\n[Extra]\r\nVersion=99\r\ngPCMachineExtensionNames=[{AAAAAAAA-0000-0000-0000-000000000000}]\r\n";
        string updated = LocalGroupPolicy.UpdatedGptIni(text);
        var general = General(updated);
        Assert.Equal("4", general["Version"]);
        Assert.Equal(RegistryGroup, general["gPCMachineExtensionNames"]);
        Assert.Contains(userNames + "\r\n", updated, StringComparison.Ordinal);
        Assert.EndsWith("[Extra]\r\nVersion=99\r\ngPCMachineExtensionNames=[{AAAAAAAA-0000-0000-0000-000000000000}]\r\n", updated, StringComparison.Ordinal);
    }

    [Fact]
    public void UpdatedGptIni_ExtensionNamesButNoVersionLine_AddsVersionOne()
    {
        var general = General(LocalGroupPolicy.UpdatedGptIni("[General]\r\ngPCMachineExtensionNames=" + RegistryGroup + "\r\n"));
        Assert.Equal("1", general["Version"]);
        Assert.Equal(RegistryGroup, general["gPCMachineExtensionNames"]);
        Assert.Equal(2, general.Count);
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("")]
    [InlineData("-3")]
    [InlineData("99999999999")]
    public void UpdatedGptIni_VersionThatIsNotANumber_CountsAsZeroAndBecomesOne(string version)
    {
        Assert.Equal("1", General(LocalGroupPolicy.UpdatedGptIni("[General]\r\nVersion=" + version + "\r\n"))["Version"]);
    }

    [Fact]
    public void UpdatedGptIni_SpacesAroundTheEqualsSign_AreTheSameKeysAndAreNotDuplicated()
    {
        const string security = "[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]";
        string updated = LocalGroupPolicy.UpdatedGptIni("[General]\r\n  Version = 7 \r\ngPCMachineExtensionNames = " + security + "\r\n");
        // General() fails on a key listed twice, so a second Version or gPCMachineExtensionNames line added beside the spaced one is caught here.
        var general = General(updated);
        Assert.Equal("8", general["Version"]);
        Assert.Equal(RegistryGroup + security, general["gPCMachineExtensionNames"]);
    }

    [Fact]
    public void UpdatedGptIni_AppliedTwice_RaisesTheVersionTwiceAndKeepsOneRegistryGroup()
    {
        string twice = LocalGroupPolicy.UpdatedGptIni(LocalGroupPolicy.UpdatedGptIni("[General]\r\nVersion=65536\r\n"));
        var general = General(twice);
        Assert.Equal("65538", general["Version"]);
        Assert.Equal(RegistryGroup, general["gPCMachineExtensionNames"]);
    }
}

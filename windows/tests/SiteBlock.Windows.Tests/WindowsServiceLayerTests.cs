using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;
using SiteBlock.Core;
using SiteBlock.Service;

namespace SiteBlock.Windows.Tests;

// A throwaway key under HKEY_CURRENT_USER\Software\SiteBlockTest, deleted on Dispose, so the tests never touch the machine-wide policy keys.
[SupportedOSPlatform("windows")]
internal sealed class ThrowawayRegistry : IDisposable
{
    public string Prefix { get; } = @"Software\SiteBlockTest\" + Guid.NewGuid().ToString("N");
    public RegistryPolicyStore Store { get; }

    public ThrowawayRegistry() => Store = new RegistryPolicyStore(RegistryHive.CurrentUser, Prefix);

    // Opens a key under the throwaway prefix for direct reads and hand edits (null when missing).
    public RegistryKey? Open(string keyPath, bool writable = false) => Registry.CurrentUser.OpenSubKey(Prefix + "\\" + keyPath, writable);

    // Creates a key under the throwaway prefix for hand edits.
    public RegistryKey Create(string keyPath) => Registry.CurrentUser.CreateSubKey(Prefix + "\\" + keyPath, writable: true);

    public void Dispose() => Registry.CurrentUser.DeleteSubKeyTree(Prefix, throwOnMissingSubKey: false);
}

// RegistryPolicyStore against the real registry. Expected values: 06-windows.md § SiteBlock.Core (Windows browser policy rules: REG_SZ and REG_DWORD, list values "1".."N",
// a value of the wrong type counts as wrong) and § BrowserPolicyEnforcer (a list subkey replaced as a whole, so a stray "1001" never survives).
[SupportedOSPlatform("windows")]
public sealed class RegistryPolicyStoreTests
{
    private const string Chrome = @"SOFTWARE\Policies\Google\Chrome";

    [Fact]
    public void SetValue_ThenReadValues_GivesBackTheTypedValuesAndCreatesTheKey()
    {
        using var registry = new ThrowawayRegistry();

        registry.Store.SetValue(Chrome, "DnsOverHttpsMode", RegValue.Str("off"));
        registry.Store.SetValue(Chrome, "SafeSitesFilterBehavior", RegValue.DWord(1));

        var values = registry.Store.ReadValues(Chrome)!;
        Assert.Equal(RegValue.Str("off"), values["DnsOverHttpsMode"]);
        Assert.Equal(RegValue.DWord(1), values["SafeSitesFilterBehavior"]);
        using var key = registry.Open(Chrome)!;
        Assert.Equal(RegistryValueKind.String, key.GetValueKind("DnsOverHttpsMode"));
        Assert.Equal(RegistryValueKind.DWord, key.GetValueKind("SafeSitesFilterBehavior"));
    }

    [Fact]
    public void ReadValues_MissingKey_IsNullAndKeyChecksAgree()
    {
        using var registry = new ThrowawayRegistry();

        Assert.Null(registry.Store.ReadValues(Chrome));
        Assert.False(registry.Store.KeyExists(Chrome));
        Assert.False(registry.Store.KeyIsEmpty(Chrome));
    }

    [Fact]
    public void ReadValues_ValuesOfOtherRegistryTypes_NeverEqualAWantedValue()
    {
        using var registry = new ThrowawayRegistry();
        using (var key = registry.Create(Chrome))
        {
            key.SetValue("AsText", "1", RegistryValueKind.String);
            key.SetValue("AsQword", 1L, RegistryValueKind.QWord);
            key.SetValue("AsExpand", "off", RegistryValueKind.ExpandString);
            key.SetValue("AsBinary", new byte[] { 1, 0, 0, 0 }, RegistryValueKind.Binary);
            key.SetValue("AsMulti", new[] { "off" }, RegistryValueKind.MultiString);
        }

        var values = registry.Store.ReadValues(Chrome)!;

        Assert.NotEqual(RegValue.DWord(1), values["AsText"]);
        Assert.Equal(RegValue.Str("1"), values["AsText"]);
        Assert.NotEqual(RegValue.DWord(1), values["AsQword"]);
        Assert.NotEqual(RegValue.Str("off"), values["AsExpand"]);
        Assert.NotEqual(RegValue.DWord(1), values["AsBinary"]);
        Assert.NotEqual(RegValue.Str("off"), values["AsMulti"]);
    }

    [Fact]
    public void KeyNames_AreComparedWithoutRegardToLetterCase()
    {
        using var registry = new ThrowawayRegistry();
        registry.Store.SetValue(Chrome, "ForceGoogleSafeSearch", RegValue.DWord(1));

        Assert.True(registry.Store.KeyExists(Chrome.ToLowerInvariant()));
        Assert.Equal(RegValue.DWord(1), registry.Store.ReadValues(Chrome.ToUpperInvariant())!["forcegooglesafesearch"]);
    }

    [Fact]
    public void ReplaceList_OverAnOldLongerListWithStrayValuesAndSubkeys_LeavesExactlyOneToN()
    {
        using var registry = new ThrowawayRegistry();
        string list = Chrome + @"\URLBlocklist";
        using (var key = registry.Create(list))
        {
            for (int i = 1; i <= 5; i++) key.SetValue(i.ToString(System.Globalization.CultureInfo.InvariantCulture), $"old{i}.example");
            key.SetValue("1001", "*");
            key.SetValue("2", 7, RegistryValueKind.DWord);
            key.CreateSubKey("Nested")!.Dispose();
        }

        registry.Store.ReplaceList(list, ["a.example", "b.example"]);

        var values = registry.Store.ReadValues(list)!;
        Assert.Equal(2, values.Count);
        Assert.Equal(RegValue.Str("a.example"), values["1"]);
        Assert.Equal(RegValue.Str("b.example"), values["2"]);
        using var after = registry.Open(list)!;
        Assert.Empty(after.GetSubKeyNames());
        Assert.True(WindowsBrowserPolicy.ListMatches(["a.example", "b.example"], values));
    }

    [Fact]
    public void DeleteValueAndDeleteKey_AreFineWhenMissingAndDeleteTheWholeTree()
    {
        using var registry = new ThrowawayRegistry();
        registry.Store.DeleteValue(Chrome, "Nothing");
        registry.Store.DeleteKey(Chrome);
        registry.Store.ReplaceList(Chrome + @"\URLBlocklist", ["a.example"]);
        registry.Store.SetValue(Chrome, "HomepageLocation", RegValue.Str("https://example.org"));

        registry.Store.DeleteValue(Chrome, "HomepageLocation");
        Assert.False(registry.Store.ReadValues(Chrome)!.ContainsKey("HomepageLocation"));
        Assert.False(registry.Store.KeyIsEmpty(Chrome));

        registry.Store.DeleteKey(Chrome);
        Assert.False(registry.Store.KeyExists(Chrome));
        Assert.False(registry.Store.KeyExists(Chrome + @"\URLBlocklist"));
    }

    [Fact]
    public void KeyIsEmpty_IsTrueOnlyWithNoValuesAndNoSubkeys()
    {
        using var registry = new ThrowawayRegistry();
        registry.Create(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter").Dispose();

        Assert.True(registry.Store.KeyIsEmpty(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter"));
        Assert.False(registry.Store.KeyIsEmpty(@"SOFTWARE\Policies\Mozilla\Firefox"));
    }
}

// BrowserPolicyEnforcer over a RegistryPolicyStore in a throwaway key. Expected values: 06-windows.md § SiteBlock.Core (keys, values, types, list subkeys) and § BrowserPolicyEnforcer
// (rewrite only what differs, "browser policy repaired (<browser>)" for changes no command asked for, values and subkeys SiteBlock does not own never changed,
// the uninstall pass removes every owned value and list subkey and deletes a policy key left empty).
[SupportedOSPlatform("windows")]
public sealed class BrowserPolicyEnforcerTests : IDisposable
{
    private readonly ThrowawayRegistry _registry = new();
    private readonly string _logPath = Path.Combine(Path.GetTempPath(), "sbq-bpe-" + Guid.NewGuid().ToString("N") + ".log");
    private readonly BrowserPolicyEnforcer _enforcer;

    private static readonly BrowserBlockLists Lists = new(["redd.it", "reddit.com"], ["youtube.com/shorts"], ["*://*.redd.it/*", "*://*.reddit.com/*"], ["*://*.youtube.com/shorts*"]);

    public BrowserPolicyEnforcerTests() => _enforcer = new BrowserPolicyEnforcer(_registry.Store, new Log(_logPath));

    public void Dispose()
    {
        _registry.Dispose();
        try { File.Delete(_logPath); } catch (IOException) { }
    }

    private string LogText() => File.Exists(_logPath) ? File.ReadAllText(_logPath) : "";

    // The value names and data of a key under the throwaway prefix, with their registry kinds.
    private Dictionary<string, (RegistryValueKind Kind, object? Data)> Read(string keyPath)
    {
        using var key = _registry.Open(keyPath) ?? throw new Xunit.Sdk.XunitException(keyPath + " is missing");
        return key.GetValueNames().ToDictionary(name => name, name => (key.GetValueKind(name), key.GetValue(name)), StringComparer.OrdinalIgnoreCase);
    }

    [Fact]
    public void Enforce_OnAnEmptyRegistry_WritesEveryBrowsersDocumentedValuesAndLists()
    {
        Assert.True(_enforcer.Enforce(Lists, adultFilter: true, causedByCommand: true));

        var chrome = Read(@"SOFTWARE\Policies\Google\Chrome");
        Assert.Equal((RegistryValueKind.DWord, (object?)1), chrome["SafeSitesFilterBehavior"]);
        Assert.Equal((RegistryValueKind.DWord, (object?)1), chrome["ForceGoogleSafeSearch"]);
        Assert.Equal((RegistryValueKind.String, (object?)"off"), chrome["DnsOverHttpsMode"]);
        var edge = Read(@"SOFTWARE\Policies\Microsoft\Edge");
        Assert.Equal((RegistryValueKind.DWord, (object?)2), edge["ForceBingSafeSearch"]);
        Assert.False(edge.ContainsKey("SafeSitesFilterBehavior"));
        var brave = Read(@"SOFTWARE\Policies\BraveSoftware\Brave");
        Assert.Equal((RegistryValueKind.DWord, (object?)1), brave["SafeSitesFilterBehavior"]);
        var firefoxDns = Read(@"SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS");
        Assert.Equal((RegistryValueKind.DWord, (object?)0), firefoxDns["Enabled"]);
        Assert.Equal((RegistryValueKind.DWord, (object?)1), firefoxDns["Locked"]);
        foreach (string key in new[] { @"SOFTWARE\Policies\Google\Chrome\URLBlocklist", @"SOFTWARE\Policies\Microsoft\Edge\URLBlocklist", @"SOFTWARE\Policies\BraveSoftware\Brave\URLBlocklist" })
        {
            var list = Read(key);
            Assert.Equal(3, list.Count);
            Assert.Equal((RegistryValueKind.String, (object?)"redd.it"), list["1"]);
            Assert.Equal((RegistryValueKind.String, (object?)"youtube.com/shorts"), list["3"]);
        }
        var firefoxList = Read(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block");
        Assert.Equal((RegistryValueKind.String, (object?)"*://*.youtube.com/shorts*"), firefoxList["3"]);
        Assert.DoesNotContain("repaired", LogText());
    }

    [Fact]
    public void Enforce_ASecondPassWithNothingWrong_ChangesAndLogsNothing()
    {
        _enforcer.Enforce(Lists, adultFilter: true, causedByCommand: true);

        Assert.True(_enforcer.Enforce(Lists, adultFilter: true, causedByCommand: false));

        Assert.DoesNotContain("repaired", LogText());
    }

    [Fact]
    public void Enforce_ValueOfTheWrongTypeAndAStrayListValue_AreRepairedAndLogged()
    {
        _enforcer.Enforce(Lists, adultFilter: true, causedByCommand: true);
        using (var chrome = _registry.Open(@"SOFTWARE\Policies\Google\Chrome", writable: true)!) chrome.SetValue("SafeSitesFilterBehavior", "1", RegistryValueKind.String);
        using (var list = _registry.Open(@"SOFTWARE\Policies\Microsoft\Edge\URLBlocklist", writable: true)!) list.SetValue("1001", "allowed.example");

        Assert.True(_enforcer.Enforce(Lists, adultFilter: true, causedByCommand: false));

        Assert.Equal((RegistryValueKind.DWord, (object?)1), Read(@"SOFTWARE\Policies\Google\Chrome")["SafeSitesFilterBehavior"]);
        var edgeList = Read(@"SOFTWARE\Policies\Microsoft\Edge\URLBlocklist");
        Assert.Equal(3, edgeList.Count);
        Assert.False(edgeList.ContainsKey("1001"));
        Assert.Contains("browser policy repaired (Chrome)", LogText());
        Assert.Contains("browser policy repaired (Edge)", LogText());
        Assert.DoesNotContain("browser policy repaired (Brave)", LogText());
    }

    [Fact]
    public void Enforce_ValuesAndSubkeysSiteBlockDoesNotOwn_AreKeptThroughRepairAndUninstall()
    {
        using (var chrome = _registry.Create(@"SOFTWARE\Policies\Google\Chrome")) chrome.SetValue("HomepageLocation", "https://intranet.example.org");
        using (var exceptions = _registry.Create(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Exceptions")) exceptions.SetValue("1", "https://intranet.example.org/*");

        _enforcer.Enforce(Lists, adultFilter: true, causedByCommand: true);
        _enforcer.Enforce(BrowserBlockLists.Empty, adultFilter: false, causedByCommand: true);

        var chromeAfter = Read(@"SOFTWARE\Policies\Google\Chrome");
        Assert.Equal(["HomepageLocation"], chromeAfter.Keys);
        Assert.Null(_registry.Open(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist"));
        Assert.Equal((RegistryValueKind.String, (object?)"https://intranet.example.org/*"), Read(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Exceptions")["1"]);
        Assert.Null(_registry.Open(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block"));
        Assert.Null(_registry.Open(@"SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS"));
    }

    [Fact]
    public void Enforce_UninstallPass_RemovesEveryOwnedValueAndDeletesKeysLeftEmpty()
    {
        _enforcer.Enforce(Lists, adultFilter: true, causedByCommand: true);

        Assert.True(_enforcer.Enforce(BrowserBlockLists.Empty, adultFilter: false, causedByCommand: true));

        Assert.Null(_registry.Open(@"SOFTWARE\Policies\Google\Chrome"));
        Assert.Null(_registry.Open(@"SOFTWARE\Policies\Microsoft\Edge"));
        Assert.Null(_registry.Open(@"SOFTWARE\Policies\BraveSoftware\Brave"));
        Assert.Null(_registry.Open(@"SOFTWARE\Policies\Mozilla\Firefox"));
    }

    [Fact]
    public void Enforce_ListShrinks_TheOldTailValuesAreGone()
    {
        _enforcer.Enforce(Lists, adultFilter: true, causedByCommand: true);

        _enforcer.Enforce(new BrowserBlockLists(["reddit.com"], [], ["*://*.reddit.com/*"], []), adultFilter: true, causedByCommand: true);

        var chromeList = Read(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist");
        Assert.Equal(["1"], chromeList.Keys);
        Assert.Equal((RegistryValueKind.String, (object?)"reddit.com"), chromeList["1"]);
    }
}

// WindowsDnsBackend in read-only mode: it lists adapters and reads their servers, and nothing here ever calls Apply. Expected values: 06-windows.md § DNSEnforcer
// (Ethernet and Wi-Fi adapters that are not loopback, keyed by GUID; static servers from NameServer, IPv4 first, then IPv6; empty when the adapter takes them from the network).
[SupportedOSPlatform("windows")]
public sealed class WindowsDnsBackendTests
{
    [Fact]
    public void ReadAdapters_ListsGuidKeyedAdaptersWithParsableServersIpv4First()
    {
        var adapters = new WindowsDnsBackend().ReadAdapters();

        Assert.Equal(adapters.Count, adapters.Select(adapter => adapter.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count());
        foreach (var adapter in adapters)
        {
            Assert.True(Guid.TryParse(adapter.Id, out _), $"adapter id {adapter.Id} is not a GUID");
            Assert.NotEqual("Loopback", adapter.InterfaceType);
            foreach (string server in adapter.Servers) Assert.True(IPAddress.TryParse(server, out _), $"{adapter.Name}: '{server}' is not an address");
            var families = adapter.Servers.Select(server => IPAddress.Parse(server).AddressFamily).ToList();
            int firstV6 = families.IndexOf(AddressFamily.InterNetworkV6);
            if (firstV6 >= 0) Assert.DoesNotContain(AddressFamily.InterNetwork, families.Skip(firstV6));
        }
    }

    [Fact]
    public void ReadAdapters_SkipsNoUsableEthernetAdapterOnARealMachine()
    {
        // A GitHub Windows runner has at least one Ethernet adapter that is up.
        bool anyEthernetUp = System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
            .Any(nic => nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Ethernet && nic.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up);

        var adapters = new WindowsDnsBackend().ReadAdapters();

        if (anyEthernetUp) Assert.Contains(adapters, adapter => adapter.InterfaceType == "Ethernet");
        Assert.All(adapters, adapter => Assert.Contains(adapter.InterfaceType, new[] { "Ethernet", "Wireless80211", "Tunnel", "Ppp" }));
    }

    [Theory]
    [InlineData("WireGuard Tunnel")]
    [InlineData("TAP-Windows Adapter V9")]
    [InlineData("Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter")]
    [InlineData("tailscale tunnel")]
    [InlineData("Cloudflare WARP Interface Tunnel")]
    public void VpnDescriptions_AreSkipped(string description)
    {
        Assert.False(new DnsAdapter("{4D36E972-E325-11CE-BFC1-08002BE10318}", "x", "Ethernet", description, true, []).IsManaged);
    }

    [Fact]
    public void PlainEthernetAndWifi_AreManagedAndTunnelsAreNot()
    {
        Assert.True(new DnsAdapter("{4D36E972-E325-11CE-BFC1-08002BE10318}", "Ethernet", "Ethernet", "Intel(R) Ethernet Connection", true, []).IsManaged);
        Assert.True(new DnsAdapter("{4D36E972-E325-11CE-BFC1-08002BE10319}", "Wi-Fi", "Wireless80211", "Intel(R) Wi-Fi 6 AX201", true, []).IsManaged);
        Assert.False(new DnsAdapter("{4D36E972-E325-11CE-BFC1-08002BE10320}", "t", "Tunnel", "Microsoft Teredo", true, []).IsManaged);
        Assert.False(new DnsAdapter("{4D36E972-E325-11CE-BFC1-08002BE10321}", "p", "Ppp", "WAN Miniport", true, []).IsManaged);
    }
}

// The pipe's access list. Expected values: 06-windows.md § PipeServer step 2 (Authenticated Users get read data, write data, read attributes, read extended attributes and
// read permissions and never the right to create a new instance; SYSTEM and Administrators full control; everything denied to NETWORK).
[SupportedOSPlatform("windows")]
public sealed class PipeSecurityTests
{
    private static List<PipeAccessRule> Rules(bool sandbox) =>
        PipeServer.BuildSecurity(sandbox).GetAccessRules(includeExplicit: true, includeInherited: true, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToList();

    private static SecurityIdentifier Sid(WellKnownSidType type) => new(type, null);

    private const PipeAccessRights ClientRights = PipeAccessRights.ReadData | PipeAccessRights.WriteData | PipeAccessRights.ReadAttributes | PipeAccessRights.ReadExtendedAttributes | PipeAccessRights.ReadPermissions;

    [Fact]
    public void Production_HasExactlyTheFourDocumentedRules()
    {
        var rules = Rules(sandbox: false);

        Assert.Equal(4, rules.Count);
        var network = Assert.Single(rules, rule => rule.IdentityReference.Equals(Sid(WellKnownSidType.NetworkSid)));
        Assert.Equal(AccessControlType.Deny, network.AccessControlType);
        // .NET leaves Synchronize out of a deny rule; every other right is denied.
        Assert.Equal(PipeAccessRights.FullControl & ~PipeAccessRights.Synchronize, network.PipeAccessRights & ~PipeAccessRights.Synchronize);
        foreach (var admin in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
        {
            var rule = Assert.Single(rules, rule => rule.IdentityReference.Equals(Sid(admin)));
            Assert.Equal(AccessControlType.Allow, rule.AccessControlType);
            Assert.Equal(PipeAccessRights.FullControl, rule.PipeAccessRights & PipeAccessRights.FullControl);
        }
    }

    [Fact]
    public void AuthenticatedUsers_GetOnlyReadWriteAndReadPermissionsNeverCreateNewInstance()
    {
        var rule = Assert.Single(Rules(sandbox: false), rule => rule.IdentityReference.Equals(Sid(WellKnownSidType.AuthenticatedUserSid)));

        Assert.Equal(AccessControlType.Allow, rule.AccessControlType);
        Assert.Equal((PipeAccessRights)0, rule.PipeAccessRights & PipeAccessRights.CreateNewInstance);
        Assert.Equal(PipeAccessRights.ReadData | PipeAccessRights.WriteData, rule.PipeAccessRights & (PipeAccessRights.ReadData | PipeAccessRights.WriteData));
        // Nothing beyond the five documented rights (Synchronize is added by Windows to every allow rule and is harmless).
        Assert.Equal((PipeAccessRights)0, rule.PipeAccessRights & ~ClientRights & ~PipeAccessRights.Synchronize);
        Assert.Equal((PipeAccessRights)0, rule.PipeAccessRights & (PipeAccessRights.ChangePermissions | PipeAccessRights.TakeOwnership | PipeAccessRights.Delete));
    }

    [Fact]
    public void Sandbox_AddsFullControlForTheRunningAccountOnly()
    {
        using var self = WindowsIdentity.GetCurrent();

        var rules = Rules(sandbox: true);

        Assert.Equal(5, rules.Count);
        var mine = Assert.Single(rules, rule => rule.IdentityReference.Equals(self.User));
        Assert.Equal(AccessControlType.Allow, mine.AccessControlType);
    }
}

// Removing the program folder from the system PATH text. Expected values: 06-windows.md § Uninstaller step 5 (delete the folder's entry in the system PATH);
// entries are folders, which Windows compares without regard to letter case or a trailing backslash, and every other entry is kept as written.
[SupportedOSPlatform("windows")]
public sealed class PathEntryTests
{
    private const string Folder = @"C:\Program Files\SiteBlock";

    [Fact]
    public void WithoutEntry_RemovesTheFolderAndKeepsEveryOtherEntryAsWritten()
    {
        Assert.Equal(@"%SystemRoot%\system32;%SystemRoot%;C:\Tools", Uninstaller.WithoutEntry(@"%SystemRoot%\system32;%SystemRoot%;C:\Program Files\SiteBlock;C:\Tools", Folder));
    }

    [Theory]
    [InlineData(@"C:\program files\siteblock")]
    [InlineData(@"C:\Program Files\SiteBlock\")]
    [InlineData(@" C:\Program Files\SiteBlock ")]
    public void WithoutEntry_LetterCaseTrailingBackslashAndSpaces_StillMatch(string entry)
    {
        Assert.Equal(@"C:\A;C:\B", Uninstaller.WithoutEntry($@"C:\A;{entry};C:\B", Folder));
    }

    [Fact]
    public void WithoutEntry_EveryCopyIsRemoved()
    {
        Assert.Equal(@"C:\A", Uninstaller.WithoutEntry(@"C:\Program Files\SiteBlock;C:\A;C:\Program Files\SiteBlock\", Folder));
    }

    [Fact]
    public void WithoutEntry_LookAlikeFoldersAreKeptAndNothingToRemoveIsNull()
    {
        const string path = @"C:\Program Files\SiteBlock2;C:\Program Files\SiteBlock\bin;D:\Program Files\SiteBlock;C:\Program Files";

        Assert.Null(Uninstaller.WithoutEntry(path, Folder));
        Assert.Null(Uninstaller.WithoutEntry("", Folder));
    }

    [Fact]
    public void WithoutEntry_TheOnlyEntry_LeavesAnEmptyPath()
    {
        Assert.Equal("", Uninstaller.WithoutEntry(Folder, Folder));
    }

    [Fact]
    public void WithoutEntry_FolderGivenWithATrailingBackslash_StillMatches()
    {
        Assert.Equal(@"C:\A", Uninstaller.WithoutEntry(@"C:\A;C:\Program Files\SiteBlock", Folder + @"\"));
    }
}

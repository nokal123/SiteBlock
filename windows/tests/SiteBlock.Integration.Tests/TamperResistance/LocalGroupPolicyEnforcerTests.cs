using System.Text;
using SiteBlock.Core;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// The Local Group Policy copy kept by BrowserPolicyEnforcer, run in-process on real files in a temporary sandbox folder with the sandbox's FilePolicyStore and FilePolicyRefresher.
// Expected values come from 06-windows.md § BrowserPolicyEnforcer (Local Group Policy copy steps 1 to 4; "Asking Windows to apply the policy": at most once every 5 seconds, a change
// inside that time is refreshed by the first pass after it, the time is taken before the call, a failed request is logged at most once a minute and tried again by a later pass, the
// success line; the uninstall pass) and § Installed Paths and Permissions (Sandbox: root/GroupPolicy/Machine/Registry.pol, root/GroupPolicy/gpt.ini, root/policy-refreshes.log).
// The refresh clock is injected (milliseconds), so no test waits on real time.
public sealed class LocalGroupPolicyEnforcerTests : IDisposable
{
    private const string ChromeList = @"SOFTWARE\Policies\Google\Chrome\URLBlocklist";
    private const string RefreshedLine = "asked Windows to apply the Local Group Policy, so running browsers read the new block lists";
    private static readonly BrowserBlockLists Reddit = new(["reddit.com"], [], ["*://*.reddit.com/*"], []);
    private static readonly BrowserBlockLists RedditAndX = new(["reddit.com", "x.com"], [], ["*://*.reddit.com/*", "*://*.x.com/*"], []);
    private static readonly PolEntry WindowsUpdate = PolEntry.Number(@"Software\Policies\Microsoft\Windows\WindowsUpdate\AU", "NoAutoUpdate", 1);
    private static readonly PolEntry Homepage = PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome", "HomepageLocation", "https://intranet.example");
    private static readonly PolEntry FirefoxException = PolEntry.Text(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Exceptions", "1", "*://*.school.example/*");

    private readonly TempSandbox _sandbox = new();
    private long _now;

    public void Dispose() => _sandbox.Dispose();

    private string PolFile => _sandbox.Paths.LocalPolicyFile;
    private string IniFile => _sandbox.Paths.LocalPolicyIni;

    private BrowserPolicyEnforcer Make(IPolicyRefresher? refresher = null) =>
        new(new FilePolicyStore(_sandbox.Paths.RegistryFile), refresher ?? new FilePolicyRefresher(_sandbox.Paths.PolicyRefreshLog), _sandbox.Log, PolFile, IniFile, () => _now);

    private int Refreshes => File.Exists(_sandbox.Paths.PolicyRefreshLog) ? File.ReadAllLines(_sandbox.Paths.PolicyRefreshLog).Count(line => line == "refresh") : 0;

    // Log lines about the Local Group Policy other than the success line: the design gives their meaning but not their words.
    private List<string> FailureLines() => [.. _sandbox.LogMessages().Where(line => line.Contains("Local Group Policy", StringComparison.Ordinal) && line != RefreshedLine)];

    private List<PolEntry> ReadPol() => RegistryPol.Parse(File.ReadAllBytes(PolFile));

    // The Version value of gpt.ini's [General] section.
    private uint IniVersion() => uint.Parse(File.ReadAllLines(IniFile).Single(line => line.StartsWith("Version=", StringComparison.OrdinalIgnoreCase))["Version=".Length..], System.Globalization.CultureInfo.InvariantCulture);

    // A refresher that throws on the calls the test chooses and counts every call.
    private sealed class ScriptedRefresher(Func<int, bool> failsOnCall) : IPolicyRefresher
    {
        public int Calls { get; private set; }

        public void Refresh()
        {
            Calls++;
            if (failsOnCall(Calls)) throw new IOException("the refresh request was refused");
        }
    }

    [Fact]
    public void SandboxPaths_PutTheLocalPolicyFilesAndTheRefreshLogUnderTheRoot()
    {
        string root = _sandbox.Root;
        Assert.Equal(Path.Combine(root, "GroupPolicy", "Machine", "Registry.pol"), _sandbox.Paths.LocalPolicyFile);
        Assert.Equal(Path.Combine(root, "GroupPolicy", "gpt.ini"), _sandbox.Paths.LocalPolicyIni);
        Assert.Equal(Path.Combine(root, "policy-refreshes.log"), _sandbox.Paths.PolicyRefreshLog);
    }

    [Fact]
    public void FirstPass_WritesRegistryPolAndGptIniAndAsksForOneRefresh()
    {
        Make().Enforce(Reddit, adultFilter: true, causedByCommand: false);

        var entries = ReadPol();
        int delvals = entries.FindIndex(entry => entry.Key.Equals(ChromeList, StringComparison.OrdinalIgnoreCase) && entry.Name == "**delvals.");
        Assert.True(delvals >= 0);
        Assert.Equal(PolEntry.Text(ChromeList, "1", "reddit.com"), entries[delvals + 1]);
        Assert.Contains(PolEntry.Text(@"SOFTWARE\Policies\Google\Chrome", "DnsOverHttpsMode", "off"), entries);
        Assert.Contains(PolEntry.Text(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block", "1", "*://*.reddit.com/*"), entries);
        Assert.Equal(1u, IniVersion());
        Assert.Contains("gPCMachineExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]", File.ReadAllText(IniFile), StringComparison.Ordinal);
        Assert.Equal(1, Refreshes);
        Assert.Equal(1, _sandbox.LogMessages().Count(line => line == RefreshedLine));
    }

    [Fact]
    public void FirstPass_LeavesNoTemporaryFileBesideEitherFile()
    {
        Make().Enforce(Reddit, true, false);
        var leftovers = Directory.GetFiles(Path.Combine(_sandbox.Root, "GroupPolicy"), "*", SearchOption.AllDirectories).Select(Path.GetFileName).Order(StringComparer.Ordinal);
        Assert.Equal(["Registry.pol", "gpt.ini"], leftovers);
    }

    [Fact]
    public void SecondPassWithNothingChanged_WritesNeitherFileAndAsksForNoRefresh()
    {
        var enforcer = Make();
        enforcer.Enforce(Reddit, true, false);
        byte[] pol = File.ReadAllBytes(PolFile);
        byte[] ini = File.ReadAllBytes(IniFile);
        DateTime polTime = File.GetLastWriteTimeUtc(PolFile);
        DateTime iniTime = File.GetLastWriteTimeUtc(IniFile);
        Thread.Sleep(20);

        for (int i = 1; i <= 5; i++)
        {
            _now = i * 60_000;
            enforcer.Enforce(Reddit, true, false);
        }

        Assert.Equal(pol, File.ReadAllBytes(PolFile));
        Assert.Equal(ini, File.ReadAllBytes(IniFile));
        Assert.Equal(polTime, File.GetLastWriteTimeUtc(PolFile));
        Assert.Equal(iniTime, File.GetLastWriteTimeUtc(IniFile));
        Assert.Equal(1, Refreshes);
    }

    [Fact]
    public void ChangeWithinFiveSecondsOfARefresh_IsWrittenAtOnceAndRefreshedByTheFirstPassAfterFiveSeconds()
    {
        var enforcer = Make();
        enforcer.Enforce(Reddit, true, false);
        Assert.Equal(1, Refreshes);

        _now = 2_000;
        enforcer.Enforce(RedditAndX, true, causedByCommand: true);
        // The file holds the new site at once, and its version went up, but the request waits for the interval.
        Assert.Contains(PolEntry.Text(ChromeList, "2", "x.com"), ReadPol());
        Assert.Equal(2u, IniVersion());
        Assert.Equal(1, Refreshes);

        _now = 4_999;
        enforcer.Enforce(RedditAndX, true, false);
        Assert.Equal(1, Refreshes);

        _now = 5_000;
        enforcer.Enforce(RedditAndX, true, false);
        Assert.Equal(2, Refreshes);

        // Nothing is waiting any more, so later passes ask for nothing, and the file was not written again.
        _now = 20_000;
        enforcer.Enforce(RedditAndX, true, false);
        Assert.Equal(2, Refreshes);
        Assert.Equal(2u, IniVersion());
    }

    [Fact]
    public void TwoChangesInsideTheInterval_GiveOneRefreshAfterIt()
    {
        var enforcer = Make();
        enforcer.Enforce(Reddit, true, false);
        _now = 1_000;
        enforcer.Enforce(RedditAndX, true, true);
        _now = 2_000;
        enforcer.Enforce(Reddit, true, true);
        Assert.Equal(1, Refreshes);
        Assert.Equal(3u, IniVersion());
        _now = 6_000;
        enforcer.Enforce(Reddit, true, false);
        _now = 7_000;
        enforcer.Enforce(Reddit, true, false);
        Assert.Equal(2, Refreshes);
    }

    [Fact]
    public void MalformedRegistryPol_IsLeftByteForByteWithNoGptIniChangeAndNoRefresh()
    {
        byte[] damaged = [.. "PReg"u8, 1, 0, 0, 0, .. Encoding.Unicode.GetBytes("[SOFTWARE\\Owner\0;Setting\0;"), 0x01];
        Directory.CreateDirectory(Path.GetDirectoryName(PolFile)!);
        File.WriteAllBytes(PolFile, damaged);
        const string ini = "[General]\r\nVersion=65541\r\ndisplayName=Owner policy\r\n";
        File.WriteAllText(IniFile, ini);

        var enforcer = Make();
        enforcer.Enforce(Reddit, true, false);
        _now = 10_000;
        enforcer.Enforce(Reddit, true, false);

        Assert.Equal(damaged, File.ReadAllBytes(PolFile));
        Assert.Equal(ini, File.ReadAllText(IniFile));
        Assert.Equal(0, Refreshes);
        Assert.Contains(_sandbox.LogMessages(), line => line.Contains("Local Group Policy", StringComparison.Ordinal) && line.Contains("could not be read", StringComparison.Ordinal));
        // The registry pass ran before the policy file and is not held back by it.
        Assert.Contains("reddit.com", File.ReadAllText(_sandbox.Paths.RegistryFile), StringComparison.Ordinal);
    }

    [Fact]
    public void OwnersEntriesAndGptIniLines_SurviveAndStaleSiteBlockEntriesAreReplaced()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PolFile)!);
        var stale = PolEntry.Text(ChromeList, "1", "old.example");
        File.WriteAllBytes(PolFile, RegistryPol.Serialize([WindowsUpdate, stale, Homepage, FirefoxException]));
        File.WriteAllText(IniFile, "[General]\r\ngPCMachineExtensionNames=[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]\r\nVersion=131077\r\ndisplayName=Owner policy\r\n");

        Make().Enforce(Reddit, true, false);

        var entries = ReadPol();
        Assert.Equal([WindowsUpdate, Homepage, FirefoxException], entries.Take(3));
        Assert.DoesNotContain(stale, entries);
        Assert.Contains(PolEntry.Text(ChromeList, "1", "reddit.com"), entries);
        string text = File.ReadAllText(IniFile);
        Assert.Equal(131078u, IniVersion());
        Assert.Contains("displayName=Owner policy\r\n", text, StringComparison.Ordinal);
        Assert.Contains("gPCMachineExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}][{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]\r\n", text, StringComparison.Ordinal);
        Assert.Equal(1, Refreshes);
    }

    [Fact]
    public void RegistryRepairAlone_DoesNotRewriteThePolicyFileOrAskForARefresh()
    {
        var enforcer = Make();
        enforcer.Enforce(Reddit, true, false);
        byte[] pol = File.ReadAllBytes(PolFile);
        // Someone empties the registry copy by hand; the policy file is still right.
        File.WriteAllText(_sandbox.Paths.RegistryFile, "{}");

        _now = 10_000;
        enforcer.Enforce(Reddit, true, false);

        Assert.Contains("reddit.com", File.ReadAllText(_sandbox.Paths.RegistryFile), StringComparison.Ordinal);
        Assert.Equal(pol, File.ReadAllBytes(PolFile));
        Assert.Equal(1, Refreshes);
    }

    [Fact]
    public void RefresherThatThrows_IsTriedAgainByALaterPassAfterTheInterval()
    {
        var refresher = new ScriptedRefresher(call => call == 1);
        var enforcer = Make(refresher);
        enforcer.Enforce(Reddit, true, false);
        Assert.Equal(1, refresher.Calls);
        Assert.DoesNotContain(RefreshedLine, _sandbox.LogMessages());
        Assert.Single(FailureLines());

        // The failed request also waits out the 5 seconds, because its time was taken before the call.
        _now = 4_000;
        enforcer.Enforce(Reddit, true, false);
        Assert.Equal(1, refresher.Calls);

        _now = 5_000;
        enforcer.Enforce(Reddit, true, false);
        Assert.Equal(2, refresher.Calls);
        Assert.Contains(RefreshedLine, _sandbox.LogMessages());

        _now = 30_000;
        enforcer.Enforce(Reddit, true, false);
        Assert.Equal(2, refresher.Calls);
    }

    [Theory]
    [InlineData(2_000)]
    [InlineData(5_000)]
    public void RefresherThatKeepsFailing_IsLoggedOnceInItsFirstMinute(int stepMs)
    {
        var refresher = new ScriptedRefresher(_ => true);
        var enforcer = Make(refresher);
        // Passes stepMs apart (2 seconds is the service's own cadence) from 0 to 58 seconds on the injected clock, so all of them fall inside one minute of the first failure.
        for (_now = 0; _now <= 58_000; _now += stepMs) enforcer.Enforce(Reddit, true, false);
        // Positive control: the request really was tried again at every pass at least 5 seconds after the previous try (0, 6, 12 … s with 2-second steps; 0, 5, 10 … s with 5-second steps).
        Assert.Equal(stepMs == 2_000 ? 10 : 12, refresher.Calls);
        Assert.Single(FailureLines());
    }

    [Fact]
    public void MalformedRegistryPol_IsLoggedOnceInItsFirstMinute()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PolFile)!);
        File.WriteAllBytes(PolFile, [.. "PRex"u8]);
        var enforcer = Make();
        for (_now = 0; _now <= 58_000; _now += 2_000) enforcer.Enforce(Reddit, true, false);
        Assert.Single(FailureLines());
    }

    [Fact]
    public void RefreshFailureAfterAPassWithNothingLeftToDo_IsLoggedAgainWithinTheMinute()
    {
        // The first request fails, the second works, and a later one (for a new change) fails again.
        var refresher = new ScriptedRefresher(call => call != 2);
        var enforcer = Make(refresher);
        enforcer.Enforce(Reddit, true, false);
        _now = 6_000;
        enforcer.Enforce(Reddit, true, false);
        _now = 8_000;
        enforcer.Enforce(Reddit, true, false);
        Assert.Single(FailureLines());

        // Both files were right and no refresh was waiting at 8 s, so the record of the first failure is gone and the new failure is logged, though it is under a minute later.
        _now = 14_000;
        enforcer.Enforce(RedditAndX, true, true);
        Assert.Equal(3, refresher.Calls);
        Assert.Equal(2, FailureLines().Count);
    }

    [Fact]
    public void GptIniOwnerLineWithANonAsciiByte_KeepsItsExactBytes()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(IniFile)!);
        byte[] owner = [.. "displayName=Caf"u8, 0xE9, (byte)'\r', (byte)'\n'];
        File.WriteAllBytes(IniFile, [.. "[General]\r\nVersion=3\r\n"u8, .. owner]);

        Make().Enforce(Reddit, true, false);

        byte[] after = File.ReadAllBytes(IniFile);
        Assert.Equal(4u, IniVersion());
        Assert.True(after.AsSpan().IndexOf(owner) >= 0, BitConverter.ToString(after));
    }

    [Fact]
    public void GptIniThatCannotBeWritten_LeavesRegistryPolUnchangedAndTheNextPassWritesBoth()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PolFile)!);
        byte[] ownerFile = RegistryPol.Serialize([WindowsUpdate, Homepage]);
        File.WriteAllBytes(PolFile, ownerFile);
        // A folder sits where gpt.ini belongs, so its move into place fails.
        Directory.CreateDirectory(IniFile);
        var enforcer = Make();

        enforcer.Enforce(Reddit, true, false);

        Assert.Equal(ownerFile, File.ReadAllBytes(PolFile));
        Assert.Equal(0, Refreshes);
        Assert.Single(FailureLines());
        Assert.Empty(Directory.GetFiles(Path.Combine(_sandbox.Root, "GroupPolicy"), "*.siteblock-tmp", SearchOption.AllDirectories));

        Directory.Delete(IniFile);
        _now = 2_000;
        enforcer.Enforce(Reddit, true, false);

        Assert.Equal(1u, IniVersion());
        var entries = ReadPol();
        Assert.Equal([WindowsUpdate, Homepage], entries.Take(2));
        Assert.Contains(PolEntry.Text(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block", "1", "*://*.reddit.com/*"), entries);
        Assert.Equal(1, Refreshes);
    }

    [Fact]
    public void UninstallPass_LeavesOnlyTheOwnersEntriesAndAsksForARefresh()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PolFile)!);
        File.WriteAllBytes(PolFile, RegistryPol.Serialize([WindowsUpdate, Homepage]));
        var enforcer = Make();
        enforcer.Enforce(Reddit, true, false);
        Assert.True(ReadPol().Count > 2);

        _now = 10_000;
        enforcer.Enforce(BrowserBlockLists.Empty, adultFilter: false, causedByCommand: true);

        Assert.Equal([WindowsUpdate, Homepage], ReadPol());
        Assert.Equal(2u, IniVersion());
        Assert.Equal(2, Refreshes);
    }

    [Fact]
    public void UninstallPassWithNoPolicyFile_CreatesNothingAndAsksForNoRefresh()
    {
        Make().Enforce(BrowserBlockLists.Empty, adultFilter: false, causedByCommand: true);
        Assert.False(File.Exists(PolFile));
        Assert.False(File.Exists(IniFile));
        Assert.Equal(0, Refreshes);
    }

    [Fact]
    public void PolicyFileThatCannotBeWritten_IsLoggedAndTheRegistryPassStillRuns()
    {
        // A folder sits where Registry.pol belongs, so the move into place fails.
        Directory.CreateDirectory(PolFile);

        Make().Enforce(Reddit, true, false);

        Assert.Contains("reddit.com", File.ReadAllText(_sandbox.Paths.RegistryFile), StringComparison.Ordinal);
        Assert.Single(FailureLines());
        Assert.Equal(0, Refreshes);
        Assert.Empty(Directory.GetFiles(Path.Combine(_sandbox.Root, "GroupPolicy"), "*.siteblock-tmp", SearchOption.AllDirectories));
    }
}

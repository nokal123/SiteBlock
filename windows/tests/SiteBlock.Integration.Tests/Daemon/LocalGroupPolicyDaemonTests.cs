using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// A real sandbox siteblockd keeps the Local Group Policy copy of the browser lists. Expected values come from 06-windows.md § BrowserPolicyEnforcer (the copy in Registry.pol, the
// refresh request after the file changed, at most once every 5 seconds) and § Installed Paths and Permissions (Sandbox: root/GroupPolicy/Machine/Registry.pol,
// root/policy-refreshes.log, where FilePolicyRefresher adds the line "refresh" for each request).
public sealed class LocalGroupPolicyDaemonTests
{
    // The 5-second refresh interval plus room for a loaded test machine.
    private const double RefreshSeconds = 12;

    private static string PolPath(SandboxDaemon daemon) => Path.Combine(daemon.Root, "GroupPolicy", "Machine", "Registry.pol");

    private static string RefreshLogPath(SandboxDaemon daemon) => Path.Combine(daemon.Root, "policy-refreshes.log");

    private static int Refreshes(SandboxDaemon daemon) => File.Exists(RefreshLogPath(daemon)) ? SandboxDaemon.ReadShared(RefreshLogPath(daemon)).Split('\n').Count(line => line == "refresh") : 0;

    // The file's entries, or none while it is missing or being replaced.
    private static List<PolEntry> Entries(SandboxDaemon daemon)
    {
        try
        {
            return File.Exists(PolPath(daemon)) ? RegistryPol.Parse(File.ReadAllBytes(PolPath(daemon))) : [];
        }
        catch (IOException)
        {
            return [];
        }
    }

    [Fact]
    public void Add_PutsTheSiteInTheSandboxRegistryPolAndAsksWindowsToApplyIt()
    {
        using var daemon = SandboxDaemon.Start();
        // The first passes may already have written the adult-filter values and asked for a refresh; let them settle so the count below belongs to the add.
        Thread.Sleep(TimeSpan.FromSeconds(1));
        int before = Refreshes(daemon);
        // The first pass writes the adult-filter values into a missing file, so it asks for a refresh; without that one counted here, the wait below could be met by it instead of the add's.
        Assert.True(before >= 1, $"refreshes before the add: {before}");

        daemon.SetupAndAdd("reddit.com");

        // The expander adds reddit's other domains (such as redd.it) to the list, so reddit.com is one of the numbered values, not necessarily "1"; the value is looked for among all of them.
        bool HasReddit() => Entries(daemon).Any(entry => entry.Key.Equals(@"SOFTWARE\Policies\Google\Chrome\URLBlocklist", StringComparison.OrdinalIgnoreCase) && entry.Name != "**delvals." && entry.Equals(PolEntry.Text(entry.Key, entry.Name, "reddit.com")));
        Assert.True(Wait.Until(HasReddit, 5), string.Join(", ", Entries(daemon)));
        Assert.Contains(Entries(daemon), entry => entry.Key.Equals(@"SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block", StringComparison.OrdinalIgnoreCase) && entry.Name == "1");
        Assert.True(Wait.Until(() => Refreshes(daemon) >= before + 1, RefreshSeconds), $"refreshes: {Refreshes(daemon)}, before the add: {before}");
        Assert.True(File.Exists(Path.Combine(daemon.Root, "GroupPolicy", "gpt.ini")));
    }
}

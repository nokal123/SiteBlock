using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// Brave's TorDisabled registry value. Expected values come from 06-windows.md § SiteBlock.Core (Windows browser policy rules: "Brave — ... TorDisabled (DWORD 1; the constant
// is BrowserPolicy.BraveTorDisabledKey)", "the adult-filter values (including Brave's TorDisabled) are left out only during an uninstall", "A value of the right name but the wrong
// type ... counts as wrong") and 03-daemon-cli-app.md § 13 BrowserPolicyEnforcer (Chrome, Edge and Firefox are not given the key).
public sealed class BraveTorDisabledPolicyTests
{
    private static readonly BrowserBlockLists RedditAndShorts = new(["reddit.com", "redd.it"], ["youtube.com/shorts"], ["*://*.reddit.com/*", "*://*.redd.it/*"], ["*://*.youtube.com/shorts*"]);

    // Every combination of the adult-filter flag and the lists a pass can be asked for.
    private static IEnumerable<RegistryPolicy> Variants(BrowserTarget target) =>
        from lists in new[] { RedditAndShorts, BrowserBlockLists.Empty } from filter in new[] { true, false } select WindowsBrowserPolicy.Desired(target, lists, filter);

    // The named values directly in the policy key, or an empty map.
    private static IReadOnlyDictionary<string, RegValue> TopValues(RegistryPolicy policy) => policy.Values.TryGetValue("", out var values) ? values : new Dictionary<string, RegValue>();

    [Fact]
    public void BraveTorDisabledKey_IsTheDesignsValueName()
    {
        Assert.Equal("TorDisabled", BrowserPolicy.BraveTorDisabledKey);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Desired_BraveWithTheFilterOn_WantsTorDisabledAsDwordOneWithOrWithoutABlockList(bool withList)
    {
        var values = TopValues(WindowsBrowserPolicy.Desired(BrowserTarget.Brave, withList ? RedditAndShorts : BrowserBlockLists.Empty, adultFilter: true));

        Assert.True(values.ContainsKey("TorDisabled"), string.Join(", ", values.Keys));
        Assert.Equal(RegValueKind.DWord, values["TorDisabled"].Kind);
        Assert.Equal(1, values["TorDisabled"].Number);
        Assert.NotEqual(RegValue.Str("1"), values["TorDisabled"]);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Desired_BraveWithTheFilterOff_LeavesTorDisabledOutButStillOwnsItSoTheUninstallRemovesIt(bool withList)
    {
        var policy = WindowsBrowserPolicy.Desired(BrowserTarget.Brave, withList ? RedditAndShorts : BrowserBlockLists.Empty, adultFilter: false);

        Assert.DoesNotContain(policy.Values, group => group.Value.ContainsKey("TorDisabled"));
        Assert.Contains("TorDisabled", policy.OwnedValueNames[""]);
    }

    [Theory]
    [InlineData(BrowserTarget.Chrome)]
    [InlineData(BrowserTarget.Edge)]
    [InlineData(BrowserTarget.Firefox)]
    public void Desired_OtherBrowsers_NeitherWantNorOwnTorDisabled(BrowserTarget target)
    {
        foreach (var policy in Variants(target))
        {
            Assert.DoesNotContain(policy.Values, group => group.Value.Keys.Contains("TorDisabled", StringComparer.OrdinalIgnoreCase));
            Assert.DoesNotContain(policy.OwnedValueNames, group => group.Value.Contains("TorDisabled", StringComparer.OrdinalIgnoreCase));
        }
    }

    [Fact]
    public void Desired_Brave_KeepsTorDisabledInTheKeyItselfNotInASubkey()
    {
        var policy = WindowsBrowserPolicy.Desired(BrowserTarget.Brave, RedditAndShorts, adultFilter: true);

        Assert.Equal([""], policy.Values.Keys);
        Assert.Equal([""], policy.OwnedValueNames.Keys);
        Assert.Equal(@"SOFTWARE\Policies\BraveSoftware\Brave", policy.KeyPath);
    }
}

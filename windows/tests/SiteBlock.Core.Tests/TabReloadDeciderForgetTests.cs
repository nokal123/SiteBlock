using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// TabReloadDecider.Forget(processId, tabId) drops what the decider remembers about one tab, so the next list that shows that tab on a matching address returns it again.
// The tab watcher calls it when a reload the decider asked for did not happen (06-windows.md § TabWatcher step 6). Expected values come from that contract and from
// 02-core-components.md § TabReloadDecider (a remembered tab at the same address is not returned again; processes never share memory).
public sealed class TabReloadDeciderForgetTests
{
    private const int Chrome = 4100;
    private const int Edge = 5200;
    private static readonly WatchedPathRule Shorts = new("youtube.com", "/shorts");
    private static readonly WatchedPathRule[] Rules = [Shorts];
    private const string Blocked = "https://www.youtube.com/shorts/abc";
    private const string OtherBlocked = "https://m.youtube.com/shorts/xyz";

    [Fact]
    public void Forget_RememberedTab_IsReturnedAgainByTheNextListAtTheSameAddress()
    {
        var decider = new TabReloadDecider();
        Assert.Equal(["1"], decider.TabsToReload(Chrome, [("1", Blocked)], Rules));
        // Control: without Forget, the same list returns nothing.
        Assert.Empty(decider.TabsToReload(Chrome, [("1", Blocked)], Rules));

        decider.Forget(Chrome, "1");

        Assert.Equal(["1"], decider.TabsToReload(Chrome, [("1", Blocked)], Rules));
        Assert.Equal(new Dictionary<string, string> { ["1"] = Blocked }, decider.Remembered(Chrome));
    }

    [Fact]
    public void Forget_OneTab_LeavesTheProcessesOtherTabsRemembered()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked), ("2", OtherBlocked)], Rules);

        decider.Forget(Chrome, "1");

        Assert.Equal(new Dictionary<string, string> { ["2"] = OtherBlocked }, decider.Remembered(Chrome));
        // Only the forgotten tab comes back; the other is still handled at its address.
        Assert.Equal(["1"], decider.TabsToReload(Chrome, [("1", Blocked), ("2", OtherBlocked)], Rules));
    }

    [Fact]
    public void Forget_LastTabOfAProcess_LeavesNothingRememberedForIt()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked)], Rules);

        decider.Forget(Chrome, "1");

        Assert.Empty(decider.Remembered(Chrome));
        // Forgetting again, now that the process has nothing left, is still harmless.
        decider.Forget(Chrome, "1");
        Assert.Empty(decider.Remembered(Chrome));
    }

    [Fact]
    public void Forget_SameTabIdInAnotherProcess_IsUntouched()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked)], Rules);
        decider.TabsToReload(Edge, [("1", Blocked)], Rules);

        decider.Forget(Chrome, "1");

        Assert.Equal(new Dictionary<string, string> { ["1"] = Blocked }, decider.Remembered(Edge));
        Assert.Empty(decider.TabsToReload(Edge, [("1", Blocked)], Rules));
        Assert.Equal(["1"], decider.TabsToReload(Chrome, [("1", Blocked)], Rules));
    }

    [Fact]
    public void Forget_UnknownProcess_ChangesNothing()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked)], Rules);

        decider.Forget(9999, "1");

        Assert.Equal(new Dictionary<string, string> { ["1"] = Blocked }, decider.Remembered(Chrome));
        Assert.Empty(decider.Remembered(9999));
        Assert.Empty(decider.TabsToReload(Chrome, [("1", Blocked)], Rules));
    }

    [Fact]
    public void Forget_UnknownTabOfAKnownProcess_ChangesNothing()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked)], Rules);

        decider.Forget(Chrome, "2");
        // Tab ids are compared as exact text, so "01" is a different tab from "1".
        decider.Forget(Chrome, "01");

        Assert.Equal(new Dictionary<string, string> { ["1"] = Blocked }, decider.Remembered(Chrome));
        Assert.Empty(decider.TabsToReload(Chrome, [("1", Blocked)], Rules));
    }

    [Fact]
    public void Forget_NullTabId_ThrowsArgumentNullExceptionAndKeepsMemory()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked)], Rules);

        Assert.Throws<ArgumentNullException>(() => decider.Forget(Chrome, null!));
        // The null id must be refused before anything changes, even for a process with nothing remembered.
        Assert.Throws<ArgumentNullException>(() => decider.Forget(9999, null!));
        Assert.Equal(new Dictionary<string, string> { ["1"] = Blocked }, decider.Remembered(Chrome));
    }

    [Fact]
    public void Forget_TabNowOnAnAddressThatMatchesNoRule_IsNotReturned()
    {
        var decider = new TabReloadDecider();
        decider.TabsToReload(Chrome, [("1", Blocked)], Rules);

        decider.Forget(Chrome, "1");

        // Forgetting only drops memory; it never makes a tab that is off the blocked part come back.
        Assert.Empty(decider.TabsToReload(Chrome, [("1", "https://www.youtube.com/watch?v=1")], Rules));
        Assert.Empty(decider.Remembered(Chrome));
    }
}

using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// AclGuard.SddlInheritsOnly and SddlMatches are pure SDDL text logic, so they run on the Mac.
// Expected values come from 06-windows.md § Installed Paths and Permissions (steps 3 and 4) and the methods' documented contract.
public sealed class AclSddlTests
{
    [Theory]
    // An empty list has no entries, so it is not "inherits only" (it is open or closed to everyone, not inheriting from the folder).
    [InlineData("D:", false)]
    // Not an access list at all.
    [InlineData("garbage", false)]
    // Protected lists do not inherit, so they are never "inherits only" even when their entries carry ID.
    [InlineData("D:PAI(A;OICIID;FA;;;SY)", false)]
    // Every entry carries the ID (inherited) flag and the list is not protected.
    [InlineData("D:AI(A;ID;FA;;;SY)(A;ID;0x1200a9;;;BU)", true)]
    // The ID flag inside a longer flag string still counts.
    [InlineData("D:(A;OICIID;FA;;;SY)", true)]
    // One entry is the object's own (no ID), so the list is not purely inherited.
    [InlineData("D:AI(A;ID;FA;;;SY)(A;;FA;;;BA)", false)]
    // An ordinary non-inherited entry.
    [InlineData("D:AI(A;OICI;FA;;;SY)", false)]
    public void SddlInheritsOnly_MatchesTheContract(string sddl, bool expected)
    {
        Assert.Equal(expected, AclGuard.SddlInheritsOnly(sddl));
    }

    [Fact]
    public void SddlMatches_SameEntriesDifferentOrder_IsTrue()
    {
        Assert.True(AclGuard.SddlMatches("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", "D:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)"));
    }

    [Fact]
    public void SddlMatches_DifferentProtection_IsFalse()
    {
        Assert.False(AclGuard.SddlMatches("D:PAI(A;OICI;FA;;;SY)", "D:AI(A;OICI;FA;;;SY)"));
    }

    [Fact]
    public void SddlMatches_DifferentEntries_IsFalse()
    {
        // The data-folder list (with a Users entry) must not match the state-folder list (without one).
        Assert.False(AclGuard.SddlMatches("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)", "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"));
    }

    [Fact]
    public void SddlMatches_AutoInheritedFlagIgnored()
    {
        // The AI flag Windows stamps on is not part of what the lists mean, so a list with it matches the same list without it.
        Assert.True(AclGuard.SddlMatches("D:PAI(A;OICI;FA;;;SY)", "D:P(A;OICI;FA;;;SY)"));
    }

    [Fact]
    public void SddlMatches_EntryCaseIgnored()
    {
        Assert.True(AclGuard.SddlMatches("D:P(a;oici;fa;;;sy)", "D:P(A;OICI;FA;;;SY)"));
    }

    [Fact]
    public void SddlMatches_NonSddl_IsFalse()
    {
        Assert.False(AclGuard.SddlMatches("nope", "D:P(A;OICI;FA;;;SY)"));
    }
}

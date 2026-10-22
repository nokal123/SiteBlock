using System.IO;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using SiteBlock.Service;

namespace SiteBlock.Windows.Tests;

// Windows-only positive check of the AclGuard path that the Mac build cannot run: with a non-sandbox Paths on Windows,
// Ensure applies the real access lists. Expected values come from 06-windows.md § Installed Paths and Permissions.
[SupportedOSPlatform("windows")]
public sealed class AclGuardWindowsTests
{
    [Fact]
    public void Ensure_NonSandboxOnWindows_AppliesTheLockedDownListsAndOwner()
    {
        string root = Path.Combine(Path.GetTempPath(), "sbaclg-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        // A non-sandbox Paths whose every folder lives under the throwaway root, so the real ACL work runs without touching the machine's install.
        var paths = Paths.Sandbox(root) with { IsSandbox = false };
        var guard = new AclGuard(paths, new Log(null));
        try
        {
            guard.Ensure();

            // The data folder gets the protected list with a Users read entry; the state folder gets the SYSTEM-and-Administrators-only list.
            Assert.True(AclGuard.SddlMatches(WindowsAcl.ReadDaclSddl(paths.DataDir)!, WindowsAcl.DataDirSddl));
            Assert.True(AclGuard.SddlMatches(WindowsAcl.ReadDaclSddl(paths.StateDir)!, WindowsAcl.StateDirSddl));

            // The data folder's owner is Administrators (S-1-5-32-544) or SYSTEM (S-1-5-18), so an owner may always put the list back.
            var owner = (SecurityIdentifier)new DirectorySecurity(paths.DataDir, AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier))!;
            Assert.Contains(owner.Value, new[] { "S-1-5-32-544", "S-1-5-18" });
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}

using System.IO;
using System.Runtime.Versioning;
using SiteBlock.Service;

namespace SiteBlock.Windows.Tests;

// Windows-only: the access-list helper calls into advapi32, so these run only on the Windows CI runner, never on the build Mac.
// Expected values come from 06-windows.md § Installed Paths and Permissions (the Access lists paragraph) and the exact SDDL strings the task pins.
[SupportedOSPlatform("windows")]
public sealed class WindowsAclTests
{
    [Fact]
    public void DataDirSddl_IsTheDocumentedProtectedList()
    {
        // Protected, inheriting: SYSTEM and Administrators full control, Users read & execute.
        Assert.Equal("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)", WindowsAcl.DataDirSddl);
    }

    [Fact]
    public void StateDirSddl_HasNoUsersEntry()
    {
        // The folder that holds the password hash: SYSTEM and Administrators only, so no ordinary account can read it.
        Assert.Equal("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", WindowsAcl.StateDirSddl);
    }

    [Fact]
    public void EnsureDataDirAcl_SetsThenReadsBackTheDataListAndIsIdempotent()
    {
        string dir = Path.Combine(Path.GetTempPath(), "sbacl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            Assert.True(WindowsAcl.EnsureDataDirAcl(dir));
            Assert.Equal(WindowsAcl.DataDirSddl, WindowsAcl.ReadDaclSddl(dir));
            // A second pass must see the list it already set and leave it alone.
            Assert.False(WindowsAcl.EnsureDataDirAcl(dir));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void EnsureStateDirAcl_SetsThenReadsBackTheStateListAndIsIdempotent()
    {
        string dir = Path.Combine(Path.GetTempPath(), "sbacl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            Assert.True(WindowsAcl.EnsureStateDirAcl(dir));
            Assert.Equal(WindowsAcl.StateDirSddl, WindowsAcl.ReadDaclSddl(dir));
            Assert.False(WindowsAcl.EnsureStateDirAcl(dir));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void EnsureBackupDirAcl_UsesTheSameSystemAndAdminsOnlyListAsTheStateFolder()
    {
        // The backup folder holds state.backup.json (a copy of the password hash), so it gets the state-folder list: no Users entry.
        string dir = Path.Combine(Path.GetTempPath(), "sbacl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            Assert.True(WindowsAcl.EnsureBackupDirAcl(dir));
            Assert.Equal(WindowsAcl.StateDirSddl, WindowsAcl.ReadDaclSddl(dir));
            Assert.False(WindowsAcl.EnsureBackupDirAcl(dir));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void EnsureFileInheritsOnly_LeavesTheFileWithOnlyInheritedEntries()
    {
        // A state file must carry no access-list entry of its own, so an added "Users may read state.json" cannot survive.
        string dir = Path.Combine(Path.GetTempPath(), "sbacl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        // The folder gets the locked-down list first, so what the file inherits is the SYSTEM-and-Administrators-only list.
        WindowsAcl.EnsureStateDirAcl(dir);
        string file = Path.Combine(dir, "state.json");
        File.WriteAllText(file, "{}");
        try
        {
            WindowsAcl.EnsureFileInheritsOnly(file);
            string? sddl = WindowsAcl.ReadDaclSddl(file);
            Assert.NotNull(sddl);
            // After the reset the file holds only what it inherits from its folder (no entry of its own, not protected).
            Assert.True(AclGuard.SddlInheritsOnly(sddl!));
            // A second pass sees it is already inherit-only and changes nothing.
            Assert.False(WindowsAcl.EnsureFileInheritsOnly(file));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void EnsureOwner_IsIdempotentOnceTheOwnerIsSystemOrAdministrators()
    {
        // There is no public owner reader, so the stable thing to assert is that after a repair the owner is SYSTEM or
        // Administrators, which makes a second call a no-op. Forcing a non-admin owner would need a second account, so this
        // checks the idempotence invariant rather than the first-pass change (which depends on who created the temp folder).
        string dir = Path.Combine(Path.GetTempPath(), "sbacl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            WindowsAcl.EnsureOwner(dir);
            Assert.False(WindowsAcl.EnsureOwner(dir));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.RegularExpressions;

namespace SiteBlock.Service;

/// <summary>
/// Keeps SiteBlock's data folders out of reach of ordinary users: no one but SYSTEM and Administrators may write anywhere in
/// them, and no one but SYSTEM and Administrators may read the two places that hold the password hash (the state folder and
/// the backup folder, which keeps a copy of the state). On every guard pass it recreates the folders when missing and puts the
/// locked-down, non-inheriting access lists back when they have drifted. It does not stop an administrator, who keeps full
/// control by design (see 06-windows.md § Installed Paths and Permissions). It never throws, because the guard timer calls it
/// alongside the other guards and an error here must not stop them.
/// </summary>
public sealed partial class AclGuard : IAclGuard
{
    // A failure message that repeats is logged at most this often, so a lasting problem does not fill the log every 5 seconds.
    private const long RepeatedFailureLogIntervalMs = 60_000;

    private readonly Paths _paths;
    private readonly Log _log;
    // When each failure message was last logged (from Environment.TickCount64).
    private readonly Dictionary<string, long> _lastFailureLogged = new(StringComparer.Ordinal);

    /// <summary>Builds the guard for the given set of paths, writing any repair lines to the given log.</summary>
    public AclGuard(Paths paths, Log log)
    {
        _paths = paths;
        _log = log;
    }

    // The folder that holds the program backup and the state backup (C:\ProgramData\SiteBlock\backup in production).
    private string BackupDir => Path.GetDirectoryName(_paths.StateBackup)!;

    /// <summary>
    /// Creates the data, state, log and backup folders when missing, then on Windows (outside the sandbox) puts the access lists
    /// of the data, state and backup folders back when they differ from the wanted ones, and resets any state file that carries
    /// its own access-list entries instead of only inheriting the state folder's.
    /// </summary>
    public void Ensure()
    {
        // Every platform needs the folders: the sandbox and the tests too. Each is handled on its own so one bad folder still lets the others be made.
        foreach (var folder in new[] { _paths.DataDir, _paths.StateDir, _paths.LogDir, BackupDir, _paths.BackupAppDir }) EnsureFolder(folder);

        // A sandbox run lives under one ordinary folder with no Windows access lists, so there is nothing to lock down.
        if (_paths.IsSandbox) return;
        // The access-list work is Windows-only; on the Mac build (used to run the shared tests) the guard stops here.
        // This guard, right before the call into the Windows-only helper, is also what keeps the CA1416 platform analyzer silent.
        if (!OperatingSystem.IsWindows()) return;

        RepairWindowsAcls();
    }

    // Creates the folder when missing. A file sitting at the folder's path would make every save into it fail, so it is renamed out of the way first (keeping its contents). A failure is logged once a minute and never thrown.
    private void EnsureFolder(string folder)
    {
        try
        {
            if (File.Exists(folder))
            {
                File.Move(folder, folder + ".siteblock-moved-" + Path.GetRandomFileName());
                _log.Write("a file in place of a SiteBlock folder was moved aside");
            }
            Directory.CreateDirectory(folder);
        }
        catch (Exception error)
        {
            LogFailure($"a SiteBlock folder could not be created ({error.GetType().Name})");
        }
    }

    // Compares each folder's current access list with the wanted one and rewrites only the ones that drifted, so a healthy
    // system produces no writes and no log lines. The folders go first, because a folder's new list flows down to the files
    // that inherit from it; the state files are checked after. A failure is logged without any path or detail, because the
    // next guard pass retries within seconds.
    [SupportedOSPlatform("windows")]
    private void RepairWindowsAcls()
    {
        // An owner may always rewrite a folder's access list, so an owner other than SYSTEM or Administrators (such as a user who created C:\ProgramData\SiteBlock before the install) is replaced first.
        foreach (var (what, folder) in new[] { ("data folder", _paths.DataDir), ("state folder", _paths.StateDir), ("backup folder", BackupDir) })
        {
            try { if (WindowsAcl.EnsureOwner(folder)) _log.Write($"{what} owner repaired"); }
            catch (Exception) { LogFailure($"{what} owner could not be repaired"); }
        }
        Repair("data folder", () => WindowsAcl.EnsureDataDirAcl(_paths.DataDir));
        Repair("state folder", () => WindowsAcl.EnsureStateDirAcl(_paths.StateDir));
        Repair("backup folder", () => WindowsAcl.EnsureBackupDirAcl(BackupDir));

        // An entry added to one file (such as "Users may read state.json") survives any folder-level repair, so each file that holds the password hash is checked on its own.
        var stateFiles = new List<string>();
        try { stateFiles.AddRange(Directory.GetFiles(_paths.StateDir)); }
        catch (Exception) { LogFailure("the state folder could not be listed"); }
        if (File.Exists(_paths.StateBackup)) stateFiles.Add(_paths.StateBackup);
        foreach (var file in stateFiles) Repair("state file", () => WindowsAcl.EnsureFileInheritsOnly(file));
    }

    // Runs one access-list check and logs "<what> access list repaired" when it changed something, or a rate-limited failure line when it could not.
    private void Repair(string what, Func<bool> ensure)
    {
        try { if (ensure()) _log.Write($"{what} access list repaired"); }
        // Win32 errors 2 and 3 (file or path not found) mean the object vanished mid-check, such as a temporary file the daemon renamed into place while saving state; there is nothing left to repair.
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
        catch (Exception) { LogFailure($"{what} access list could not be repaired"); }
    }

    /// <summary>
    /// True when <paramref name="sddl"/> (an access list in SDDL text form) is not protected and every one of its entries was
    /// inherited from the parent folder (each carries the <c>ID</c> flag). An empty list, a list with no entries at all, and a
    /// list that has any entry of its own all return false. Pure text logic, so it is tested on every platform.
    /// </summary>
    internal static bool SddlInheritsOnly(string sddl)
    {
        if (!sddl.StartsWith("D:", StringComparison.Ordinal)) return false;
        int firstEntry = sddl.IndexOf('(');
        // With no entries the file is either open to everyone (a null list) or closed to everyone; neither is what inheriting from the state folder gives.
        if (firstEntry < 0) return false;
        // The list's own flags sit between "D:" and the first entry; P means protected (does not inherit).
        if (sddl[2..firstEntry].Contains('P')) return false;
        foreach (Match entry in SddlEntry().Matches(sddl))
        {
            // Each entry is "type;flags;rights;object;inherited object;who". The flags are two-letter codes, and ID marks an inherited entry.
            var fields = entry.Groups[1].Value.Split(';');
            if (fields.Length < 2) return false;
            var flags = fields[1];
            bool inherited = Enumerable.Range(0, flags.Length / 2).Any(i => flags.Substring(i * 2, 2) == "ID");
            if (!inherited) return false;
        }
        return true;
    }

    /// <summary>
    /// True when two access lists in SDDL text form mean the same thing: both protected or both not, and the same entries in
    /// any order. The auto-inherited flags (AI, AR) that Windows adds on its own are ignored, so a list read back in a
    /// different order or with those flags still matches the wanted one and is not rewritten on every pass.
    /// </summary>
    internal static bool SddlMatches(string current, string wanted)
    {
        static (bool Protected, string[] Entries)? Shape(string sddl)
        {
            if (!sddl.StartsWith("D:", StringComparison.Ordinal)) return null;
            int firstEntry = sddl.IndexOf('(');
            var listFlags = firstEntry < 0 ? sddl[2..] : sddl[2..firstEntry];
            var entries = SddlEntry().Matches(sddl).Select(entry => entry.Value.ToUpperInvariant()).Order(StringComparer.Ordinal).ToArray();
            return (listFlags.Contains('P'), entries);
        }
        var a = Shape(current);
        var b = Shape(wanted);
        return a is not null && b is not null && a.Value.Protected == b.Value.Protected && a.Value.Entries.SequenceEqual(b.Value.Entries);
    }

    [GeneratedRegex(@"\(([^)]*)\)")]
    private static partial Regex SddlEntry();

    // Writes a failure line, but only when the same line was not written within the last minute.
    private void LogFailure(string message)
    {
        long now = Environment.TickCount64;
        if (_lastFailureLogged.TryGetValue(message, out long last) && now - last < RepeatedFailureLogIntervalMs) return;
        _lastFailureLogged[message] = now;
        _log.Write(message);
    }
}

/// <summary>
/// The raw-Win32 access-list logic, kept public and static so the Windows-only test project can run it against a
/// throwaway temp folder. It reads a folder's current DACL (discretionary access control list: the list of who may
/// do what to the folder), compares it to the wanted one, and rewrites it as a protected (non-inheriting) list when
/// they differ. "Protected" means the list does not inherit entries from the parent folder, which is why it blocks
/// the way C:\ProgramData otherwise lets ordinary users create files inside new subfolders. When SYSTEM has been locked
/// out of an object, it takes ownership first (see <see cref="OwnershipNative"/>) and writes the list again.
/// </summary>
[SupportedOSPlatform("windows")]
public static partial class WindowsAcl
{
    /// <summary>
    /// The wanted data-folder list, written as an SDDL (Security Descriptor Definition Language) string.
    /// <c>D:</c> starts the DACL; <c>P</c> protects it so it does not inherit from the parent; <c>AI</c> is the
    /// auto-inherited flag the system stamps on when it applies the list, so a freshly set folder reads back with it.
    /// Each <c>(A;OICI;rights;;;who)</c> is an allow entry that inherits to child files and folders (<c>OI</c> object
    /// inherit, <c>CI</c> container inherit): SYSTEM (<c>SY</c>) and Administrators (<c>BA</c>) get full access
    /// (<c>FA</c>), and Users (<c>BU</c>) get read &amp; execute (<c>0x1200a9</c> = read + execute).
    /// </summary>
    public const string DataDirSddl = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)";

    /// <summary>
    /// The wanted list for the state folder and the backup folder: the same protected list as the data folder but with NO
    /// Users entry, so no account other than SYSTEM and Administrators can read them. Both hold the password hash (the state
    /// and its backup copy), so an ordinary user must not be able to read it and attack the hash offline.
    /// </summary>
    public const string StateDirSddl = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

    // An empty access list. Written without the protected flag, it leaves an object with only the entries it inherits from its folder.
    private const string InheritOnlySddl = "D:";

    // SE_FILE_OBJECT: the object named by GetNamedSecurityInfo/SetNamedSecurityInfo is a file-system path.
    private const int SE_FILE_OBJECT = 1;
    // OWNER_SECURITY_INFORMATION: the owner part of a security descriptor.
    private const uint OWNER_SECURITY_INFORMATION = 0x00000001;
    // DACL_SECURITY_INFORMATION: the "who may do what" list.
    private const uint DACL_SECURITY_INFORMATION = 0x00000004;
    // PROTECTED_DACL_SECURITY_INFORMATION: on a set, replace the list with one that does not inherit from the parent.
    private const uint PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000;
    // UNPROTECTED_DACL_SECURITY_INFORMATION: on a set, let the list inherit from the parent again.
    private const uint UNPROTECTED_DACL_SECURITY_INFORMATION = 0x20000000;
    // SDDL_REVISION_1: the only SDDL version Windows defines; required by both convert calls.
    private const uint SDDL_REVISION_1 = 1;
    // ERROR_SUCCESS: GetNamedSecurityInfo and SetNamedSecurityInfo return a Win32 error code directly, 0 meaning success.
    private const uint ERROR_SUCCESS = 0;

    /// <summary>Puts the protected data-folder list on <paramref name="path"/> when it differs, and returns true when it had to change it.</summary>
    public static bool EnsureDataDirAcl(string path) => EnsureAcl(path, DataDirSddl);

    /// <summary>Puts the protected state-folder list (SYSTEM and Administrators only, no Users) on <paramref name="path"/> when it differs, and returns true when it had to change it.</summary>
    public static bool EnsureStateDirAcl(string path) => EnsureAcl(path, StateDirSddl);

    /// <summary>Puts the same SYSTEM-and-Administrators-only list on the backup folder, which holds the state backup, and returns true when it had to change it.</summary>
    public static bool EnsureBackupDirAcl(string path) => EnsureAcl(path, StateDirSddl);

    /// <summary>
    /// Makes the file at <paramref name="path"/> hold only the entries it inherits from its folder, removing any entry of its
    /// own and any protection, and returns true when it had to change it. Used on the files that hold the password hash.
    /// </summary>
    public static bool EnsureFileInheritsOnly(string path)
    {
        var current = ReadDaclSddl(path);
        if (current is not null && AclGuard.SddlInheritsOnly(current)) return false;
        ApplyWithTakeover(path, InheritOnlySddl, protect: false);
        return true;
    }

    /// <summary>
    /// Makes Administrators the owner of <paramref name="path"/> when its owner is anyone other than SYSTEM or
    /// Administrators, and returns true when it had to change it. Throws Win32Exception when the change fails.
    /// </summary>
    public static bool EnsureOwner(string path)
    {
        var owner = ReadSddl(path, OWNER_SECURITY_INFORMATION);
        if (owner is "O:SY" or "O:BA") return false;
        if (OwnershipNative.TakeOwnership(path) is string failure) throw new Win32Exception((int)OwnershipNative.ErrorAccessDenied, failure);
        return true;
    }

    /// <summary>
    /// Reads the folder's current DACL as an SDDL string, or null when the read fails. Public so a test can check
    /// the exact list on a folder after a repair (for example, that the state folder has no Users entry).
    /// </summary>
    public static string? ReadDaclSddl(string path) => ReadSddl(path, DACL_SECURITY_INFORMATION);

    // Reads one part of a path's security descriptor (its owner or its access list) as SDDL text, or null when the read fails.
    private static string? ReadSddl(string path, uint part)
    {
        // Ask only for the requested part. The four owner/group/dacl/sacl out pointers are optional conveniences we skip with NULL;
        // the whole descriptor still comes back in the last out buffer, which the system allocated and we must LocalFree.
        uint rc = GetNamedSecurityInfo(path, SE_FILE_OBJECT, part, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out IntPtr descriptor);
        if (rc != ERROR_SUCCESS || descriptor == IntPtr.Zero)
        {
            if (descriptor != IntPtr.Zero) LocalFree(descriptor);
            return null;
        }
        try
        {
            // Turn the requested part of the descriptor into SDDL text. The returned string buffer is also system-allocated, so free it too.
            if (!ConvertSecurityDescriptorToStringSecurityDescriptor(descriptor, SDDL_REVISION_1, part, out IntPtr sddl, out _))
                return null;
            try { return Marshal.PtrToStringUni(sddl); }
            finally { LocalFree(sddl); }
        }
        finally { LocalFree(descriptor); }
    }

    // Reads the folder's current list and rewrites it only when it does not mean the same as the wanted one (same
    // protection, same entries in any order; see AclGuard.SddlMatches). A read that fails (for example because the
    // list denies SYSTEM even reading it) is treated as "differs", so the guard rewrites rather than assuming it is fine.
    private static bool EnsureAcl(string path, string wantedSddl)
    {
        var current = ReadDaclSddl(path);
        if (current is not null && AclGuard.SddlMatches(current, wantedSddl)) return false;
        ApplyWithTakeover(path, wantedSddl, protect: true);
        return true;
    }

    // Writes the list; when Windows refuses because the list or the owner locks SYSTEM out, makes Administrators the owner
    // (an owner may always rewrite the list) and writes it again. Throws Win32Exception when the write still fails.
    private static void ApplyWithTakeover(string path, string sddl, bool protect)
    {
        try { ApplyAcl(path, sddl, protect); }
        catch (Win32Exception error) when (error.NativeErrorCode == (int)OwnershipNative.ErrorAccessDenied)
        {
            if (OwnershipNative.TakeOwnership(path) is string failure) throw new Win32Exception(error.NativeErrorCode, failure);
            ApplyAcl(path, sddl, protect);
        }
    }

    // Builds a security descriptor from the SDDL text, pulls its DACL out, and writes that DACL onto the path, either as a
    // protected list that replaces everything (inherited entries included) or as an unprotected one that keeps inheriting
    // from the parent. Throws Win32Exception when any step fails, so the caller can log a generic failure and a test can see
    // a real error rather than a silent miss. Frees the system-allocated descriptor buffer whether or not the set succeeded.
    private static void ApplyAcl(string path, string sddl, bool protect)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, SDDL_REVISION_1, out IntPtr descriptor, out _))
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        try
        {
            // The DACL pointer points inside the descriptor buffer, so it stays valid until we free that buffer.
            if (!GetSecurityDescriptorDacl(descriptor, out bool present, out IntPtr dacl, out _) || !present)
                throw new Win32Exception(Marshal.GetLastPInvokeError());
            uint protection = protect ? PROTECTED_DACL_SECURITY_INFORMATION : UNPROTECTED_DACL_SECURITY_INFORMATION;
            uint rc = SetNamedSecurityInfo(path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | protection, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (rc != ERROR_SUCCESS) throw new Win32Exception((int)rc);
        }
        finally { LocalFree(descriptor); }
    }

    // Reads a named object's security descriptor. Returns a Win32 error code; the descriptor out buffer is LocalAlloc'd and the caller frees it.
    [LibraryImport("advapi32.dll", EntryPoint = "GetNamedSecurityInfoW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint GetNamedSecurityInfo(string objectName, int objectType, uint securityInfo, IntPtr ppsidOwner, IntPtr ppsidGroup, IntPtr ppDacl, IntPtr ppSacl, out IntPtr ppSecurityDescriptor);

    // Writes a named object's security descriptor. Returns a Win32 error code.
    [LibraryImport("advapi32.dll", EntryPoint = "SetNamedSecurityInfoW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint SetNamedSecurityInfo(string objectName, int objectType, uint securityInfo, IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);

    // Parses an SDDL string into a security descriptor. Returns false on failure (check GetLastPInvokeError); the out descriptor is LocalAlloc'd.
    [LibraryImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ConvertStringSecurityDescriptorToSecurityDescriptor(string stringSecurityDescriptor, uint stringSDRevision, out IntPtr securityDescriptor, out uint securityDescriptorSize);

    // Renders a security descriptor's requested parts back into an SDDL string. Returns false on failure; the out string is LocalAlloc'd.
    [LibraryImport("advapi32.dll", EntryPoint = "ConvertSecurityDescriptorToStringSecurityDescriptorW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ConvertSecurityDescriptorToStringSecurityDescriptor(IntPtr securityDescriptor, uint requestedStringSDRevision, uint securityInformation, out IntPtr stringSecurityDescriptor, out uint stringSecurityDescriptorLen);

    // Reads the DACL pointer out of a security descriptor. The pointer is into the descriptor's own buffer, not a new allocation.
    [LibraryImport("advapi32.dll", EntryPoint = "GetSecurityDescriptorDacl", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetSecurityDescriptorDacl(IntPtr securityDescriptor, [MarshalAs(UnmanagedType.Bool)] out bool daclPresent, out IntPtr dacl, [MarshalAs(UnmanagedType.Bool)] out bool daclDefaulted);

    // Frees a buffer that a LocalAlloc-based call (the two converts and the get) handed back. Returns NULL on success.
    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr hMem);
}

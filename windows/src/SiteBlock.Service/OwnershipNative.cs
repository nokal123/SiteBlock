using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace SiteBlock.Service;

/// <summary>
/// Takes back a file or folder that someone has locked the SYSTEM account out of, for the hosts enforcer and the folder guard.
/// SYSTEM holds the "take ownership" and "restore files" privileges, but Windows starts a service with both switched off, so they
/// are switched on once for the whole process before the first takeover. A takeover then runs in two steps: make Administrators
/// the owner (the take-ownership privilege allows this even when the access list denies SYSTEM everything), then write the new
/// access list (an object's owner may always change its access list). One combined call would fail, because the privilege only
/// grants the right to change the owner, not the right to change the access list.
/// </summary>
[SupportedOSPlatform("windows")]
internal static partial class OwnershipNative
{
    // The Administrators group, which SiteBlock makes the owner. SYSTEM is a member of it, so SYSTEM then gets an owner's rights.
    private const string AdministratorsSid = "S-1-5-32-544";
    private const int SeFileObject = 1;
    private const uint OwnerSecurityInformation = 0x00000001;
    private const uint DaclSecurityInformation = 0x00000004;
    private const uint ProtectedDaclSecurityInformation = 0x80000000;
    private const uint SddlRevision1 = 1;
    private const uint TokenAdjustPrivileges = 0x0020;
    private const uint TokenQuery = 0x0008;
    private const uint SePrivilegeEnabled = 0x00000002;
    // AdjustTokenPrivileges succeeds but sets this error when the token does not hold the privilege at all.
    private const int ErrorNotAllAssigned = 1300;

    /// <summary>The Win32 error code SetNamedSecurityInfo returns when the caller lacks the rights to change the object.</summary>
    internal const uint ErrorAccessDenied = 5;

    private static readonly object EnableLock = new();
    private static bool _privilegesEnabled;

    /// <summary>
    /// Makes Administrators the owner of <paramref name="path"/>, then replaces its access list with the one in
    /// <paramref name="sddl"/> (SDDL, the text form of a security descriptor) as a list that does not inherit from the parent.
    /// Returns null on success, or a short description of the step that failed.
    /// </summary>
    internal static string? TakeOwnershipAndSetAcl(string path, string sddl)
    {
        if (TakeOwnership(path) is string ownerFailure) return ownerFailure;

        nint descriptor = 0;
        try
        {
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SddlRevision1, out descriptor, out _)) return $"access-list build error {Marshal.GetLastPInvokeError()}";
            if (!GetSecurityDescriptorDacl(descriptor, out bool present, out nint dacl, out _) || !present) return $"access-list read error {Marshal.GetLastPInvokeError()}";
            // The protected flag stops entries inherited from the parent folder from adding a denial back.
            uint daclResult = SetNamedSecurityInfoW(path, SeFileObject, DaclSecurityInformation | ProtectedDaclSecurityInformation, 0, 0, dacl, 0);
            return daclResult == 0 ? null : $"set-access-list error {daclResult}";
        }
        finally
        {
            // The access-list pointer points inside the descriptor, so freeing the descriptor frees it too.
            if (descriptor != 0) LocalFree(descriptor);
        }
    }

    /// <summary>
    /// Makes Administrators the owner of <paramref name="path"/>, after switching on the take-ownership privilege, so SYSTEM (a
    /// member of Administrators) gains an owner's right to rewrite the access list. Returns null on success, or what failed.
    /// </summary>
    internal static string? TakeOwnership(string path)
    {
        if (EnablePrivileges() is string privilegeFailure) return privilegeFailure;

        nint ownerSid = 0;
        try
        {
            if (!ConvertStringSidToSidW(AdministratorsSid, out ownerSid)) return $"owner SID error {Marshal.GetLastPInvokeError()}";
            uint ownerResult = SetNamedSecurityInfoW(path, SeFileObject, OwnerSecurityInformation, ownerSid, 0, 0, 0);
            return ownerResult == 0 ? null : $"take-ownership error {ownerResult}";
        }
        finally
        {
            if (ownerSid != 0) LocalFree(ownerSid);
        }
    }

    // Switches on the take-ownership privilege (and the restore privilege when held) for this process, once, and returns null on success or what failed.
    // They stay on afterwards: the process already runs as SYSTEM, and switching them off between uses would race between the
    // guard thread and the engine thread, which both take files back. A failure is not remembered, so the next takeover tries again.
    private static string? EnablePrivileges()
    {
        lock (EnableLock)
        {
            if (_privilegesEnabled) return null;
            if (!OpenProcessToken(GetCurrentProcess(), TokenAdjustPrivileges | TokenQuery, out nint token)) return $"token open error {Marshal.GetLastPInvokeError()}";
            try
            {
                // Taking ownership needs only SeTakeOwnershipPrivilege. SeRestorePrivilege is switched on as well when the account holds it, because it also lets the owner be set to a group, but its absence is not a failure.
                if (EnableOne(token, "SeTakeOwnershipPrivilege") is string failure) return failure;
                EnableOne(token, "SeRestorePrivilege");
                _privilegesEnabled = true;
                return null;
            }
            finally { CloseHandle(token); }
        }
    }

    // Switches on one privilege in the token and returns null on success or what failed.
    private static string? EnableOne(nint token, string name)
    {
        if (!LookupPrivilegeValueW(null, name, out var luid)) return $"privilege lookup error {Marshal.GetLastPInvokeError()}";
        var privileges = new TokenPrivilegesOne { PrivilegeCount = 1, Luid = luid, Attributes = SePrivilegeEnabled };
        // AdjustTokenPrivileges reports success even when the token lacks the privilege, so the last error is checked too.
        if (!AdjustTokenPrivileges(token, false, ref privileges, 0, 0, 0)) return $"privilege enable error {Marshal.GetLastPInvokeError()}";
        return Marshal.GetLastPInvokeError() == ErrorNotAllAssigned ? $"{name} is not held by this account" : null;
    }

    // A locally unique ID (LUID), the number Windows uses for a privilege on this PC.
    [StructLayout(LayoutKind.Sequential)]
    private struct Luid
    {
        public uint LowPart;
        public int HighPart;
    }

    // TOKEN_PRIVILEGES holding exactly one privilege, which is all each AdjustTokenPrivileges call here needs.
    [StructLayout(LayoutKind.Sequential)]
    private struct TokenPrivilegesOne
    {
        public uint PrivilegeCount;
        public Luid Luid;
        public uint Attributes;
    }

    [LibraryImport("kernel32.dll")]
    private static partial nint GetCurrentProcess();

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenProcessToken(nint processHandle, uint desiredAccess, out nint tokenHandle);

    [LibraryImport("advapi32.dll", EntryPoint = "LookupPrivilegeValueW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool LookupPrivilegeValueW(string? systemName, string name, out Luid luid);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AdjustTokenPrivileges(nint tokenHandle, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivilegesOne newState, uint bufferLength, nint previousState, nint returnLength);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

    [LibraryImport("advapi32.dll", EntryPoint = "ConvertStringSidToSidW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ConvertStringSidToSidW(string stringSid, out nint sid);

    [LibraryImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out nint securityDescriptor, out uint size);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetSecurityDescriptorDacl(nint securityDescriptor, [MarshalAs(UnmanagedType.Bool)] out bool daclPresent, out nint dacl, [MarshalAs(UnmanagedType.Bool)] out bool daclDefaulted);

    [LibraryImport("advapi32.dll", EntryPoint = "SetNamedSecurityInfoW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint SetNamedSecurityInfoW(string objectName, int objectType, uint securityInfo, nint owner, nint group, nint dacl, nint sacl);

    [LibraryImport("kernel32.dll")]
    private static partial nint LocalFree(nint mem);
}

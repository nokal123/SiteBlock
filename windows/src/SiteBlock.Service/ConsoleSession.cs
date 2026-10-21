using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;

namespace SiteBlock.Service;

/// <summary>
/// Finds the person signed in to the active console session (the session shown on the PC's own screen), which replaces the Mac's owner of /dev/console.
/// It reads the session with WTSGetActiveConsoleSessionId and WTSQuerySessionInformation and turns the account name into its security ID (SID).
/// </summary>
public static class ConsoleSession
{
    /// <summary>The SID of the built-in SYSTEM account, which only the service itself and administrators can act as.</summary>
    public const string SystemSid = "S-1-5-18";

    // WTSGetActiveConsoleSessionId returns this when no session is attached to the console (for example while sessions are switching).
    private const uint NoSession = 0xFFFFFFFF;
    // The WTS_INFO_CLASS values for the user name and the domain name of a session.
    private const int WtsUserName = 5;
    private const int WtsDomainName = 7;

    /// <summary>
    /// The SID of the console user, or the SYSTEM SID when nobody is signed in or the lookup fails. It never returns null, because the engine reads null as "anyone may set the password":
    /// a failure must close setup to everyone but administrators, as the Mac's lookup falls back to root.
    /// </summary>
    public static string UserSidOrSystem()
    {
        if (!OperatingSystem.IsWindows()) return SystemSid;
        try
        {
            return ConsoleUserSid() ?? SystemSid;
        }
        catch (Exception)
        {
            return SystemSid;
        }
    }

    /// <summary>The active console session's ID, or null when no session is attached to the console. Windows only.</summary>
    [SupportedOSPlatform("windows")]
    public static uint? ActiveSessionId()
    {
        uint id = WTSGetActiveConsoleSessionId();
        return id == NoSession ? null : id;
    }

    /// <summary>
    /// The console user's SID, or null when no session is attached or nobody is signed in to it. It reads the user's own token with WTSQueryUserToken (which the service may call
    /// because it runs as SYSTEM), so no account-name lookup is needed: such a lookup can stall on a domain controller and can fail for Microsoft and work accounts.
    /// When the token cannot be read it falls back to the session's account name.
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static string? ConsoleUserSid()
    {
        if (ActiveSessionId() is not uint session) return null;
        if (WTSQueryUserToken(session, out IntPtr token))
        {
            try
            {
                using var identity = new WindowsIdentity(token);
                return identity.User?.Value;
            }
            finally
            {
                CloseHandle(token);
            }
        }
        string? user = QueryString(session, WtsUserName);
        // The console session exists but shows the sign-in screen: nobody is signed in.
        if (string.IsNullOrEmpty(user)) return null;
        string? domain = QueryString(session, WtsDomainName);
        var account = string.IsNullOrEmpty(domain) ? new NTAccount(user) : new NTAccount(domain, user);
        return ((SecurityIdentifier)account.Translate(typeof(SecurityIdentifier))).Value;
    }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    /// <summary>Reads one text field of a session, or null when the call fails.</summary>
    [SupportedOSPlatform("windows")]
    private static string? QueryString(uint session, int infoClass)
    {
        if (!WTSQuerySessionInformationW(IntPtr.Zero, session, infoClass, out IntPtr buffer, out _)) return null;
        try
        {
            return Marshal.PtrToStringUni(buffer);
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQuerySessionInformationW(IntPtr server, uint sessionId, int infoClass, out IntPtr buffer, out uint bytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);
}

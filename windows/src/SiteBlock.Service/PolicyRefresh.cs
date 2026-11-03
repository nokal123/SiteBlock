using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace SiteBlock.Service;

/// <summary>
/// Asks Windows to apply the computer's Group Policy, after SiteBlock changed its Local Group Policy file. Chrome, Edge and Brave on Windows read their policy again only when Windows signals that it applied
/// a policy change, or on their own 15-minute timer (06-windows.md § BrowserPolicyEnforcer).
/// </summary>
public interface IPolicyRefresher
{
    /// <summary>Asks for one refresh. Throws when the request could not be made.</summary>
    void Refresh();
}

/// <summary>Chooses the refresher for a run.</summary>
public static class PolicyRefreshers
{
    /// <summary>The sandbox's refresh log for a sandbox run; a real Group Policy refresh otherwise.</summary>
    public static IPolicyRefresher For(Paths paths)
    {
        if (paths.IsSandbox || !OperatingSystem.IsWindows()) return new FilePolicyRefresher(paths.PolicyRefreshLog);
        return new GroupPolicyRefresher();
    }
}

/// <summary>
/// Asks Windows to apply the computer's Group Policy (<c>RefreshPolicyEx</c>, the call behind <c>gpupdate /target:computer</c>). Windows sees the raised version in gpt.ini, applies the Local Group Policy file,
/// and then signals every program that registered for policy changes, so Chrome, Edge and Brave read their policy keys again. The call only starts the refresh and returns; it does not wait for it.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class GroupPolicyRefresher : IPolicyRefresher
{
    /// <summary>Starts a refresh of the computer's policy, or throws a <see cref="Win32Exception"/> with Windows' error when it cannot be started.</summary>
    public void Refresh()
    {
        // bMachine true refreshes computer policy, which is where HKEY_LOCAL_MACHINE\SOFTWARE\Policies belongs. Option 0 applies only what changed, which is the policy file SiteBlock just changed.
        if (!RefreshPolicyEx(true, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RefreshPolicyEx([MarshalAs(UnmanagedType.Bool)] bool bMachine, uint dwOptions);
}

/// <summary>The sandbox stand-in: each refresh adds the line "refresh" to a file, so tests can count the refreshes that were asked for.</summary>
public sealed class FilePolicyRefresher(string path) : IPolicyRefresher
{
    /// <summary>Appends one "refresh" line to the file, creating it when missing.</summary>
    public void Refresh() => File.AppendAllText(path, "refresh\n");
}

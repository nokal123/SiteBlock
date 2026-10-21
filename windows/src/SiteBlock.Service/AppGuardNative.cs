using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace SiteBlock.Service;

/// <summary>
/// The Windows system calls the tray-app guard needs: reading, writing and deleting the Run value in the 64-bit
/// registry view, finding the session shown on the PC's own screen, and starting a program inside that signed-in
/// user's session. Every type here is prefixed "AppGuard" so its interop declarations cannot clash with another
/// component's. Nothing in this file runs on macOS; the guard calls it only after it has checked it is on Windows.
/// </summary>
internal static class AppGuardNative
{
    // The registry path, under HKEY_LOCAL_MACHINE, of the values Windows starts at every sign-in.
    private const string RunKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";

    // HKEY_LOCAL_MACHINE is the fixed pseudo-handle (LONG)0x80000002 widened to a pointer, matching the Windows headers.
    private static readonly IntPtr HkeyLocalMachine = new(unchecked((int)0x80000002));

    // Registry call return codes and the only value type the guard reads or writes.
    private const int ErrorSuccess = 0;
    private const int ErrorFileNotFound = 2;
    private const uint RegSz = 1;

    // Access rights for opening the key: ask-for-a-value, set-a-value, and the flag that forces the 64-bit view so a 32-bit service still reads the 64-bit Run key.
    private const uint KeyQueryValue = 0x0001;
    private const uint KeySetValue = 0x0002;
    private const uint KeyWow6464Key = 0x0100;

    // The session id WTSGetActiveConsoleSessionId returns when no session is attached to the physical console.
    private const uint NoConsoleSession = 0xFFFFFFFF;

    // Tells CreateProcessAsUser the environment block it is handed is UTF-16 rather than the older single-byte form.
    private const uint CreateUnicodeEnvironment = 0x00000400;

    // --- Registry (advapi32) ---

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegOpenKeyExW(IntPtr hKey, string lpSubKey, uint ulOptions, uint samDesired, out IntPtr phkResult);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegQueryValueExW(IntPtr hKey, string lpValueName, IntPtr lpReserved, out uint lpType, byte[]? lpData, ref uint lpcbData);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegSetValueExW(IntPtr hKey, string lpValueName, uint reserved, uint dwType, byte[] lpData, uint cbData);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegDeleteValueW(IntPtr hKey, string lpValueName);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegCloseKey(IntPtr hKey);

    // --- Console session and launching into it (kernel32, wtsapi32, userenv, advapi32) ---

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool WTSQueryUserToken(uint sessionId, out IntPtr phToken);

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, [MarshalAs(UnmanagedType.Bool)] bool bInherit);

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    // lpCommandLine is a StringBuilder because CreateProcessW may write into the command-line buffer, and a .NET string must never be changed in place.
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessAsUserW(
        IntPtr hToken, string? lpApplicationName, StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string? lpCurrentDirectory,
        ref AppGuardStartupInfo lpStartupInfo, out AppGuardProcessInformation lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr hObject);

    // PROCESS_QUERY_LIMITED_INFORMATION: the smallest access right that still allows reading a process's program path.
    private const uint ProcessQueryLimitedInformation = 0x1000;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);

    // --- Process helper the guard uses ---

    // Returns the full path of the program a process runs (such as C:\Program Files\SiteBlock\SiteBlockApp.exe), or null when it cannot be read, for example because the process has already exited.
    [SupportedOSPlatform("windows")]
    internal static string? ProcessImagePath(int processId)
    {
        var handle = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (handle == IntPtr.Zero) return null;
        try
        {
            // 32,767 characters is the longest path Windows allows, so the buffer can never be too small.
            uint size = 32_767;
            var buffer = new StringBuilder((int)size);
            // Flag 0 asks for the ordinary Win32 form of the path (C:\...), the same form the guard compares against.
            return QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? buffer.ToString(0, (int)size) : null;
        }
        finally { CloseHandle(handle); }
    }

    // --- Registry helpers the guard uses ---

    // Reads the named Run value's string, or null when the value is missing, is not a string or cannot be read.
    [SupportedOSPlatform("windows")]
    internal static string? ReadRunValue(string valueName)
    {
        if (RegOpenKeyExW(HkeyLocalMachine, RunKeyPath, 0, KeyQueryValue | KeyWow6464Key, out var key) != ErrorSuccess) return null;
        try
        {
            uint size = 0;
            // Asking with no buffer reports how many bytes the value needs, so the right-sized buffer is allocated once.
            if (RegQueryValueExW(key, valueName, IntPtr.Zero, out var type, null, ref size) != ErrorSuccess || type != RegSz || size == 0) return null;
            var buffer = new byte[size];
            if (RegQueryValueExW(key, valueName, IntPtr.Zero, out type, buffer, ref size) != ErrorSuccess || type != RegSz) return null;
            // The bytes are UTF-16 and carry a terminating null; the value ends at the first null, so that is where the string is cut.
            var text = Encoding.Unicode.GetString(buffer, 0, (int)size);
            var end = text.IndexOf('\0');
            return end >= 0 ? text[..end] : text;
        }
        finally { RegCloseKey(key); }
    }

    // Writes the Run value as a string and returns whether the write succeeded.
    [SupportedOSPlatform("windows")]
    internal static bool WriteRunValue(string valueName, string value)
    {
        if (RegOpenKeyExW(HkeyLocalMachine, RunKeyPath, 0, KeySetValue | KeyWow6464Key, out var key) != ErrorSuccess) return false;
        try
        {
            // A string value is stored as UTF-16 with a terminating null, so the null is added and counted in the byte length.
            var bytes = Encoding.Unicode.GetBytes(value + '\0');
            return RegSetValueExW(key, valueName, 0, RegSz, bytes, (uint)bytes.Length) == ErrorSuccess;
        }
        finally { RegCloseKey(key); }
    }

    // Deletes the Run value and returns true when it is gone afterwards, counting "already absent" as success.
    [SupportedOSPlatform("windows")]
    internal static bool DeleteRunValue(string valueName)
    {
        if (RegOpenKeyExW(HkeyLocalMachine, RunKeyPath, 0, KeySetValue | KeyWow6464Key, out var key) != ErrorSuccess) return false;
        try
        {
            var status = RegDeleteValueW(key, valueName);
            // The uninstaller only cares that the value is absent, so a value that was never there is not a failure.
            return status == ErrorSuccess || status == ErrorFileNotFound;
        }
        finally { RegCloseKey(key); }
    }

    // --- Console-session helpers the guard uses ---

    // Returns the id of the session shown on the PC's own screen, or null when no session is attached there.
    [SupportedOSPlatform("windows")]
    internal static uint? ConsoleSessionId()
    {
        var session = WTSGetActiveConsoleSessionId();
        return session == NoConsoleSession ? null : session;
    }

    // Builds the signed-in user's environment, starts the program with that user's token on the user's own desktop,
    // and returns whether the program started. `errorMessage` says what step failed, for a rate-limited log line.
    [SupportedOSPlatform("windows")]
    internal static bool StartProcessAsUser(IntPtr userToken, string applicationPath, string workingDirectory, out string? errorMessage)
    {
        errorMessage = null;
        var environment = IntPtr.Zero;
        try
        {
            // The app must see the user's own variables (their profile, temp folder and so on), not the service's SYSTEM environment.
            if (!CreateEnvironmentBlock(out environment, userToken, false))
            {
                errorMessage = $"building the user environment failed (Win32 error {Marshal.GetLastWin32Error()})";
                return false;
            }
            // winsta0\default is the interactive desktop the signed-in user looks at; the tray window must appear there.
            var startup = new AppGuardStartupInfo { cb = Marshal.SizeOf<AppGuardStartupInfo>(), lpDesktop = @"winsta0\default" };
            // Starting with the user's token (not the service's SYSTEM token) gives the app the user's normal rights and a real desktop; SYSTEM has no desktop to show a window on.
            // The command line is the program path in quotes. Without one, Windows would use the bare path, and the space in "Program Files" would split it so the app received "Files\SiteBlock\SiteBlockApp.exe" as a stray argument.
            var commandLine = new StringBuilder($"\"{applicationPath}\"");
            var started = CreateProcessAsUserW(userToken, applicationPath, commandLine, IntPtr.Zero, IntPtr.Zero, false, CreateUnicodeEnvironment, environment, workingDirectory, ref startup, out var info);
            if (!started)
            {
                errorMessage = $"launching it in the user's session failed (Win32 error {Marshal.GetLastWin32Error()})";
                return false;
            }
            // The service does not wait on the app, so the two handles the call opened are closed at once to leak nothing.
            CloseHandle(info.hThread);
            CloseHandle(info.hProcess);
            return true;
        }
        finally
        {
            if (environment != IntPtr.Zero) DestroyEnvironmentBlock(environment);
        }
    }
}

// The fields of these two structs are filled by the Windows marshaller, not by C# code, so the compiler's
// "never assigned" check does not apply to them; it is turned off for the two declarations only.
#pragma warning disable CS0649

/// <summary>The STARTUPINFO structure CreateProcessAsUser reads: the guard sets only the size and the desktop name.</summary>
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct AppGuardStartupInfo
{
    public int cb;
    public string? lpReserved;
    public string? lpDesktop;
    public string? lpTitle;
    public int dwX;
    public int dwY;
    public int dwXSize;
    public int dwYSize;
    public int dwXCountChars;
    public int dwYCountChars;
    public int dwFillAttribute;
    public int dwFlags;
    public short wShowWindow;
    public short cbReserved2;
    public IntPtr lpReserved2;
    public IntPtr hStdInput;
    public IntPtr hStdOutput;
    public IntPtr hStdError;
}

/// <summary>The PROCESS_INFORMATION structure CreateProcessAsUser fills: the guard closes the two handles and ignores the ids.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct AppGuardProcessInformation
{
    public IntPtr hProcess;
    public IntPtr hThread;
    public int dwProcessId;
    public int dwThreadId;
}

#pragma warning restore CS0649

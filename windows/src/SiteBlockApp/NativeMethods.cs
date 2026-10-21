using System.Runtime.InteropServices;

namespace SiteBlock.App;

/// <summary>The few Windows functions the tray app calls directly: the window frame and backdrop (dwmapi), window styles and icons (user32).</summary>
internal static partial class NativeMethods
{
    /// <summary>Asks Windows to draw the window's title bar and frame dark (20 = DWMWA_USE_IMMERSIVE_DARK_MODE).</summary>
    public const int DwmwaUseImmersiveDarkMode = 20;
    /// <summary>The window's corner style (33 = DWMWA_WINDOW_CORNER_PREFERENCE), Windows 11 only.</summary>
    public const int DwmwaWindowCornerPreference = 33;
    /// <summary>The material behind the window (38 = DWMWA_SYSTEMBACKDROP_TYPE), Windows 11 22H2 and later.</summary>
    public const int DwmwaSystemBackdropType = 38;
    /// <summary>The corner value for rounded corners (DWMWCP_ROUND).</summary>
    public const int DwmwcpRound = 2;
    /// <summary>The backdrop value for Mica (DWMSBT_MAINWINDOW).</summary>
    public const int DwmsbtMainWindow = 2;

    /// <summary>The extended window style index for SetWindowLongPtr.</summary>
    public const int GwlExStyle = -20;
    /// <summary>A tool window: it does not show in Alt+Tab or on the taskbar.</summary>
    public const long WsExToolWindow = 0x00000080;
    /// <summary>The message Windows sends when a system setting changes, including light and dark mode ("ImmersiveColorSet").</summary>
    public const int WmSettingChange = 0x001A;
    /// <summary>Lets any process take the foreground once, so the running copy can bring its panel forward when a second copy asks.</summary>
    public const uint AsfwAny = unchecked((uint)-1);

    /// <summary>The margins of the frame drawn into the window's client area; -1 on every side means the whole window.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct Margins
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;
    }

    /// <summary>Sets one attribute of how the desktop window manager draws the window. Returns 0 on success.</summary>
    [LibraryImport("dwmapi.dll")]
    public static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Draws the window frame (and with it the backdrop material) into the client area.</summary>
    [LibraryImport("dwmapi.dll")]
    public static partial int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    /// <summary>Reads a window's extended style bits.</summary>
    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static partial IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    /// <summary>Writes a window's extended style bits.</summary>
    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static partial IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    /// <summary>Frees an icon handle made by Bitmap.GetHicon.</summary>
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyIcon(IntPtr handle);

    /// <summary>Allows the given process (or any, with <see cref="AsfwAny"/>) to bring a window to the foreground.</summary>
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AllowSetForegroundWindow(uint processId);

    /// <summary>Brings a window to the foreground and gives it keyboard focus.</summary>
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(IntPtr hwnd);

    /// <summary>Calls back once for every top-level window. (DllImport, because the newer LibraryImport cannot pass a delegate.)</summary>
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    /// <summary>The callback of <see cref="EnumWindows"/>; return true to continue.</summary>
    [return: MarshalAs(UnmanagedType.Bool)]
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    /// <summary>True when the window is visible.</summary>
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindowVisible(IntPtr hwnd);

    /// <summary>True when the handle still names a window.</summary>
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindow(IntPtr hwnd);

    /// <summary>The length of the window's title, 0 for none.</summary>
    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextLengthW")]
    public static partial int GetWindowTextLength(IntPtr hwnd);

    /// <summary>Copies the window's class name into the buffer and returns its length.</summary>
    [LibraryImport("user32.dll", EntryPoint = "GetClassNameW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int GetClassName(IntPtr hwnd, [Out] char[] className, int maxCount);

    /// <summary>The id of the process that owns the window.</summary>
    [LibraryImport("user32.dll")]
    public static partial uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
}

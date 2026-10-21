using System.Diagnostics;
using System.Globalization;
using System.Windows.Automation;
using SiteBlock.AppLogic;

namespace SiteBlock.App;

/// <summary>
/// Reads and reloads the visible tab of every Chrome, Edge and Brave window through UI Automation (the Windows accessibility interface screen readers use).
/// It lists the top-level windows of class <c>Chrome_WidgetWin_1</c> that are visible, have a title and belong to a process named chrome, msedge or brave; finds each window's address bar (class <c>OmniboxViewViews</c>, an Edit control) once and remembers it;
/// reads its text with the Value pattern (skipping a window while its address bar has keyboard focus, because the person may be typing); and reloads by pressing the window's <c>ReloadButton</c> with the Invoke pattern.
/// Class names are used because they do not change with the browser's language, while visible names do. Every call runs on the tab watcher's pool thread, never on the window thread.
/// </summary>
internal sealed class UiaBrowserTabs : IBrowserTabs
{
    /// <summary>The process names of the supported browsers, with the names people know them by.</summary>
    private static readonly Dictionary<string, string> Browsers = new(StringComparer.OrdinalIgnoreCase)
    {
        ["chrome"] = "Google Chrome",
        ["msedge"] = "Microsoft Edge",
        ["brave"] = "Brave",
    };

    /// <summary>The window class of every Chromium browser window (also used by other Chromium-based apps, which the process name filters out).</summary>
    private const string BrowserWindowClass = "Chrome_WidgetWin_1";
    /// <summary>The class of the address bar.</summary>
    private const string AddressBarClass = "OmniboxViewViews";
    /// <summary>The class of the reload button.</summary>
    private const string ReloadButtonClass = "ReloadButton";
    /// <summary>The most elements one search for the address bar or reload button looks at, so a huge window never stalls a tick.</summary>
    private const int MaxSearchNodes = 4000;

    private readonly Lock _gate = new();
    /// <summary>The browser windows found by the latest <see cref="RunningBrowsers"/>, by process id.</summary>
    private Dictionary<int, List<IntPtr>> _windows = [];
    /// <summary>Each window's address bar and reload button, found once and kept until the window closes or the element stops answering.</summary>
    private readonly Dictionary<IntPtr, (AutomationElement? AddressBar, AutomationElement? ReloadButton)> _elements = [];
    /// <summary>When a window whose address bar or reload button was not found may be searched again (milliseconds since Windows started), so a window without one, such as DevTools, is not searched every tick.</summary>
    private readonly Dictionary<(IntPtr Window, bool ReloadButton), long> _retryAfter = [];
    /// <summary>How long to wait before searching a window again after a search found nothing.</summary>
    private const long RetryMilliseconds = 2_000;
    /// <summary>Process names already looked up, by process id and start time, so a reused id is looked up again.</summary>
    private readonly Dictionary<int, (DateTime Started, string? Name)> _processNames = [];

    /// <summary>Lists the browser processes that own at least one visible, titled browser window right now.</summary>
    public IReadOnlyList<BrowserProcess> RunningBrowsers()
    {
        var windows = new Dictionary<int, List<IntPtr>>();
        var className = new char[64];
        NativeMethods.EnumWindows((hwnd, _) =>
        {
            if (!NativeMethods.IsWindowVisible(hwnd) || NativeMethods.GetWindowTextLength(hwnd) == 0) return true;
            int length = NativeMethods.GetClassName(hwnd, className, className.Length);
            if (length <= 0 || !new string(className, 0, length).Equals(BrowserWindowClass, StringComparison.Ordinal)) return true;
            NativeMethods.GetWindowThreadProcessId(hwnd, out uint processId);
            if (!windows.TryGetValue((int)processId, out List<IntPtr>? list)) windows[(int)processId] = list = [];
            list.Add(hwnd);
            return true;
        }, IntPtr.Zero);

        var browsers = new List<BrowserProcess>();
        foreach (int processId in windows.Keys.ToList())
        {
            if (DisplayNameOf(processId) is { } name) browsers.Add(new BrowserProcess(processId, name));
            else windows.Remove(processId);
        }
        lock (_gate)
        {
            _windows = windows;
            // Forget the elements of windows that are gone.
            var live = windows.Values.SelectMany(list => list).ToHashSet();
            foreach (IntPtr gone in _elements.Keys.Where(hwnd => !live.Contains(hwnd)).ToList()) _elements.Remove(gone);
            foreach (var gone in _retryAfter.Keys.Where(key => !live.Contains(key.Window)).ToList()) _retryAfter.Remove(gone);
        }
        return browsers;
    }

    /// <summary>Reads the address of each window of one browser process. Windows whose address bar has focus or cannot be found are left out.</summary>
    public IReadOnlyList<BrowserWindowAddress> ReadWindows(int processId)
    {
        List<IntPtr> windows;
        lock (_gate) windows = _windows.TryGetValue(processId, out List<IntPtr>? list) ? [.. list] : [];
        var result = new List<BrowserWindowAddress>();
        foreach (IntPtr hwnd in windows)
        {
            try
            {
                if (ReadAddress(hwnd) is { Length: > 0 } url) result.Add(new BrowserWindowAddress(IdOf(hwnd), url));
            }
            catch (Exception)
            {
                // This window closed or stopped answering; forget its elements and skip it this tick.
                Forget(hwnd);
            }
        }
        return result;
    }

    /// <summary>Reads one window's address again, or null when it cannot be read now.</summary>
    public string? CurrentUrl(int processId, string windowId)
    {
        IntPtr hwnd = HandleOf(windowId);
        if (!NativeMethods.IsWindow(hwnd)) return null;
        try
        {
            return ReadAddress(hwnd) is { Length: > 0 } url ? url : null;
        }
        catch (Exception)
        {
            Forget(hwnd);
            return null;
        }
    }

    /// <summary>Presses the window's reload button. Throws when the button cannot be found or pressed.</summary>
    public void Reload(int processId, string windowId)
    {
        IntPtr hwnd = HandleOf(windowId);
        AutomationElement button = Element(hwnd, reloadButton: true) ?? throw new InvalidOperationException("The window has no reload button.");
        try
        {
            ((InvokePattern)button.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        }
        catch (Exception)
        {
            Forget(hwnd);
            throw;
        }
    }

    /// <summary>
    /// The address shown in a window's address bar with a scheme added where the browser hid it, or null while the bar has keyboard focus (the person may be typing) or the window has no address bar.
    /// </summary>
    private string? ReadAddress(IntPtr hwnd)
    {
        if (Element(hwnd, reloadButton: false) is not { } bar) return null;
        if (bar.Current.HasKeyboardFocus) return null;
        if (!bar.TryGetCurrentPattern(ValuePattern.Pattern, out object pattern)) return null;
        string text = ((ValuePattern)pattern).Current.Value;
        return BrowserAddress.ToUrl(text);
    }

    /// <summary>The window's address bar or reload button, found on first use and remembered.</summary>
    private AutomationElement? Element(IntPtr hwnd, bool reloadButton)
    {
        (AutomationElement? AddressBar, AutomationElement? ReloadButton) known;
        lock (_gate) _elements.TryGetValue(hwnd, out known);
        AutomationElement? found = reloadButton ? known.ReloadButton : known.AddressBar;
        if (found is not null) return found;
        lock (_gate)
        {
            if (_retryAfter.TryGetValue((hwnd, reloadButton), out long retry) && Environment.TickCount64 < retry) return null;
        }

        AutomationElement window = AutomationElement.FromHandle(hwnd);
        found = reloadButton ? Find(window, ReloadButtonClass, ControlType.Button) : Find(window, AddressBarClass, ControlType.Edit);
        lock (_gate)
        {
            // Chrome builds its accessibility tree only once a reader asks, so the first search can come up empty; the window is searched again later.
            if (found is null) _retryAfter[(hwnd, reloadButton)] = Environment.TickCount64 + RetryMilliseconds;
            else _retryAfter.Remove((hwnd, reloadButton));
        }
        if (found is null) return null;
        lock (_gate)
        {
            _elements.TryGetValue(hwnd, out known);
            _elements[hwnd] = reloadButton ? (known.AddressBar, found) : (found, known.ReloadButton);
        }
        return found;
    }

    /// <summary>
    /// Finds the first element below <paramref name="root"/> with the given class name and control type, searching the browser's own controls breadth first.
    /// Web page content (Document elements) is not searched, because the toolbar never lives there and a page's tree can be very large.
    /// </summary>
    private static AutomationElement? Find(AutomationElement root, string className, ControlType controlType)
    {
        TreeWalker walker = TreeWalker.ControlViewWalker;
        var queue = new Queue<AutomationElement>();
        queue.Enqueue(root);
        int visited = 0;
        while (queue.Count > 0 && visited < MaxSearchNodes)
        {
            AutomationElement parent = queue.Dequeue();
            AutomationElement? child = walker.GetFirstChild(parent);
            while (child is not null && visited < MaxSearchNodes)
            {
                visited++;
                AutomationElement.AutomationElementInformation info = child.Current;
                if (info.ClassName == className && info.ControlType == controlType) return child;
                if (info.ControlType != ControlType.Document) queue.Enqueue(child);
                child = walker.GetNextSibling(child);
            }
        }
        return null;
    }

    /// <summary>The display name of a supported browser process, or null for any other process. Names are cached by process id and start time.</summary>
    private string? DisplayNameOf(int processId)
    {
        try
        {
            using Process process = Process.GetProcessById(processId);
            DateTime started = process.StartTime;
            lock (_gate)
            {
                if (_processNames.TryGetValue(processId, out var cached) && cached.Started == started) return cached.Name;
            }
            string? name = Browsers.TryGetValue(process.ProcessName, out string? display) ? display : null;
            lock (_gate) _processNames[processId] = (started, name);
            return name;
        }
        catch (Exception)
        {
            // The process ended, or belongs to another account and cannot be inspected; either way it is not watched.
            return null;
        }
    }

    /// <summary>Drops the remembered elements of one window.</summary>
    private void Forget(IntPtr hwnd)
    {
        lock (_gate) _elements.Remove(hwnd);
    }

    /// <summary>The window id the tab watcher uses: the handle as a decimal number.</summary>
    private static string IdOf(IntPtr hwnd) => hwnd.ToInt64().ToString(CultureInfo.InvariantCulture);

    /// <summary>The handle back from a window id; zero for text that is not a number.</summary>
    private static IntPtr HandleOf(string windowId) => long.TryParse(windowId, NumberStyles.Integer, CultureInfo.InvariantCulture, out long value) ? new IntPtr(value) : IntPtr.Zero;
}

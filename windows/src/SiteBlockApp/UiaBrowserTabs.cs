using System.Diagnostics;
using System.Runtime.InteropServices;
using Accessibility;
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

    // The app's log, for a short report of what the reader saw. Every line holds counts and the browser's own control class names only, never an address, a domain or a path rule.
    private readonly IAppLog _log;
    // What the reads since the last listing found: addresses read, windows whose address bar was not found, and windows skipped because their address bar had focus.
    private int _passRead, _passNotFound, _passFocused;
    // The last summary line written, so a line is written only when something changed.
    private string _lastSummary = "";
    // When a failed address bar search was last described in the log (milliseconds since Windows started); one description a minute is enough.
    private long _lastSearchReport = long.MinValue;

    /// <summary>Creates the reader. <paramref name="log"/> receives a line when what the reader sees changes, and a description of a failed address bar search at most once a minute.</summary>
    public UiaBrowserTabs(IAppLog log) => _log = log;

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
        // One line when the picture changes: how many browser processes and windows there are, and what the reads since the last listing found.
        int windowCount = windows.Values.Sum(list => list.Count);
        string summary;
        lock (_gate)
        {
            summary = $"tab reader: {browsers.Count} browser processes with {windowCount} windows; last look read {_passRead} addresses, {_passNotFound} address bars not found, {_passFocused} skipped while focused";
            _passRead = _passNotFound = _passFocused = 0;
        }
        if (summary != _lastSummary)
        {
            _lastSummary = summary;
            _log.Info(summary);
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
                if (ReadAddress(hwnd) is { Length: > 0 } url)
                {
                    result.Add(new BrowserWindowAddress(IdOf(hwnd), url));
                    lock (_gate) _passRead++;
                }
            }
            catch (Exception error)
            {
                // This window closed or stopped answering; forget its elements and skip it this tick.
                Forget(hwnd);
                ReportOncePerMinute($"tab reader: reading a window failed ({error.GetType().Name})");
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
            Press(hwnd, button);
        }
        catch (Exception error)
        {
            Forget(hwnd);
            if (ShouldReport()) _log.Info($"tab reader: pressing the reload button failed ({error.GetType().Name}); {DescribeElement(button)}");
            throw;
        }
    }

    /// <summary>
    /// The address shown in a window's address bar with a scheme added where the browser hid it, or null while the bar has keyboard focus (the person may be typing) or the window has no address bar.
    /// </summary>
    private string? ReadAddress(IntPtr hwnd)
    {
        if (Element(hwnd, reloadButton: false) is not { } bar)
        {
            lock (_gate) _passNotFound++;
            return null;
        }
        if (bar.Current.HasKeyboardFocus)
        {
            lock (_gate) _passFocused++;
            return null;
        }
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
        if (found is null && ShouldReport()) _log.Info(DescribeSearch(window, reloadButton));
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

    /// <summary>True at most once a minute, for a description of a failed address bar search.</summary>
    private bool ShouldReport()
    {
        lock (_gate)
        {
            long now = Environment.TickCount64;
            if (_lastSearchReport != long.MinValue && now - _lastSearchReport < 60_000) return false;
            _lastSearchReport = now;
            return true;
        }
    }

    /// <summary>
    /// Presses a browser button. A button that offers UI Automation's Invoke pattern is invoked. Chrome's reload button does not: it offers only ExpandCollapse (which opens
    /// its menu) and ScrollItem, so it is pressed the way screen readers press it, through the older accessibility interface (MSAA), whose default action for a button is a
    /// press. The MSAA object is found by asking this window's own accessibility tree what lies at the button's centre, so a window lying on top never gets the press, and
    /// it is pressed only when it is a button. Throws when the button cannot be pressed.
    /// </summary>
    private static void Press(IntPtr hwnd, AutomationElement button)
    {
        if (button.TryGetCurrentPattern(InvokePattern.Pattern, out object invoke))
        {
            ((InvokePattern)invoke).Invoke();
            return;
        }
        // UI Automation and MSAA both give screen positions in physical pixels here, because the app is per-monitor DPI aware.
        System.Windows.Rect bounds = button.Current.BoundingRectangle;
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0) throw new InvalidOperationException("The reload button has no position on screen.");
        int x = (int)(bounds.Left + bounds.Width / 2);
        int y = (int)(bounds.Top + bounds.Height / 2);

        Guid accessibleId = AccessibleInterfaceId;
        int result = AccessibleObjectFromWindow(hwnd, ObjectIdClient, ref accessibleId, out object rootObject);
        if (result != 0 || rootObject is not IAccessible root) throw new InvalidOperationException($"The window's accessibility object could not be read (0x{result:X8}).");
        // accHitTest answers with the object at the point, or with a child number of the object it was asked on, or with nothing.
        object hit = root.accHitTest(x, y);
        (IAccessible target, object child) = hit switch
        {
            IAccessible element => (element, (object)ChildSelf),
            int childNumber when childNumber != ChildSelf => (root, childNumber),
            _ => throw new InvalidOperationException("Nothing in the window lies at the reload button's position."),
        };
        int role = Convert.ToInt32(target.get_accRole(child), System.Globalization.CultureInfo.InvariantCulture);
        if (!ButtonRoles.Contains(role)) throw new InvalidOperationException($"The object at the reload button's position is not a button (MSAA role {role}).");
        target.accDoDefaultAction(child);
    }

    // IID_IAccessible, the MSAA interface asked for from the window.
    private static readonly Guid AccessibleInterfaceId = new("618736E0-3C3D-11CF-810C-00AA00389B71");
    // OBJID_CLIENT: the window's content (for Chrome, its whole accessibility tree), rather than its frame.
    private const uint ObjectIdClient = 0xFFFFFFFC;
    // CHILDID_SELF: "the object itself" when calling an MSAA method.
    private const int ChildSelf = 0;
    // The MSAA roles of a button: push button (0x2B), button with drop-down (0x38), button with menu (0x39) and split button (0x3E).
    private static readonly HashSet<int> ButtonRoles = [0x2B, 0x38, 0x39, 0x3E];

    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint objectId, ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object accessible);

    /// <summary>Describes one control for the log: its class name, control type, whether it is enabled, and the UI Automation patterns (abilities, such as Invoke or Toggle) it offers. No text from the control is included.</summary>
    private static string DescribeElement(AutomationElement element)
    {
        try
        {
            AutomationElement.AutomationElementInformation info = element.Current;
            string patterns = string.Join(", ", element.GetSupportedPatterns().Select(pattern => pattern.ProgrammaticName));
            return $"the button is {info.ClassName}/{info.ControlType.ProgrammaticName}, enabled={info.IsEnabled}, patterns: [{patterns}]";
        }
        catch (Exception error)
        {
            return $"describing the button failed ({error.GetType().Name})";
        }
    }

    /// <summary>Writes a line at most once a minute (shared with the search description).</summary>
    private void ReportOncePerMinute(string line)
    {
        if (ShouldReport()) _log.Info(line);
    }

    /// <summary>
    /// Describes what a failed search for the address bar or the reload button saw, for the log: how many elements the browser's own controls hold (up to 400), the
    /// class names of its first-level children, and those of every edit control (for the address bar) or every button-like control (for the reload button), outside web
    /// page content. These are the browser's control names, never page text or an address.
    /// </summary>
    private static string DescribeSearch(AutomationElement root, bool reloadButton)
    {
        string what = reloadButton ? "reload button" : "address bar";
        TreeWalker walker = TreeWalker.ControlViewWalker;
        var top = new List<string>();
        var edits = new List<string>();
        var queue = new Queue<(AutomationElement Element, int Depth)>();
        queue.Enqueue((root, 0));
        int visited = 0;
        try
        {
            while (queue.Count > 0 && visited < 400)
            {
                var (parent, depth) = queue.Dequeue();
                AutomationElement? child = walker.GetFirstChild(parent);
                while (child is not null && visited < 400)
                {
                    visited++;
                    AutomationElement.AutomationElementInformation info = child.Current;
                    string label = $"{info.ClassName}/{info.ControlType.ProgrammaticName.Replace("ControlType.", "", StringComparison.Ordinal)}";
                    if (depth == 0 && top.Count < 10) top.Add(label);
                    bool wanted = reloadButton
                        ? info.ControlType == ControlType.Button || info.ControlType == ControlType.SplitButton || info.ControlType == ControlType.MenuItem
                        : info.ControlType == ControlType.Edit;
                    if (wanted && edits.Count < 15) edits.Add(label);
                    if (info.ControlType != ControlType.Document) queue.Enqueue((child, depth + 1));
                    child = walker.GetNextSibling(child);
                }
            }
        }
        catch (Exception error)
        {
            return $"tab reader: no {what} found; describing the window failed after {visited} elements ({error.GetType().Name})";
        }
        return $"tab reader: no {what} found among {visited} elements; top level: [{string.Join(", ", top)}]; {(reloadButton ? "buttons" : "edit controls")}: [{string.Join(", ", edits)}]";
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

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;
using SiteBlock.App.Views;
using SiteBlock.AppLogic;

namespace SiteBlock.App;

/// <summary>
/// The borderless panel that opens above the tray, 440 pixels wide, and hides when it loses focus, like the Windows clock and volume flyouts.
/// On Windows 11 22H2 and later it shows the Mica backdrop with rounded corners; earlier Windows 11 gets rounded corners on a solid color; Windows 10 gets a solid light or dark background.
/// It follows the Windows light or dark app mode and switches as soon as that setting changes.
/// </summary>
internal sealed class PanelWindow : Window
{
    /// <summary>The panel's width at 100% scaling.</summary>
    public const double PanelWidth = 440;

    /// <summary>The gap between the panel and the screen edges and taskbar.</summary>
    private const double EdgeGap = 12;

    private readonly PanelModel _model;
    private readonly PanelView _view;
    private readonly DispatcherTimer _countdownTimer;
    private bool _dark;
    private long _hiddenAt;

    /// <summary>Raised after the light or dark mode changed, so the tray icon can follow the taskbar's colors.</summary>
    public event Action? ThemeChanged;

    /// <summary>Creates the (hidden) panel for the model.</summary>
    public PanelWindow(PanelModel model)
    {
        _model = model;
        Title = PanelModel.AppName;
        Width = PanelWidth;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        FontFamily = Theme.UiFont;
        FontSize = Ui.BodySize;
        UseLayoutRounding = true;
        SetResourceReference(ForegroundProperty, ThemeKeys.Text);
        _dark = Theme.AppsUseDarkMode();
        Theme.Apply(Resources, _dark);

        if (Theme.IsWindows11)
        {
            // The window keeps a real frame so Windows draws its shadow, rounded corners and backdrop; the chrome settings make that frame cover the whole window with no title bar.
            WindowStyle = WindowStyle.SingleBorderWindow;
            WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, GlassFrameThickness = new Thickness(-1), ResizeBorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false });
        }
        else
        {
            WindowStyle = WindowStyle.None;
            BorderThickness = new Thickness(1);
            SetResourceReference(BorderBrushProperty, ThemeKeys.CardEdge);
        }
        SetResourceReference(BackgroundProperty, ThemeKeys.PanelBackground);

        _view = new PanelView(model);
        Content = _view;

        // Live countdowns tick once a second while the panel is open.
        _countdownTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
        _countdownTimer.Tick += (_, _) => _view.RequestUpdate();

        SourceInitialized += (_, _) => ConfigureWindow();
        Deactivated += (_, _) => HidePanel();
        SizeChanged += (_, _) => PlaceAboveTray();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            HidePanel();
        };
    }

    /// <summary>True when the panel was hidden in the last 300 milliseconds. A click on the tray icon first takes focus from the panel (which hides it), so that click must not open it again.</summary>
    public bool JustHidden => Environment.TickCount64 - _hiddenAt < 300;

    /// <summary>Shows the panel above the tray, brings it to the front with keyboard focus, and tells the model it is open (which polls every second).</summary>
    public void ShowPanel(bool settings = false)
    {
        if (settings && _model.Status.Snapshot?.PasswordSet == true) _model.OpenSettings();
        if (!IsVisible)
        {
            Show();
            _ = _model.PanelVisibilityChangedAsync(true);
            _countdownTimer.Start();
        }
        PlaceAboveTray();
        Activate();
        NativeMethods.SetForegroundWindow(new WindowInteropHelper(this).Handle);
        _view.RequestUpdate();
    }

    /// <summary>Hides the panel and tells the model, which forgets everything typed and polls every 30 seconds again.</summary>
    public void HidePanel()
    {
        if (!IsVisible) return;
        _hiddenAt = Environment.TickCount64;
        _countdownTimer.Stop();
        Hide();
        _ = _model.PanelVisibilityChangedAsync(false);
        _view.Reset();
    }

    /// <summary>Opens the panel when it is closed and closes it when it is open (a left click on the tray icon).</summary>
    public void Toggle()
    {
        if (IsVisible) HidePanel();
        else if (!JustHidden) ShowPanel();
    }

    /// <summary>
    /// Places the panel in the corner by the tray: above the taskbar when it is at the bottom, below it at the top, and beside it on the left or right. The edge is found by comparing the work area (the screen minus the taskbar) with the whole primary screen.
    /// </summary>
    private void PlaceAboveTray()
    {
        Rect work = SystemParameters.WorkArea;
        double screenWidth = SystemParameters.PrimaryScreenWidth;
        double screenHeight = SystemParameters.PrimaryScreenHeight;
        MaxHeight = Math.Max(200, work.Height - 2 * EdgeGap);
        double width = ActualWidth > 0 ? ActualWidth : PanelWidth;
        double height = ActualHeight > 0 ? ActualHeight : 400;
        bool taskbarTop = work.Top > 0.5;
        bool taskbarLeft = work.Left > 0.5;
        // The tray sits at the right end of a horizontal taskbar and the bottom of a vertical one (the left-edge taskbar keeps the panel on the left).
        Left = taskbarLeft ? work.Left + EdgeGap : work.Right - width - EdgeGap;
        Top = taskbarTop ? work.Top + EdgeGap : work.Bottom - height - EdgeGap;
        // Guard against odd work areas (an auto-hiding taskbar reports the whole screen).
        Left = Math.Clamp(Left, 0, Math.Max(0, screenWidth - width));
        Top = Math.Clamp(Top, 0, Math.Max(0, screenHeight - height));
    }

    /// <summary>Once the window has a handle: hides it from Alt+Tab, applies the backdrop, corners and dark frame, and listens for the light or dark mode changing.</summary>
    private void ConfigureWindow()
    {
        IntPtr hwnd = new WindowInteropHelper(this).Handle;
        long exStyle = NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GwlExStyle).ToInt64();
        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GwlExStyle, new IntPtr(exStyle | NativeMethods.WsExToolWindow));
        if (HwndSource.FromHwnd(hwnd) is { } source)
        {
            if (Theme.SupportsMica && source.CompositionTarget is { } target) target.BackgroundColor = Colors.Transparent;
            source.AddHook(WndProc);
        }
        ApplyFrame(hwnd);
    }

    /// <summary>Sets the window's dark frame, rounded corners and Mica backdrop (each only where Windows supports it). If Mica cannot be set, the panel falls back to a solid background.</summary>
    private void ApplyFrame(IntPtr hwnd)
    {
        if (!Theme.IsWindows11) return;
        int dark = _dark ? 1 : 0;
        NativeMethods.DwmSetWindowAttribute(hwnd, NativeMethods.DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
        int corners = NativeMethods.DwmwcpRound;
        NativeMethods.DwmSetWindowAttribute(hwnd, NativeMethods.DwmwaWindowCornerPreference, ref corners, sizeof(int));
        if (!Theme.SupportsMica) return;
        var margins = new NativeMethods.Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        NativeMethods.DwmExtendFrameIntoClientArea(hwnd, ref margins);
        int backdrop = NativeMethods.DwmsbtMainWindow;
        if (NativeMethods.DwmSetWindowAttribute(hwnd, NativeMethods.DwmwaSystemBackdropType, ref backdrop, sizeof(int)) != 0)
        {
            // A see-through window without the backdrop would be black, so a solid color is used instead.
            Resources[ThemeKeys.PanelBackground] = new SolidColorBrush(_dark ? Color.FromRgb(0x20, 0x20, 0x20) : Color.FromRgb(0xF3, 0xF3, 0xF3));
        }
    }

    /// <summary>Watches for the "ImmersiveColorSet" setting change Windows sends when light or dark mode changes, and recolors the panel at once.</summary>
    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == NativeMethods.WmSettingChange && lParam != IntPtr.Zero && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            bool dark = Theme.AppsUseDarkMode();
            if (dark != _dark)
            {
                _dark = dark;
                Theme.Apply(Resources, dark);
                ApplyFrame(hwnd);
            }
            ThemeChanged?.Invoke();
        }
        return IntPtr.Zero;
    }
}

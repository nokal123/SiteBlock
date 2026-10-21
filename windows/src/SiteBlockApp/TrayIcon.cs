using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace SiteBlock.App;

/// <summary>
/// The shield in the notification area. A left click opens or closes the panel; the right-click menu has "Open SiteBlock" and "Settings" and no Exit, because the app always stays running.
/// The shield is drawn in code: half filled normally, and outlined with a slash when the service cannot be reached. It is black on a light taskbar and white on a dark one.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _notifyIcon;
    private readonly Forms.ContextMenuStrip _menu;
    private Drawing.Icon? _current;
    private (bool Slashed, bool LightTaskbar, int Size)? _shown;

    /// <summary>Raised by a left click on the icon.</summary>
    public event Action? Clicked;

    /// <summary>Raised by "Open SiteBlock" in the menu.</summary>
    public event Action? OpenRequested;

    /// <summary>Raised by "Settings" in the menu.</summary>
    public event Action? SettingsRequested;

    /// <summary>Creates the icon and its menu and shows it.</summary>
    public TrayIcon()
    {
        _menu = new Forms.ContextMenuStrip();
        var open = new Forms.ToolStripMenuItem("Open SiteBlock") { Font = new Drawing.Font(Forms.Control.DefaultFont, Drawing.FontStyle.Bold) };
        open.Click += (_, _) => OpenRequested?.Invoke();
        var settings = new Forms.ToolStripMenuItem("Settings");
        settings.Click += (_, _) => SettingsRequested?.Invoke();
        _menu.Items.Add(open);
        _menu.Items.Add(settings);

        _notifyIcon = new Forms.NotifyIcon { Text = "SiteBlock", ContextMenuStrip = _menu };
        _notifyIcon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) Clicked?.Invoke();
        };
        Update(slashed: false);
        _notifyIcon.Visible = true;
    }

    /// <summary>Redraws the shield for the service's state and the taskbar's current colors, when either changed.</summary>
    public void Update(bool slashed)
    {
        bool light = Theme.TaskbarIsLight();
        int size = Forms.SystemInformation.SmallIconSize.Width;
        if (_shown == (slashed, light, size)) return;
        _shown = (slashed, light, size);
        Drawing.Icon icon = ShieldIcon.Create(slashed, light, size);
        _notifyIcon.Icon = icon;
        _current?.Dispose();
        _current = icon;
    }

    /// <summary>Removes the icon from the notification area.</summary>
    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _menu.Dispose();
        _current?.Dispose();
    }
}

/// <summary>Draws the tray shield as an icon of any size.</summary>
internal static class ShieldIcon
{
    /// <summary>
    /// A shield on a 16-unit grid scaled to <paramref name="size"/> pixels: its outline, with the left half filled (like the Mac's half-filled shield), or, when <paramref name="slashed"/>, only the outline crossed by a slash.
    /// It is black for a light taskbar and white for a dark one.
    /// </summary>
    public static Drawing.Icon Create(bool slashed, bool lightTaskbar, int size)
    {
        size = Math.Max(16, size);
        float unit = size / 16f;
        using var bitmap = new Drawing.Bitmap(size, size, Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (Drawing.Graphics graphics = Drawing.Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            graphics.Clear(Drawing.Color.Transparent);
            Drawing.Color color = lightTaskbar ? Drawing.Color.FromArgb(255, 0, 0, 0) : Drawing.Color.FromArgb(255, 255, 255, 255);
            using var pen = new Drawing.Pen(color, 1.3f * unit) { LineJoin = Drawing.Drawing2D.LineJoin.Round, StartCap = Drawing.Drawing2D.LineCap.Round, EndCap = Drawing.Drawing2D.LineCap.Round };
            using var brush = new Drawing.SolidBrush(color);
            using Drawing.Drawing2D.GraphicsPath shield = ShieldPath(unit);
            if (!slashed)
            {
                graphics.SetClip(new Drawing.RectangleF(0, 0, 8f * unit, size));
                graphics.FillPath(brush, shield);
                graphics.ResetClip();
            }
            graphics.DrawPath(pen, shield);
            if (slashed) graphics.DrawLine(pen, 1.6f * unit, 1.6f * unit, 14.4f * unit, 14.4f * unit);
        }
        IntPtr handle = bitmap.GetHicon();
        try
        {
            using Drawing.Icon borrowed = Drawing.Icon.FromHandle(handle);
            // The clone owns its own copy, so the handle from GetHicon can be freed at once.
            return (Drawing.Icon)borrowed.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(handle);
        }
    }

    /// <summary>The shield's outline: a flat-topped crest that curves down to a point.</summary>
    private static Drawing.Drawing2D.GraphicsPath ShieldPath(float unit)
    {
        var path = new Drawing.Drawing2D.GraphicsPath();
        path.StartFigure();
        path.AddLine(8f * unit, 1.5f * unit, 13.8f * unit, 3.4f * unit);
        path.AddLine(13.8f * unit, 3.4f * unit, 13.8f * unit, 8f * unit);
        path.AddBezier(13.8f * unit, 8f * unit, 13.8f * unit, 11.4f * unit, 11f * unit, 13.6f * unit, 8f * unit, 14.7f * unit);
        path.AddBezier(8f * unit, 14.7f * unit, 5f * unit, 13.6f * unit, 2.2f * unit, 11.4f * unit, 2.2f * unit, 8f * unit);
        path.AddLine(2.2f * unit, 8f * unit, 2.2f * unit, 3.4f * unit);
        path.CloseFigure();
        return path;
    }
}

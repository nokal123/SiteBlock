using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using SiteBlock.AppLogic;

namespace SiteBlock.App;

/// <summary>The names of the colors the panel uses. Every element refers to these names, so switching between light and dark mode only replaces the colors behind them.</summary>
internal static class ThemeKeys
{
    public const string PanelBackground = "SB.PanelBackground";
    public const string Clear = "SB.Clear";
    public const string Text = "SB.Text";
    public const string TextSecondary = "SB.TextSecondary";
    public const string TextTertiary = "SB.TextTertiary";
    public const string CardFill = "SB.CardFill";
    public const string CardEdge = "SB.CardEdge";
    public const string Divider = "SB.Divider";
    public const string Accent = "SB.Accent";
    public const string AccentHover = "SB.AccentHover";
    public const string AccentText = "SB.AccentText";
    public const string ControlFill = "SB.ControlFill";
    public const string ControlFillHover = "SB.ControlFillHover";
    public const string ControlFillPressed = "SB.ControlFillPressed";
    public const string ControlEdge = "SB.ControlEdge";
    public const string InputFill = "SB.InputFill";
    public const string InputEdge = "SB.InputEdge";
    public const string SubtleHover = "SB.SubtleHover";
    public const string Error = "SB.Error";
    public const string Success = "SB.Success";
    public const string Warning = "SB.Warning";
    public const string ScrollThumb = "SB.ScrollThumb";
    public const string ToneButtonText = "SB.ToneButtonText";

    /// <summary>The full-strength color of a row tone.</summary>
    public static string ToneAccent(SiteTone tone) => $"SB.Tone.{tone}.Accent";
    /// <summary>The wash behind a tinted row.</summary>
    public static string ToneFill(SiteTone tone) => $"SB.Tone.{tone}.Fill";
    /// <summary>The edge of a tinted row.</summary>
    public static string ToneEdge(SiteTone tone) => $"SB.Tone.{tone}.Edge";
    /// <summary>The fill of a filled button in a tone.</summary>
    public static string ToneButton(SiteTone tone) => $"SB.Tone.{tone}.Button";
    /// <summary>The color of a banner's icon.</summary>
    public static string BannerAccent(BannerTint tint) => $"SB.Banner.{tint}.Accent";
    /// <summary>The wash behind a banner.</summary>
    public static string BannerFill(BannerTint tint) => $"SB.Banner.{tint}.Fill";
    /// <summary>The edge of a banner.</summary>
    public static string BannerEdge(BannerTint tint) => $"SB.Banner.{tint}.Edge";
}

/// <summary>
/// Reads the Windows light or dark app mode and fills a resource dictionary with the matching colors, fonts and glyphs.
/// Windows 11 gets the Segoe UI Variable font and Segoe Fluent Icons; Windows 10 gets Segoe UI and Segoe MDL2 Assets.
/// </summary>
internal static class Theme
{
    /// <summary>Where Windows keeps the light and dark mode switches for apps and for the taskbar.</summary>
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>True on Windows 11 (build 22000 or later), which has rounded window corners and the Fluent fonts.</summary>
    public static bool IsWindows11 { get; } = Environment.OSVersion.Version.Build >= 22000;

    /// <summary>True on Windows 11 22H2 (build 22621) or later, the first version with the Mica backdrop setting.</summary>
    public static bool SupportsMica { get; } = Environment.OSVersion.Version.Build >= 22621;

    /// <summary>The text font: Segoe UI Variable on Windows 11 (falling back to Segoe UI), Segoe UI on Windows 10.</summary>
    public static FontFamily UiFont { get; } = new(IsWindows11 ? "Segoe UI Variable Text, Segoe UI" : "Segoe UI");

    /// <summary>The icon font: Segoe Fluent Icons on Windows 11 (falling back to Segoe MDL2 Assets), Segoe MDL2 Assets on Windows 10.</summary>
    public static FontFamily IconFont { get; } = new(IsWindows11 ? "Segoe Fluent Icons, Segoe MDL2 Assets" : "Segoe MDL2 Assets");

    /// <summary>The font for host names.</summary>
    public static FontFamily MonoFont { get; } = new("Cascadia Mono, Consolas");

    /// <summary>True when Windows is set to dark mode for apps (AppsUseLightTheme is 0). A missing or unreadable value means light.</summary>
    public static bool AppsUseDarkMode() => ReadPersonalizeFlag("AppsUseLightTheme") == 0;

    /// <summary>True when the taskbar and tray are light (SystemUsesLightTheme is 1), which needs a dark tray icon.</summary>
    public static bool TaskbarIsLight() => ReadPersonalizeFlag("SystemUsesLightTheme") == 1;

    /// <summary>Reads one DWORD under the Personalize key, or -1 when it is missing or unreadable.</summary>
    private static int ReadPersonalizeFlag(string name)
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue(name) is int value ? value : -1;
        }
        catch (Exception)
        {
            return -1;
        }
    }

    /// <summary>Fills <paramref name="resources"/> with the light or dark colors. Elements that refer to the keys with SetResourceReference change color at once.</summary>
    public static void Apply(ResourceDictionary resources, bool dark)
    {
        // A see-through panel on Windows 11 22H2 shows the Mica material; Windows 10 and early Windows 11 get the system's solid flyout color.
        resources[ThemeKeys.PanelBackground] = SupportsMica ? Brush(0x000000, 0) : Brush(dark ? 0x202020u : 0xF3F3F3u);
        resources[ThemeKeys.Clear] = Brush(0x000000, 0);
        resources[ThemeKeys.Text] = dark ? Brush(0xFFFFFF) : Brush(0x1A1A1A);
        resources[ThemeKeys.TextSecondary] = dark ? Brush(0xFFFFFF, 0.72) : Brush(0x000000, 0.62);
        resources[ThemeKeys.TextTertiary] = dark ? Brush(0xFFFFFF, 0.5) : Brush(0x000000, 0.45);
        resources[ThemeKeys.CardFill] = dark ? Brush(0xFFFFFF, 0.06) : Brush(0x000000, 0.06);
        resources[ThemeKeys.CardEdge] = dark ? Brush(0xFFFFFF, 0.08) : Brush(0x000000, 0.08);
        resources[ThemeKeys.Divider] = dark ? Brush(0xFFFFFF, 0.1) : Brush(0x000000, 0.1);
        resources[ThemeKeys.Accent] = dark ? Brush(0x60CDFF) : Brush(0x005FB8);
        resources[ThemeKeys.AccentHover] = dark ? Brush(0x5AB9E6) : Brush(0x196EBF);
        resources[ThemeKeys.AccentText] = dark ? Brush(0x000000) : Brush(0xFFFFFF);
        resources[ThemeKeys.ControlFill] = dark ? Brush(0xFFFFFF, 0.08) : Brush(0xFFFFFF, 0.75);
        resources[ThemeKeys.ControlFillHover] = dark ? Brush(0xFFFFFF, 0.12) : Brush(0xF9F9F9, 0.6);
        resources[ThemeKeys.ControlFillPressed] = dark ? Brush(0xFFFFFF, 0.05) : Brush(0xF9F9F9, 0.35);
        resources[ThemeKeys.ControlEdge] = dark ? Brush(0xFFFFFF, 0.1) : Brush(0x000000, 0.12);
        resources[ThemeKeys.InputFill] = dark ? Brush(0xFFFFFF, 0.06) : Brush(0xFFFFFF, 0.8);
        resources[ThemeKeys.InputEdge] = dark ? Brush(0xFFFFFF, 0.14) : Brush(0x000000, 0.16);
        resources[ThemeKeys.SubtleHover] = dark ? Brush(0xFFFFFF, 0.08) : Brush(0x000000, 0.05);
        resources[ThemeKeys.Error] = dark ? Brush(0xFF99A4) : Brush(0xC42B1C);
        resources[ThemeKeys.Success] = dark ? Brush(0x6CCB5F) : Brush(0x0F7B0F);
        resources[ThemeKeys.Warning] = dark ? Brush(0xFF9F0A) : Brush(0xC75C00);
        resources[ThemeKeys.ScrollThumb] = dark ? Brush(0xFFFFFF, 0.45) : Brush(0x000000, 0.4);
        resources[ThemeKeys.ToneButtonText] = Brush(0xFFFFFF);

        // The row tones use the exact shades from ToneColors.
        foreach (SiteTone tone in new[] { SiteTone.Blocked, SiteTone.Open })
        {
            resources[ThemeKeys.ToneAccent(tone)] = Brush(ToneColors.Accent(tone, dark)!.Value);
            resources[ThemeKeys.ToneFill(tone)] = Brush(ToneColors.Fill(tone, dark)!.Value);
            resources[ThemeKeys.ToneEdge(tone)] = Brush(ToneColors.Edge(tone, dark)!.Value);
            resources[ThemeKeys.ToneButton(tone)] = Brush(ToneColors.ButtonFill(tone, dark)!.Value);
        }
        // A plain row has no tone: the gray card and the secondary text color.
        resources[ThemeKeys.ToneAccent(SiteTone.Neutral)] = resources[ThemeKeys.TextSecondary];
        resources[ThemeKeys.ToneFill(SiteTone.Neutral)] = resources[ThemeKeys.CardFill];
        resources[ThemeKeys.ToneEdge(SiteTone.Neutral)] = resources[ThemeKeys.CardEdge];
        resources[ThemeKeys.ToneButton(SiteTone.Neutral)] = resources[ThemeKeys.Accent];

        // Banner boxes: the tint at 12% with a 35% edge, the icon at full strength.
        (BannerTint Tint, uint Light, uint Dark)[] banners = [(BannerTint.Red, 0xC42B1C, 0xFF6B60), (BannerTint.Orange, 0xC75C00, 0xFF9F0A), (BannerTint.Blue, 0x005FB8, 0x60CDFF)];
        foreach (var (tint, light, darkShade) in banners)
        {
            uint shade = dark ? darkShade : light;
            resources[ThemeKeys.BannerAccent(tint)] = Brush(shade);
            resources[ThemeKeys.BannerFill(tint)] = Brush(shade, 0.12);
            resources[ThemeKeys.BannerEdge(tint)] = Brush(shade, 0.35);
        }
    }

    /// <summary>A frozen brush of 0xRRGGBB at the given opacity.</summary>
    private static SolidColorBrush Brush(uint rgb, double opacity = 1) => Brush(Argb.FromHex(rgb, opacity));

    /// <summary>A frozen brush of an exact color.</summary>
    private static SolidColorBrush Brush(Argb color)
    {
        var brush = new SolidColorBrush(Color.FromArgb(color.A, color.R, color.G, color.B));
        brush.Freeze();
        return brush;
    }
}

/// <summary>The glyphs used from the icon font (the same code points exist in Segoe Fluent Icons and Segoe MDL2 Assets).</summary>
internal static class Glyphs
{
    public const string Shield = "";
    public const string Lock = "";
    public const string Unlock = "";
    public const string Clock = "";
    public const string Timer = "";
    public const string Settings = "";
    public const string Back = "";
    public const string ChevronRight = "";
    public const string ChevronDown = "";
    public const string Warning = "";
    public const string Error = "";
    public const string Completed = "";
    public const string Key = "";
    public const string Delete = "";
    public const string Download = "";
}

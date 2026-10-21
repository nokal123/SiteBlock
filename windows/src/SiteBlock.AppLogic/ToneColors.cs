namespace SiteBlock.AppLogic;

/// <summary>A color as 8-bit alpha, red, green and blue, so the exact shades can be tested without a window.</summary>
/// <param name="A">Opacity, 0 to 255.</param>
/// <param name="R">Red, 0 to 255.</param>
/// <param name="G">Green, 0 to 255.</param>
/// <param name="B">Blue, 0 to 255.</param>
public readonly record struct Argb(byte A, byte R, byte G, byte B)
{
    /// <summary>The color 0xRRGGBB at the given opacity (0 to 1), rounding the opacity to the nearest step with halves rounded up.</summary>
    public static Argb FromHex(uint rgb, double opacity = 1) =>
        new((byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255, MidpointRounding.AwayFromZero), (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));
}

/// <summary>
/// The exact colors of the row tones, the same as the Mac's: brick red #9E3A2F (light) / #E08A78 (dark) and pine green #3D6B4A / #8CC29B at full strength for the lock and the countdown line;
/// the box at 7% (light) / 13% (dark) with a one-pixel edge at 22% / 30%; and the filled "Keep blocked" / "Block now" button in #9E3A2F (light) / #B04A3D (dark), darker in dark mode so its white label stays readable.
/// </summary>
public static class ToneColors
{
    /// <summary>Brick red in light mode.</summary>
    public const uint BlockedLight = 0x9E3A2F;
    /// <summary>Brick red in dark mode.</summary>
    public const uint BlockedDark = 0xE08A78;
    /// <summary>Pine green in light mode.</summary>
    public const uint OpenLight = 0x3D6B4A;
    /// <summary>Pine green in dark mode.</summary>
    public const uint OpenDark = 0x8CC29B;
    /// <summary>The blocked button fill in light mode.</summary>
    public const uint BlockedButtonLight = 0x9E3A2F;
    /// <summary>The blocked button fill in dark mode.</summary>
    public const uint BlockedButtonDark = 0xB04A3D;
    /// <summary>The open button fill in light mode.</summary>
    public const uint OpenButtonLight = 0x3D6B4A;
    /// <summary>The open button fill in dark mode.</summary>
    public const uint OpenButtonDark = 0x3F7A52;

    /// <summary>The full-strength color of a tone, for the lock and the countdown line. Neutral has none and returns null.</summary>
    public static Argb? Accent(SiteTone tone, bool dark) => tone switch
    {
        SiteTone.Blocked => Argb.FromHex(dark ? BlockedDark : BlockedLight),
        SiteTone.Open => Argb.FromHex(dark ? OpenDark : OpenLight),
        _ => null,
    };

    /// <summary>The wash behind a tinted row: the tone at 7% in light mode and 13% in dark mode. Neutral returns null (the gray card is used).</summary>
    public static Argb? Fill(SiteTone tone, bool dark) => Tinted(tone, dark, dark ? 0.13 : 0.07);

    /// <summary>The one-pixel edge of a tinted row: the tone at 22% in light mode and 30% in dark mode. Neutral returns null.</summary>
    public static Argb? Edge(SiteTone tone, bool dark) => Tinted(tone, dark, dark ? 0.30 : 0.22);

    /// <summary>The fill of a filled button in a tone (white label). Neutral returns null.</summary>
    public static Argb? ButtonFill(SiteTone tone, bool dark) => tone switch
    {
        SiteTone.Blocked => Argb.FromHex(dark ? BlockedButtonDark : BlockedButtonLight),
        SiteTone.Open => Argb.FromHex(dark ? OpenButtonDark : OpenButtonLight),
        _ => null,
    };

    /// <summary>The tone's accent at the given opacity, or null for neutral.</summary>
    private static Argb? Tinted(SiteTone tone, bool dark, double opacity) => tone switch
    {
        SiteTone.Blocked => Argb.FromHex(dark ? BlockedDark : BlockedLight, opacity),
        SiteTone.Open => Argb.FromHex(dark ? OpenDark : OpenLight, opacity),
        _ => null,
    };
}

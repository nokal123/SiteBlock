using System.Text;

namespace SiteBlock.Core;

/// <summary>
/// Converts a single Unicode domain label into the ASCII "xn--" form defined by RFC 3492, so international names can travel through systems that only understand ASCII.
/// It applies no IDNA mapping rules (the extra rules that fold look-alike characters); the caller lowercases the label first.
/// </summary>
public static class Punycode
{
    // The fixed parameters from RFC 3492 section 5.
    private const uint Base = 36;
    private const uint TMin = 1;
    private const uint TMax = 26;
    private const uint Skew = 38;
    private const uint Damp = 700;
    private const uint InitialBias = 72;
    private const uint InitialN = 128;

    /// <summary>Recomputes the bias after each encoded value; the bias controls how many digits the next value needs, which keeps typical output short.</summary>
    private static uint Adapt(uint delta, uint numPoints, bool firstTime)
    {
        delta = firstTime ? delta / Damp : delta / 2;
        delta += delta / numPoints;
        uint k = 0;
        while (delta > ((Base - TMin) * TMax) / 2)
        {
            delta /= Base - TMin;
            k += Base;
        }
        return k + (Base - TMin + 1) * delta / (delta + Skew);
    }

    /// <summary>Turns a digit value 0-35 into its output character: 0-25 become a-z and 26-35 become 0-9.</summary>
    private static char EncodeDigit(uint digit) => (char)(digit < 26 ? 97 + digit : 22 + digit);

    /// <summary>Encodes one label (already lowercased by the caller) and returns it without the "xn--" prefix, or null when the arithmetic would overflow.</summary>
    public static string? Encode(string label)
    {
        ArgumentNullException.ThrowIfNull(label);
        return Encode(SwiftText.Scalars(label));
    }

    /// <summary>Encodes a label given as Unicode scalars; the shared body of both public entry points.</summary>
    internal static string? Encode(ReadOnlySpan<int> input)
    {
        var output = new StringBuilder();
        // Plain ASCII characters are copied through first, in their original order.
        foreach (int value in input)
        {
            if (value < 0x80) output.Append((char)value);
        }
        uint basicCount = (uint)output.Length;
        uint handled = basicCount;
        // The delimiter only appears when there is at least one plain character to separate from the encoded part.
        if (basicCount > 0) output.Append('-');
        uint n = InitialN;
        uint delta = 0;
        uint bias = InitialBias;
        uint total = (uint)input.Length;
        while (handled < total)
        {
            // The next code point to encode is the smallest one at or above n; one always exists while handled < total.
            uint? smallest = null;
            foreach (int value in input)
            {
                uint candidate = (uint)value;
                if (candidate >= n && (smallest is null || candidate < smallest.Value)) smallest = candidate;
            }
            if (smallest is not uint m) return null;
            // The overflow checks mirror Swift's multipliedReportingOverflow and addingReportingOverflow on 32-bit unsigned values.
            ulong step = (ulong)(m - n) * (handled + 1);
            if (step > uint.MaxValue) return null;
            ulong grown = (ulong)delta + step;
            if (grown > uint.MaxValue) return null;
            delta = (uint)grown;
            n = m;
            foreach (int value in input)
            {
                uint current = (uint)value;
                if (current < n)
                {
                    if (delta == uint.MaxValue) return null;
                    delta++;
                }
                if (current == n)
                {
                    // Write delta as a variable-length number whose digit thresholds depend on the current bias.
                    uint q = delta;
                    uint k = Base;
                    while (true)
                    {
                        uint t = k <= bias ? TMin : (k >= bias + TMax ? TMax : k - bias);
                        if (q < t) break;
                        output.Append(EncodeDigit(t + (q - t) % (Base - t)));
                        q = (q - t) / (Base - t);
                        k += Base;
                    }
                    output.Append(EncodeDigit(q));
                    bias = Adapt(delta, handled + 1, handled == basicCount);
                    delta = 0;
                    handled++;
                }
            }
            if (delta == uint.MaxValue) return null;
            delta++;
            n++;
        }
        return output.ToString();
    }

    /// <summary>Returns the label unchanged when it is pure ASCII, otherwise "xn--" followed by the encoded form, or null when encoding overflows.</summary>
    public static string? ToAscii(string label)
    {
        ArgumentNullException.ThrowIfNull(label);
        int[] scalars = SwiftText.Scalars(label);
        if (Array.TrueForAll(scalars, s => s < 0x80)) return label;
        return ToAscii(scalars);
    }

    /// <summary>The scalar form of <see cref="ToAscii(string)"/>, used by the normalizer on labels it has already split.</summary>
    internal static string? ToAscii(ReadOnlySpan<int> scalars)
    {
        bool ascii = true;
        foreach (int s in scalars)
        {
            if (s >= 0x80) { ascii = false; break; }
        }
        if (ascii) return SwiftText.FromScalars(scalars);
        string? encoded = Encode(scalars);
        return encoded is null ? null : "xn--" + encoded;
    }
}

using System.Globalization;
using System.Text;

namespace SiteBlock.Core;

/// <summary>
/// Reproduces the few Swift string operations the original SiteBlockCore relies on, so the C# port gives the same answer on every input.
/// Swift strings are sequences of Unicode scalars (code points) grouped into Characters (what a person sees as one letter); C# strings are UTF-16 code units.
/// </summary>
internal static class SwiftText
{
    /// <summary>
    /// Splits text into Unicode scalars the way Swift's <c>unicodeScalars</c> view does: a surrogate pair becomes one code point.
    /// A lone surrogate, which a Swift string can never hold, is kept as its own code unit value so callers can reject it.
    /// </summary>
    public static int[] Scalars(string text)
    {
        var result = new int[text.Length];
        int count = 0;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                result[count++] = char.ConvertToUtf32(c, text[i + 1]);
                i++;
            }
            else
            {
                result[count++] = c;
            }
        }
        Array.Resize(ref result, count);
        return result;
    }

    /// <summary>Builds a string back from Unicode scalars exactly as given, with no normalization.</summary>
    public static string FromScalars(ReadOnlySpan<int> scalars)
    {
        var builder = new StringBuilder(scalars.Length);
        foreach (int scalar in scalars) AppendScalar(builder, scalar);
        return builder.ToString();
    }

    /// <summary>Appends one scalar to a builder, as two UTF-16 units when it lies above the Basic Multilingual Plane.</summary>
    private static void AppendScalar(StringBuilder builder, int scalar)
    {
        if (scalar >= 0x10000)
        {
            int offset = scalar - 0x10000;
            builder.Append((char)(0xD800 + (offset >> 10)));
            builder.Append((char)(0xDC00 + (offset & 0x3FF)));
        }
        else
        {
            builder.Append((char)scalar);
        }
    }

    /// <summary>True for a value in the UTF-16 surrogate range, which is never a real Unicode scalar.</summary>
    public static bool IsSurrogate(int scalar) => scalar is >= 0xD800 and <= 0xDFFF;

    /// <summary>
    /// Lowercases scalars the way Swift's <c>String.lowercased()</c> does: each scalar is replaced by its full lowercase mapping, with no context rules.
    /// The only full mapping that differs from the one-to-one mapping .NET uses is U+0130 (capital I with dot above), which becomes "i" plus U+0307.
    /// </summary>
    public static int[] Lowercased(ReadOnlySpan<int> scalars)
    {
        var result = new List<int>(scalars.Length);
        foreach (int scalar in scalars)
        {
            if (scalar < 0x80)
            {
                result.Add(scalar is >= 'A' and <= 'Z' ? scalar + 0x20 : scalar);
            }
            else if (scalar == 0x130)
            {
                result.Add('i');
                result.Add(0x307);
            }
            else if (IsSurrogate(scalar))
            {
                // A lone surrogate has no case; it is kept so a later check can refuse it.
                result.Add(scalar);
            }
            else
            {
                result.Add(Rune.ToLowerInvariant(new Rune(scalar)).Value);
            }
        }
        return result.ToArray();
    }

    /// <summary>Lowercases a whole string the way Swift's <c>lowercased()</c> does (see the scalar overload).</summary>
    public static string Lowercased(string text)
    {
        // Plain ASCII text is by far the common case and needs no scalar work.
        bool ascii = true;
        foreach (char c in text)
        {
            if (c >= 0x80) { ascii = false; break; }
        }
        if (ascii) return text.ToLowerInvariant();
        return FromScalars(Lowercased(Scalars(text)));
    }

    /// <summary>
    /// True for a scalar in Foundation's <c>CharacterSet.whitespacesAndNewlines</c>, read from Foundation itself: tab and the line breaks U+000A to U+000D, U+0020, U+0085, U+00A0, U+1680,
    /// U+2000 to U+200B (which includes the zero-width space U+200B, unlike Unicode's own space category), U+2028, U+2029, U+202F, U+205F and U+3000.
    /// </summary>
    public static bool IsFoundationWhitespace(int scalar) =>
        scalar is (>= 0x9 and <= 0xD) or 0x20 or 0x85 or 0xA0 or 0x1680 or (>= 0x2000 and <= 0x200B) or 0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000;

    /// <summary>The same set as <see cref="IsFoundationWhitespace"/>; kept under this name for callers that trim the way Foundation's <c>whitespacesAndNewlines</c> does.</summary>
    public static bool IsWhitespaceOrNewline(int scalar) => IsFoundationWhitespace(scalar);

    /// <summary>
    /// Trims leading and trailing scalars in Foundation's <c>whitespacesAndNewlines</c>, as Swift's <c>trimmingCharacters(in:)</c> does. It works scalar by scalar,
    /// so a space carrying a combining mark loses the space and keeps the mark. All of these characters are single UTF-16 units.
    /// </summary>
    public static string Trim(string text)
    {
        int start = 0;
        int end = text.Length;
        while (start < end && IsFoundationWhitespace(text[start])) start++;
        while (end > start && IsFoundationWhitespace(text[end - 1])) end--;
        return start == 0 && end == text.Length ? text : text[start..end];
    }

    // Foundation's CharacterSet.controlCharacters outside plane 14, read from Foundation itself: the Cc and Cf categories as Apple's Unicode tables define them.
    private static readonly (int Low, int High)[] FoundationControlRanges =
    [
        (0x0, 0x1F), (0x7F, 0x9F), (0xAD, 0xAD), (0x600, 0x605), (0x61C, 0x61C), (0x6DD, 0x6DD), (0x70F, 0x70F), (0x890, 0x891), (0x8E2, 0x8E2), (0x180E, 0x180E),
        (0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x2064), (0x2066, 0x206F), (0xFEFF, 0xFEFF), (0xFFF9, 0xFFFB), (0x110BD, 0x110BD), (0x110CD, 0x110CD),
        (0x13430, 0x1343F), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A),
    ];

    /// <summary>
    /// True for a scalar in Foundation's <c>CharacterSet.controlCharacters</c>, read from Foundation itself. Outside plane 14 it is the Cc and Cf categories.
    /// In plane 14 (U+E0000 to U+EFFFF) Foundation's table holds every code point whose low byte is 0x01 or 0x20 to 0x7F, which covers the tag characters and also some variation selectors; that is copied as it is.
    /// </summary>
    public static bool IsFoundationControl(int scalar)
    {
        if (scalar is >= 0xE0000 and <= 0xEFFFF)
        {
            int low = scalar & 0xFF;
            return low == 0x01 || low is >= 0x20 and <= 0x7F;
        }
        foreach (var (low, high) in FoundationControlRanges)
        {
            if (scalar < low) return false;
            if (scalar <= high) return true;
        }
        return false;
    }

    /// <summary>True for a scalar with Unicode's White_Space property, which is what Swift's <c>Character.isWhitespace</c> checks on a Character's first scalar (it does not include U+200B).</summary>
    public static bool IsUnicodeWhitespace(int scalar) => !IsSurrogate(scalar) && scalar <= 0x10FFFF && Rune.IsWhiteSpace(new Rune(scalar));

    /// <summary>
    /// Splits text at every Character (text element) that is exactly the given ASCII separator, as Swift's <c>components(separatedBy:)</c> does.
    /// A separator glued to a combining mark, a joiner or a prepended mark is part of a larger Character and does not split.
    /// </summary>
    public static List<string> SplitOnCharacter(string text, char separator)
    {
        var parts = new List<string>();
        int partStart = 0;
        int position = 0;
        while (position < text.Length)
        {
            int length = StringInfo.GetNextTextElementLength(text, position);
            if (length == 1 && text[position] == separator)
            {
                parts.Add(text[partStart..position]);
                partStart = position + 1;
            }
            position += length;
        }
        parts.Add(text[partStart..]);
        return parts;
    }

    /// <summary>
    /// True when the text starts with the given ASCII prefix counted in Swift Characters (user-perceived letters), which is what Swift's <c>hasPrefix</c> compares.
    /// A combining mark right after the prefix's last letter joins that letter into a different Character, so "www." followed by U+0301 does not start with "www.".
    /// </summary>
    public static bool HasCharacterPrefix(string text, string asciiPrefix)
    {
        if (!text.StartsWith(asciiPrefix, StringComparison.Ordinal)) return false;
        if (text.Length == asciiPrefix.Length) return true;
        // The prefix holds whole Characters only when its last letter is a text element of its own.
        int lastIndex = asciiPrefix.Length - 1;
        return StringInfo.GetNextTextElementLength(text, lastIndex) == 1 && ElementStartsAt(text, lastIndex);
    }

    /// <summary>True when the text's last Character is exactly the given ASCII character, which is what Swift's <c>hasSuffix</c> compares.</summary>
    public static bool HasCharacterSuffix(string text, char asciiSuffix)
    {
        if (text.Length == 0 || text[^1] != asciiSuffix) return false;
        return ElementStartsAt(text, text.Length - 1);
    }

    /// <summary>True when a text element (a Swift Character) begins at the given index, so the character there is not glued onto the one before it.</summary>
    private static bool ElementStartsAt(string text, int index)
    {
        int position = 0;
        while (position < text.Length)
        {
            if (position == index) return true;
            if (position > index) return false;
            position += StringInfo.GetNextTextElementLength(text, position);
        }
        return false;
    }

    /// <summary>The text split into its text elements (Swift Characters), in order.</summary>
    public static List<string> Characters(string text)
    {
        var result = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) result.Add(enumerator.GetTextElement());
        return result;
    }
}

using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace SiteBlock.Core;

/// <summary>The reasons a password cannot be stored or hashed; each case has a plain sentence a person can read (see <see cref="PasswordException"/>).</summary>
public enum PasswordError
{
    /// <summary>The new password has fewer characters than the minimum.</summary>
    TooShort,
    /// <summary>The new password is only spaces, tabs or line breaks.</summary>
    WhitespaceOnly,
    /// <summary>The system could not produce secure random bytes for the salt.</summary>
    RandomFailed,
    /// <summary>PBKDF2 could not run with the given values.</summary>
    DerivationFailed,
}

/// <summary>Thrown by <see cref="PasswordHasher"/> when a password cannot be stored or hashed; its message is the readable sentence for <see cref="Error"/>.</summary>
public sealed class PasswordException : Exception
{
    /// <summary>Creates the exception; <paramref name="minimum"/> is only used by <see cref="PasswordError.TooShort"/>, to name the minimum length.</summary>
    public PasswordException(PasswordError error, int minimum = PasswordHasher.MinimumLength) : base(Describe(error, minimum))
    {
        Error = error;
        Minimum = minimum;
    }

    /// <summary>Which problem the password has.</summary>
    public PasswordError Error { get; }

    /// <summary>The shortest password allowed, named in the TooShort sentence.</summary>
    public int Minimum { get; }

    /// <summary>The sentence shown to the user for this problem.</summary>
    private static string Describe(PasswordError error, int minimum) => error switch
    {
        PasswordError.TooShort => $"The password must be at least {minimum} characters long.",
        PasswordError.WhitespaceOnly => "The password can't be only spaces.",
        PasswordError.RandomFailed => "The system could not produce secure random bytes for the password.",
        PasswordError.DerivationFailed => "The password could not be hashed.",
        _ => throw new ArgumentOutOfRangeException(nameof(error)),
    };
}

/// <summary>Creates and checks the stored password fingerprint (PBKDF2 with SHA-256 and a random salt), so a hash made by the Mac version verifies here and the reverse.</summary>
public static class PasswordHasher
{
    /// <summary>The shortest password that <see cref="ValidateNew"/> accepts.</summary>
    public const int MinimumLength = 6;
    /// <summary>The only algorithm name this hasher writes or accepts.</summary>
    public const string AlgorithmName = "pbkdf2-sha256";
    private const int SaltLength = 16;
    private const int HashLength = 32;

    /// <summary>
    /// Runs PBKDF2-HMAC-SHA256 over the password's UTF-8 bytes and returns the requested number of output bytes, or null when it cannot run.
    /// Swift allows up to <c>uint.MaxValue</c> iterations; .NET's PBKDF2 takes an <c>int</c>, so a count above <c>int.MaxValue</c> also gives null (no real hash uses one).
    /// </summary>
    private static byte[]? Derive(string password, byte[] salt, long iterations, int length)
    {
        if (iterations <= 0 || iterations > uint.MaxValue || salt.Length == 0 || length <= 0) return null;
        if (iterations > int.MaxValue) return null;
        try
        {
            return Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, (int)iterations, HashAlgorithmName.SHA256, length);
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    /// <summary>Builds a new PasswordHash with a fresh random 16-byte salt and a 32-byte derived key. Throws <see cref="PasswordException"/> when random bytes or the derivation fail.</summary>
    public static PasswordHash Make(string password, int iterations = 210_000)
    {
        ArgumentNullException.ThrowIfNull(password);
        byte[] salt;
        try
        {
            salt = RandomNumberGenerator.GetBytes(SaltLength);
        }
        catch (CryptographicException)
        {
            throw new PasswordException(PasswordError.RandomFailed);
        }
        byte[] derived = Derive(password, salt, iterations, HashLength) ?? throw new PasswordException(PasswordError.DerivationFailed);
        return new PasswordHash(AlgorithmName, iterations, Convert.ToBase64String(salt), Convert.ToBase64String(derived));
    }

    /// <summary>Checks a password against a stored hash; returns false for a wrong password, an unknown algorithm, bad Base64 or unusable stored values. It never throws.</summary>
    public static bool Verify(string password, PasswordHash stored)
    {
        if (password is null || stored is null) return false;
        if (stored.Algorithm != AlgorithmName) return false;
        if (DecodeBase64(stored.Salt) is not byte[] salt || DecodeBase64(stored.Hash) is not byte[] expected) return false;
        if (salt.Length == 0 || expected.Length == 0) return false;
        // Always derive the full 32 bytes. A stored hash of any other length then fails the length check, so a shortened hash in an edited state file cannot make wrong passwords easier to hit.
        if (Derive(password, salt, stored.Iterations, HashLength) is not byte[] derived) return false;
        // FixedTimeEquals takes the same time wherever the bytes differ, so timing does not reveal how many leading bytes matched; a length mismatch is false.
        return CryptographicOperations.FixedTimeEquals(derived, expected);
    }

    /// <summary>
    /// Reads strict Base64 the way Foundation's <c>Data(base64Encoded:)</c> does, or returns null. .NET's decoder skips spaces and line breaks inside the text,
    /// while Foundation refuses them, so text holding any whitespace is refused here first.
    /// </summary>
    private static byte[]? DecodeBase64(string? text)
    {
        if (text is null) return null;
        foreach (char c in text)
        {
            if (char.IsWhiteSpace(c)) return null;
        }
        var buffer = new byte[(text.Length / 4 + 1) * 3];
        return Convert.TryFromBase64String(text, buffer, out int written) ? buffer[..written] : null;
    }

    /// <summary>
    /// Throws when a new password is shorter than the minimum or is only whitespace. Length is counted in user-perceived characters (text elements), as Swift counts Characters, not bytes or UTF-16 units.
    /// The length rule runs first, so an empty password reports TooShort.
    /// </summary>
    public static void ValidateNew(string password)
    {
        ArgumentNullException.ThrowIfNull(password);
        if (new StringInfo(password).LengthInTextElements < MinimumLength) throw new PasswordException(PasswordError.TooShort);
        // Swift's Character.isWhitespace looks at the first scalar of each Character, so a space carrying a combining mark still counts as whitespace.
        bool allWhitespace = true;
        foreach (string character in SwiftText.Characters(password))
        {
            if (!SwiftText.IsUnicodeWhitespace(SwiftText.Scalars(character)[0]))
            {
                allWhitespace = false;
                break;
            }
        }
        if (allWhitespace) throw new PasswordException(PasswordError.WhitespaceOnly);
    }
}

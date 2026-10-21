using System.Security.Cryptography;
using System.Text;

namespace SiteBlock.Core;

/// <summary>Chooses the name of the named pipe (the Windows channel the tray app and the command line use to talk to the service) so the service and its clients always agree on it.</summary>
public static class PipeNames
{
    /// <summary>The pipe name of the installed service. On Windows it is the pipe <c>\\.\pipe\siteblock</c>.</summary>
    public const string Production = "siteblock";

    /// <summary>
    /// Turns a sandbox pipe path such as <c>/tmp/box/siteblock.pipe</c> into a pipe name.
    /// On Windows a pipe name cannot hold slashes, so the name is "siteblock-" plus the first 16 lowercase hex characters of the SHA-256 of the full path in upper case, which gives each sandbox folder its own pipe whatever letter case it is typed in.
    /// On other systems .NET treats an absolute pipe name as the path of a Unix socket, so the full path is returned unchanged.
    /// </summary>
    public static string FromSandboxPath(string path)
    {
        if (!OperatingSystem.IsWindows()) return path;
        // Windows treats C:\Box and c:\box as the same folder, so the path is upper-cased before hashing and both spellings reach the same pipe.
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(path).ToUpperInvariant()));
        // Eight bytes make 16 hex characters.
        return "siteblock-" + Convert.ToHexString(hash.AsSpan(0, 8)).ToLowerInvariant();
    }

    /// <summary>
    /// The pipe name a client connects to: the given override if there is one, otherwise the SITEBLOCK_PIPE environment variable when it is set and not empty, otherwise the installed service's name.
    /// A chosen value that is an absolute path (a sandbox run) goes through <see cref="FromSandboxPath"/>, so it matches the name the sandbox service made for itself.
    /// </summary>
    public static string ClientPipeName(string? overrideValue)
    {
        string? chosen = !string.IsNullOrEmpty(overrideValue) ? overrideValue : Environment.GetEnvironmentVariable("SITEBLOCK_PIPE");
        if (string.IsNullOrEmpty(chosen)) return Production;
        // Someone may give the full Windows pipe address; the client wants only the part after it.
        const string windowsPrefix = @"\\.\pipe\";
        if (chosen.StartsWith(windowsPrefix, StringComparison.OrdinalIgnoreCase)) return chosen[windowsPrefix.Length..];
        return Path.IsPathFullyQualified(chosen) ? FromSandboxPath(chosen) : chosen;
    }
}

namespace SiteBlock.Core;

/// <summary>
/// Who is on the other end of the pipe. It takes the place of the caller's Unix user ID in the Swift version: every rule that says "uid 0" or "root" there uses <see cref="IsAdmin"/> here.
/// </summary>
/// <param name="UserId">The caller's Windows security ID (SID) as text, such as <c>S-1-5-21-…-1001</c>; any stable text in sandbox runs and tests.</param>
/// <param name="IsAdmin">True for SYSTEM and for a member of Administrators running elevated ("Run as administrator").</param>
public sealed record Peer(string UserId, bool IsAdmin)
{
    /// <summary>The caller used when the identity cannot be read. It is not an administrator, so a failure to read the identity never grants admin-only commands.</summary>
    public static Peer Unknown { get; } = new("unknown", false);
}

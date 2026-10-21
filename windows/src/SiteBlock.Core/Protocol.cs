using System.Text.Json.Serialization;

namespace SiteBlock.Core;

/// <summary>Every command a client can send to the service. On the wire each is written as its camelCase name (see <see cref="WireNames"/>), for example <c>cancelUnblock</c>.</summary>
[JsonConverter(typeof(CommandJsonConverter))]
public enum Command
{
    Status,
    Setup,
    Add,
    Unblock,
    CancelUnblock,
    AddPath,
    UnblockPath,
    CancelUnblockPath,
    TemporaryUnblock,
    TemporaryUnblockPath,
    SetDelay,
    CancelDelayChange,
    ChangePassword,
    Uninstall,
    CancelUninstall,
    RecoveryStart,
    RecoveryCancel,
}

/// <summary>The stable machine-readable reasons a command can fail. On the wire each is written as its camelCase name, for example <c>badRequest</c> and <c>internal</c>.</summary>
[JsonConverter(typeof(ErrorCodeJsonConverter))]
public enum ErrorCode
{
    BadRequest,
    InvalidDomain,
    NotSetUp,
    AlreadySetUp,
    WrongPassword,
    LockedOut,
    WeakPassword,
    NotBlocked,
    AlreadyBlocked,
    NothingPending,
    InvalidDelay,
    NotRoot,
    NotAllowed,
    TooManySites,
    InvalidPath,
    InvalidDuration,
    AlreadyPending,
    Internal,
}

/// <summary>Converts <see cref="Command"/> and <see cref="ErrorCode"/> values to and from the exact names the Swift version uses on the wire (the C# name with its first letter lowercased). Reading is exact and case-sensitive.</summary>
public static class WireNames
{
    private static readonly Dictionary<Command, string> CommandToName = Enum.GetValues<Command>().ToDictionary(c => c, c => CamelCase(c.ToString()));
    private static readonly Dictionary<string, Command> NameToCommand = CommandToName.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.Ordinal);
    private static readonly Dictionary<ErrorCode, string> CodeToName = Enum.GetValues<ErrorCode>().ToDictionary(c => c, c => CamelCase(c.ToString()));
    private static readonly Dictionary<string, ErrorCode> NameToCode = CodeToName.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.Ordinal);

    /// <summary>Lowercases the first letter of a C# name, which gives the Swift raw value.</summary>
    private static string CamelCase(string name) => char.ToLowerInvariant(name[0]) + name[1..];

    /// <summary>The name of the command on the wire, for example "cancelUnblock".</summary>
    public static string WireName(this Command command) => CommandToName.TryGetValue(command, out var name) ? name : throw new ArgumentOutOfRangeException(nameof(command));

    /// <summary>The name of the error code on the wire, for example "badRequest".</summary>
    public static string WireName(this ErrorCode code) => CodeToName.TryGetValue(code, out var name) ? name : throw new ArgumentOutOfRangeException(nameof(code));

    /// <summary>Reads a command name exactly as it appears on the wire; false for anything else, including a different letter case.</summary>
    public static bool TryParseCommand(string? name, out Command command) => NameToCommand.TryGetValue(name ?? "", out command);

    /// <summary>Reads an error code name exactly as it appears on the wire; false for anything else.</summary>
    public static bool TryParseErrorCode(string? name, out ErrorCode code) => NameToCode.TryGetValue(name ?? "", out code);
}

/// <summary>One request from a client: a command plus the arguments that command needs. Arguments a command does not use stay null and are left out of the JSON.</summary>
/// <param name="Command">Which command to run.</param>
/// <param name="Domain">The site for add, unblock, cancelUnblock and temporaryUnblock. For addPath, unblockPath, cancelUnblockPath and temporaryUnblockPath it holds the whole rule text, for example youtube.com/shorts or a pasted link.</param>
/// <param name="Password">The current password, for commands that loosen anything.</param>
/// <param name="NewPassword">The new password, for changePassword.</param>
/// <param name="Seconds">The delay in seconds, for setDelay. For temporaryUnblock and temporaryUnblockPath it is how long the site stays open (the window).</param>
/// <param name="StartSeconds">How long to wait before the site opens, in seconds, for temporaryUnblock and temporaryUnblockPath. Left out, it means the current unblock delay.</param>
[JsonConverter(typeof(RequestJsonConverter))]
public sealed record Request(Command Command, string? Domain = null, string? Password = null, string? NewPassword = null, long? Seconds = null, long? StartSeconds = null);

/// <summary>A temporary unblock as shown to clients.</summary>
/// <param name="OpensInSeconds">Seconds until the site opens, rounded up; null once it is open.</param>
/// <param name="SecondsRemaining">While waiting, the full length of the window; while open, the seconds left in the window, rounded up.</param>
/// <param name="WindowSeconds">The length of the window the person chose, in seconds.</param>
/// <param name="IsOpen">True while the site is open.</param>
[JsonConverter(typeof(TemporaryUnblockStatusJsonConverter))]
public sealed record TemporaryUnblockStatus(long? OpensInSeconds, long SecondsRemaining, long WindowSeconds, bool IsOpen);

/// <summary>One blocked site as shown to clients.</summary>
/// <param name="Domain">The base name, for example reddit.com.</param>
/// <param name="Hosts">Every host name written to the hosts file for this site.</param>
/// <param name="UnblockSecondsRemaining">Seconds until the site unblocks, or null when no unblock is pending.</param>
/// <param name="TemporaryUnblock">The site's temporary unblock, or null when it has none (also when an older service sent no such key).</param>
[JsonConverter(typeof(BlockedSiteStatusJsonConverter))]
public sealed record BlockedSiteStatus(string Domain, IReadOnlyList<string> Hosts, long? UnblockSecondsRemaining, TemporaryUnblockStatus? TemporaryUnblock = null)
{
    /// <summary>True when both hold equal values, comparing the host lists entry by entry.</summary>
    public bool Equals(BlockedSiteStatus? other) =>
        other is not null && Domain == other.Domain && Hosts.SequenceEqual(other.Hosts) && UnblockSecondsRemaining == other.UnblockSecondsRemaining && Equals(TemporaryUnblock, other.TemporaryUnblock);

    /// <summary>A hash that agrees with <see cref="Equals(BlockedSiteStatus?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Domain, Hosts.Count, UnblockSecondsRemaining, TemporaryUnblock);
}

/// <summary>One path rule as shown to clients.</summary>
/// <param name="Domain">The base name, for example youtube.com.</param>
/// <param name="Path">The path prefix, for example /shorts.</param>
/// <param name="Rule">The domain and path joined as people read them, for example youtube.com/shorts. Clients also send this text back to unblock or cancel the rule.</param>
/// <param name="UnblockSecondsRemaining">Seconds until the rule is removed, or null when no unblock is pending.</param>
/// <param name="TemporaryUnblock">The rule's temporary unblock, or null when it has none.</param>
[JsonConverter(typeof(BlockedPathStatusJsonConverter))]
public sealed record BlockedPathStatus(string Domain, string Path, string Rule, long? UnblockSecondsRemaining, TemporaryUnblockStatus? TemporaryUnblock = null);

/// <summary>A pending shorter delay as shown to clients.</summary>
/// <param name="NewDelaySeconds">The shorter delay that will apply.</param>
/// <param name="SecondsRemaining">Seconds before it applies.</param>
[JsonConverter(typeof(PendingDelayStatusJsonConverter))]
public sealed record PendingDelayStatus(long NewDelaySeconds, long SecondsRemaining);

/// <summary>A picture of the whole service state, sent with every successful response so clients can redraw after any command.</summary>
/// <param name="Version">The service's version string, for example "1.0.3".</param>
/// <param name="PasswordSet">True once a password has been set.</param>
/// <param name="Blocked">Every blocked site.</param>
/// <param name="DelaySeconds">The current unblock delay in seconds.</param>
/// <param name="PendingDelay">A requested shorter delay that has not applied yet.</param>
/// <param name="UninstallSecondsRemaining">Seconds until a requested uninstall happens.</param>
/// <param name="RecoverySecondsRemaining">Seconds until a running password recovery finishes.</param>
/// <param name="LockoutSecondsRemaining">Seconds until password checks are allowed again.</param>
/// <param name="HostsFileHealthy">True when the last enforcement pass found or left the hosts file in the right state.</param>
/// <param name="AdultFilterEnabled">Whether the adult content filter is on. A service that has the filter always sends true; a missing key reads as false.</param>
/// <param name="BlockedPaths">Every path rule. A missing key reads as an empty list.</param>
[JsonConverter(typeof(StatusSnapshotJsonConverter))]
public sealed record StatusSnapshot(string Version, bool PasswordSet, IReadOnlyList<BlockedSiteStatus> Blocked, long DelaySeconds, PendingDelayStatus? PendingDelay, long? UninstallSecondsRemaining, long? RecoverySecondsRemaining, long? LockoutSecondsRemaining, bool HostsFileHealthy, bool? AdultFilterEnabled = false, IReadOnlyList<BlockedPathStatus>? BlockedPaths = null)
{
    /// <summary>Every path rule; the constructor turns a missing list into an empty one, as the Swift default does.</summary>
    public IReadOnlyList<BlockedPathStatus>? BlockedPaths { get; init; } = BlockedPaths ?? [];

    /// <summary>
    /// The path rules the tab watcher looks for: every rule in the snapshot except those a temporary unblock currently has open, because an open rule is allowed for now and its tabs must be left alone.
    /// Rules waiting to open, or waiting to unblock for good, are still blocked, so they stay in. A snapshot with no path rules gives an empty list.
    /// </summary>
    public List<WatchedPathRule> WatchedPathRules =>
        (BlockedPaths ?? []).Where(rule => rule.TemporaryUnblock?.IsOpen != true).Select(rule => new WatchedPathRule(rule.Domain, rule.Path)).ToList();

    /// <summary>True when both snapshots hold equal values, comparing every list entry by entry.</summary>
    public bool Equals(StatusSnapshot? other)
    {
        if (other is null) return false;
        return Version == other.Version && PasswordSet == other.PasswordSet && Blocked.SequenceEqual(other.Blocked) && DelaySeconds == other.DelaySeconds
            && Equals(PendingDelay, other.PendingDelay) && UninstallSecondsRemaining == other.UninstallSecondsRemaining && RecoverySecondsRemaining == other.RecoverySecondsRemaining
            && LockoutSecondsRemaining == other.LockoutSecondsRemaining && HostsFileHealthy == other.HostsFileHealthy && AdultFilterEnabled == other.AdultFilterEnabled
            && (BlockedPaths is null || other.BlockedPaths is null ? BlockedPaths is null && other.BlockedPaths is null : BlockedPaths.SequenceEqual(other.BlockedPaths));
    }

    /// <summary>A hash that agrees with <see cref="Equals(StatusSnapshot?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Version, PasswordSet, Blocked.Count, DelaySeconds, HostsFileHealthy, BlockedPaths?.Count);
}

/// <summary>The service's reply to one request.</summary>
/// <param name="Ok">True when the command succeeded.</param>
/// <param name="Error">A sentence a person can read; present when Ok is false.</param>
/// <param name="ErrorCode">A stable machine-readable code; present when Ok is false.</param>
/// <param name="Status">Present on every successful response.</param>
/// <param name="Message">A short confirmation sentence for a successful command.</param>
[JsonConverter(typeof(ResponseJsonConverter))]
public sealed record Response(bool Ok, string? Error = null, ErrorCode? ErrorCode = null, StatusSnapshot? Status = null, string? Message = null)
{
    /// <summary>Builds a successful response carrying the current status and an optional confirmation sentence.</summary>
    public static Response Success(StatusSnapshot status, string? message = null) => new(true, Status: status, Message: message);

    /// <summary>Builds a failed response with a stable code and a readable sentence.</summary>
    public static Response Failure(ErrorCode code, string message) => new(false, Error: message, ErrorCode: code);
}

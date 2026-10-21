using System.Text.Json.Serialization;

namespace SiteBlock.Core;

/// <summary>
/// A timer that stores the time left rather than a finish time. A finish time would be compared with the wall clock, which the user can change.
/// JSON: <c>{"remainingSeconds": number, "totalSeconds": number}</c>.
/// </summary>
[JsonConverter(typeof(CountdownJsonConverter))]
public sealed record Countdown
{
    /// <summary>Creates a countdown with both the remaining and the total time set to the given length; a negative or non-finite length becomes 0.</summary>
    public Countdown(double seconds)
    {
        double clean = double.IsFinite(seconds) ? Math.Max(0, seconds) : 0;
        RemainingSeconds = clean;
        TotalSeconds = clean;
    }

    /// <summary>Creates a countdown from stored values (used when decoding saved state). The values are taken as they are.</summary>
    public Countdown(double remainingSeconds, double totalSeconds)
    {
        RemainingSeconds = remainingSeconds;
        TotalSeconds = totalSeconds;
    }

    /// <summary>Seconds left; never below 0 once it has been advanced.</summary>
    public double RemainingSeconds { get; set; }

    /// <summary>The length the countdown started with, for progress display.</summary>
    public double TotalSeconds { get; set; }

    /// <summary>Subtracts real elapsed time and stops at 0. Negative or non-finite input is ignored, so a bad clock reading can neither add time nor finish a countdown early.</summary>
    public void Advance(double elapsed)
    {
        if (!double.IsFinite(elapsed) || !(elapsed > 0)) return;
        double left = RemainingSeconds - elapsed;
        // Anything under a nanosecond is rounding noise from adding up many small ticks (2.0 - 1.9 - 0.1 is not exactly 0), not real time, so it counts as finished.
        RemainingSeconds = left < 1e-9 ? 0 : left;
    }

    /// <summary>True once no time is left.</summary>
    public bool IsFinished => RemainingSeconds <= 0;

    /// <summary>The remaining time rounded up to whole seconds, so a running countdown never shows 0.</summary>
    public long DisplaySeconds
    {
        get
        {
            if (!double.IsFinite(RemainingSeconds) || !(RemainingSeconds > 0)) return 0;
            // The upper bound keeps the integer conversion safe for absurd stored values.
            return (long)Math.Ceiling(Math.Min(RemainingSeconds, 1e12));
        }
    }

    /// <summary>A separate copy that can be changed without changing this one.</summary>
    public Countdown DeepCopy() => new(RemainingSeconds, TotalSeconds);
}

/// <summary>The stored fingerprint of the SiteBlock password. JSON: <c>{"algorithm", "hash", "iterations", "salt"}</c>.</summary>
/// <param name="Algorithm">Always "pbkdf2-sha256".</param>
/// <param name="Iterations">How many times the hashing is repeated (210000 in production).</param>
/// <param name="Salt">The random salt, Base64-encoded.</param>
/// <param name="Hash">The derived key, Base64-encoded.</param>
[JsonConverter(typeof(PasswordHashJsonConverter))]
public sealed record PasswordHash(string Algorithm, long Iterations, string Salt, string Hash);

/// <summary>
/// An unblock for a limited time that the person asked for on a site or path rule. The site stays blocked while <see cref="StartsIn"/> runs down, stays open for exactly <see cref="Window"/>, and is then blocked again on its own; the site or rule itself never leaves the block list.
/// JSON: <c>{"startsIn": Countdown, "window": Countdown}</c>.
/// </summary>
[JsonConverter(typeof(TemporaryUnblockJsonConverter))]
public sealed record TemporaryUnblock
{
    /// <summary>Creates a temporary unblock from its two countdowns.</summary>
    public TemporaryUnblock(Countdown startsIn, Countdown window)
    {
        StartsIn = startsIn ?? throw new ArgumentNullException(nameof(startsIn));
        Window = window ?? throw new ArgumentNullException(nameof(window));
    }

    /// <summary>Time left before the site opens. It starts at the start wait the person chose.</summary>
    public Countdown StartsIn { get; set; }

    /// <summary>How long the site stays open. It starts counting down only after <see cref="StartsIn"/> has reached 0.</summary>
    public Countdown Window { get; set; }

    /// <summary>True while the site is open: the start wait is over and the window still has time left.</summary>
    public bool IsOpen => StartsIn.RemainingSeconds <= 0 && Window.RemainingSeconds > 0;

    /// <summary>True once both the start wait and the window have run out, which means the site is blocked again and this record can be removed.</summary>
    public bool IsFinished => StartsIn.RemainingSeconds <= 0 && Window.RemainingSeconds <= 0;

    /// <summary>The length of the window the person chose, in whole seconds rounded up. It does not change as time passes.</summary>
    public long WindowSeconds
    {
        get
        {
            if (!double.IsFinite(Window.TotalSeconds) || !(Window.TotalSeconds > 0)) return 0;
            // The upper bound keeps the integer conversion safe for absurd stored values.
            return (long)Math.Ceiling(Math.Min(Window.TotalSeconds, 1e12));
        }
    }

    /// <summary>
    /// Subtracts real elapsed time. The start wait uses it first; whatever the start wait did not need (because it reached 0 during this step) comes off the window, and once the start wait is over all of it comes off the window.
    /// Neither countdown goes below 0. Negative or non-finite input changes nothing.
    /// </summary>
    public void Advance(double elapsed)
    {
        if (!double.IsFinite(elapsed) || !(elapsed > 0)) return;
        // How much of this step the start wait can still take; a stored negative or odd value counts as nothing left.
        double usedByStart = Math.Min(elapsed, Math.Max(0, StartsIn.RemainingSeconds));
        StartsIn.Advance(elapsed);
        Window.Advance(elapsed - usedByStart);
    }

    /// <summary>A separate copy, with its own countdowns, that can be changed without changing this one.</summary>
    public TemporaryUnblock DeepCopy() => new(StartsIn.DeepCopy(), Window.DeepCopy());
}

/// <summary>
/// One blocked site: the name the user asked for, every host name written to the hosts file for it, and an optional unblock that is waiting out its delay or a temporary unblock the person scheduled. The two never exist on the same site at once.
/// JSON: <c>{"domain", "hosts", "pendingUnblock"?, "temporaryUnblock"?}</c>. A <c>temporaryUnblock</c> that is present but cannot be read is dropped (read as null) instead of failing the whole file.
/// </summary>
[JsonConverter(typeof(BlockedSiteJsonConverter))]
public sealed record BlockedSite
{
    /// <summary>Creates a blocked site record.</summary>
    public BlockedSite(string domain, List<string> hosts, Countdown? pendingUnblock = null, TemporaryUnblock? temporaryUnblock = null)
    {
        Domain = domain ?? throw new ArgumentNullException(nameof(domain));
        Hosts = hosts ?? throw new ArgumentNullException(nameof(hosts));
        PendingUnblock = pendingUnblock;
        TemporaryUnblock = temporaryUnblock;
    }

    /// <summary>The normalized base name, for example reddit.com.</summary>
    public string Domain { get; set; }

    /// <summary>The full expanded host list, sorted and without duplicates.</summary>
    public List<string> Hosts { get; set; }

    /// <summary>Set when an unblock was approved; when it reaches zero the site is removed.</summary>
    public Countdown? PendingUnblock { get; set; }

    /// <summary>Set when a temporary unblock was approved; the site opens after its start wait and is blocked again when its window ends. A missing key reads as null, so an older state file still loads.</summary>
    public TemporaryUnblock? TemporaryUnblock { get; set; }

    /// <summary>True while a temporary unblock has this site open, which means its hosts are left out of the hosts file and the browsers' lists.</summary>
    public bool IsTemporarilyOpen => TemporaryUnblock?.IsOpen == true;

    /// <summary>A separate deep copy that can be changed without changing this one.</summary>
    public BlockedSite DeepCopy() => new(Domain, [.. Hosts], PendingUnblock?.DeepCopy(), TemporaryUnblock?.DeepCopy());

    /// <summary>True when both sites hold equal values, comparing the host lists entry by entry.</summary>
    public bool Equals(BlockedSite? other) =>
        other is not null && Domain == other.Domain && Hosts.SequenceEqual(other.Hosts) && Equals(PendingUnblock, other.PendingUnblock) && Equals(TemporaryUnblock, other.TemporaryUnblock);

    /// <summary>A hash that agrees with <see cref="Equals(BlockedSite?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Domain, Hosts.Count, PendingUnblock, TemporaryUnblock);
}

/// <summary>
/// One path rule: the start of a path on a site that stays blocked while the rest of the site stays open, for example <c>/shorts</c> on youtube.com. Only the browsers' own block lists can enforce it; the hosts file can only block whole names.
/// JSON: <c>{"domain", "path", "pendingUnblock"?, "temporaryUnblock"?}</c>, with the same dropping rule for an unreadable <c>temporaryUnblock</c> as a site.
/// </summary>
[JsonConverter(typeof(BlockedPathJsonConverter))]
public sealed record BlockedPath
{
    /// <summary>Creates a path rule record.</summary>
    public BlockedPath(string domain, string path, Countdown? pendingUnblock = null, TemporaryUnblock? temporaryUnblock = null)
    {
        Domain = domain ?? throw new ArgumentNullException(nameof(domain));
        Path = path ?? throw new ArgumentNullException(nameof(path));
        PendingUnblock = pendingUnblock;
        TemporaryUnblock = temporaryUnblock;
    }

    /// <summary>The normalized base domain, for example youtube.com.</summary>
    public string Domain { get; set; }

    /// <summary>The path prefix, starting with "/", for example /shorts. Its case is kept, because paths are case-sensitive.</summary>
    public string Path { get; set; }

    /// <summary>Set when an unblock was approved; when it reaches zero the rule is removed.</summary>
    public Countdown? PendingUnblock { get; set; }

    /// <summary>Set when a temporary unblock was approved; the rule stops blocking after its start wait and blocks again when its window ends.</summary>
    public TemporaryUnblock? TemporaryUnblock { get; set; }

    /// <summary>True while a temporary unblock has this rule open, which means the browsers' lists leave it out.</summary>
    public bool IsTemporarilyOpen => TemporaryUnblock?.IsOpen == true;

    /// <summary>A separate deep copy that can be changed without changing this one.</summary>
    public BlockedPath DeepCopy() => new(Domain, Path, PendingUnblock?.DeepCopy(), TemporaryUnblock?.DeepCopy());
}

/// <summary>A requested shorter unblock delay that has not taken effect yet. JSON: <c>{"countdown": Countdown, "newDelaySeconds": int}</c>.</summary>
[JsonConverter(typeof(PendingDelayChangeJsonConverter))]
public sealed record PendingDelayChange
{
    /// <summary>Creates a pending delay change.</summary>
    public PendingDelayChange(long newDelaySeconds, Countdown countdown)
    {
        NewDelaySeconds = newDelaySeconds;
        Countdown = countdown ?? throw new ArgumentNullException(nameof(countdown));
    }

    /// <summary>The shorter delay that will apply when the countdown ends.</summary>
    public long NewDelaySeconds { get; set; }

    /// <summary>Time left before the new delay applies.</summary>
    public Countdown Countdown { get; set; }

    /// <summary>A separate deep copy that can be changed without changing this one.</summary>
    public PendingDelayChange DeepCopy() => new(NewDelaySeconds, Countdown.DeepCopy());
}

/// <summary>
/// Everything SiteBlock remembers between runs; stored as one JSON file, <c>state.json</c>, with the same field names the Mac version writes.
/// The fields of the first release are required (a file missing one, such as <c>{}</c>, does not load); <c>savedDNS</c> and <c>blockedPaths</c> are optional.
/// </summary>
[JsonConverter(typeof(PersistedStateJsonConverter))]
public sealed record PersistedState
{
    /// <summary>The schema version this code writes.</summary>
    public const long CurrentVersion = 1;

    /// <summary>Creates a state record from every field; the optional ones default to the values of a fresh install.</summary>
    public PersistedState(long delaySeconds, long version = CurrentVersion, PasswordHash? passwordHash = null, List<BlockedSite>? blocked = null, PendingDelayChange? pendingDelayChange = null, Countdown? pendingUninstall = null, Countdown? recovery = null, long failedAttempts = 0, Countdown? lockout = null, bool uninstalling = false, Dictionary<string, List<string>>? savedDNS = null, List<BlockedPath>? blockedPaths = null)
    {
        Version = version;
        PasswordHash = passwordHash;
        Blocked = blocked ?? [];
        DelaySeconds = delaySeconds;
        PendingDelayChange = pendingDelayChange;
        PendingUninstall = pendingUninstall;
        Recovery = recovery;
        FailedAttempts = failedAttempts;
        Lockout = lockout;
        Uninstalling = uninstalling;
        SavedDNS = savedDNS;
        BlockedPaths = blockedPaths;
    }

    /// <summary>Schema version of the stored file. It is read but not checked.</summary>
    public long Version { get; set; }

    /// <summary>The password fingerprint, or null before the first setup and after a finished recovery.</summary>
    public PasswordHash? PasswordHash { get; set; }

    /// <summary>Every blocked site, in the order added.</summary>
    public List<BlockedSite> Blocked { get; set; }

    /// <summary>The current unblock waiting period in seconds.</summary>
    public long DelaySeconds { get; set; }

    /// <summary>A shorter waiting period that has been requested but has not applied yet.</summary>
    public PendingDelayChange? PendingDelayChange { get; set; }

    /// <summary>A requested uninstall that has not taken effect yet.</summary>
    public Countdown? PendingUninstall { get; set; }

    /// <summary>A running forgotten-password reset.</summary>
    public Countdown? Recovery { get; set; }

    /// <summary>Wrong passwords since the last correct one or the last lockout.</summary>
    public long FailedAttempts { get; set; }

    /// <summary>Time left before password checks are allowed again.</summary>
    public Countdown? Lockout { get; set; }

    /// <summary>Set to true when an uninstall starts so the watchdog stops restarting the service.</summary>
    public bool Uninstalling { get; set; }

    /// <summary>
    /// For each network adapter (keyed by its GUID on Windows, by its SystemConfiguration service ID on the Mac), the DNS servers it had before SiteBlock replaced them with the family servers; an empty list means the adapter had none set by hand.
    /// Written the first time an adapter is overridden and used only by the uninstaller to put the originals back. Null until the first override.
    /// </summary>
    public Dictionary<string, List<string>>? SavedDNS { get; set; }

    /// <summary>Every path rule, in the order added. Null until the first rule is added, and null again once the last one is removed.</summary>
    public List<BlockedPath>? BlockedPaths { get; set; }

    /// <summary>The state of a brand-new install: no password, nothing blocked, nothing pending.</summary>
    public static PersistedState Fresh(long delaySeconds = 1800) => new(delaySeconds);

    /// <summary>
    /// True only when the state describes a real uninstall: the <c>uninstalling</c> flag is set, an uninstall countdown exists, and it has run out.
    /// The flag alone is not enough, because anyone who can edit the state file could set it to make the service uninstall itself without the password and the wait.
    /// </summary>
    public bool HasFinishedUninstall => Uninstalling && PendingUninstall?.IsFinished == true;

    /// <summary>A separate deep copy that can be changed without changing this one.</summary>
    public PersistedState DeepCopy() => new(
        DelaySeconds, Version, PasswordHash, Blocked.Select(site => site.DeepCopy()).ToList(), PendingDelayChange?.DeepCopy(), PendingUninstall?.DeepCopy(), Recovery?.DeepCopy(),
        FailedAttempts, Lockout?.DeepCopy(), Uninstalling, SavedDNS?.ToDictionary(pair => pair.Key, pair => new List<string>(pair.Value), StringComparer.Ordinal), BlockedPaths?.Select(rule => rule.DeepCopy()).ToList());

    /// <summary>True when both states hold equal values, comparing lists entry by entry and the saved DNS record key by key.</summary>
    public bool Equals(PersistedState? other)
    {
        if (other is null) return false;
        return Version == other.Version && Equals(PasswordHash, other.PasswordHash) && Blocked.SequenceEqual(other.Blocked) && DelaySeconds == other.DelaySeconds
            && Equals(PendingDelayChange, other.PendingDelayChange) && Equals(PendingUninstall, other.PendingUninstall) && Equals(Recovery, other.Recovery)
            && FailedAttempts == other.FailedAttempts && Equals(Lockout, other.Lockout) && Uninstalling == other.Uninstalling
            && SavedDNSEqual(SavedDNS, other.SavedDNS) && NullableSequenceEqual(BlockedPaths, other.BlockedPaths);
    }

    /// <summary>A hash that agrees with <see cref="Equals(PersistedState?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Version, PasswordHash, Blocked.Count, DelaySeconds, FailedAttempts, Uninstalling, BlockedPaths?.Count);

    /// <summary>True when both saved DNS records are null, or hold the same keys with the same server lists in the same order.</summary>
    private static bool SavedDNSEqual(Dictionary<string, List<string>>? a, Dictionary<string, List<string>>? b)
    {
        if (a is null || b is null) return a is null && b is null;
        if (a.Count != b.Count) return false;
        foreach (var (key, servers) in a)
        {
            if (!b.TryGetValue(key, out var otherServers) || !servers.SequenceEqual(otherServers)) return false;
        }
        return true;
    }

    /// <summary>True when both lists are null, or both hold equal entries in the same order.</summary>
    private static bool NullableSequenceEqual<T>(List<T>? a, List<T>? b) => a is null || b is null ? a is null && b is null : a.SequenceEqual(b);
}

namespace SiteBlock.Core;

/// <summary>
/// The fixed numbers that govern waiting periods, lockouts and password hashing. It is a record so sandbox runs and tests can use shorter values (for example with a <c>with</c> expression).
/// </summary>
/// <param name="DefaultDelaySeconds">The unblock delay a fresh install starts with.</param>
/// <param name="MinDelaySeconds">The shortest delay that setDelay accepts.</param>
/// <param name="MaxDelaySeconds">The longest delay that setDelay accepts.</param>
/// <param name="RecoverySeconds">How long a forgotten-password reset waits.</param>
/// <param name="LockoutSeconds">How long password checks stay locked after too many wrong passwords.</param>
/// <param name="MaxFailedAttempts">How many wrong passwords trigger a lockout.</param>
/// <param name="Pbkdf2Iterations">How many PBKDF2 rounds new password hashes use.</param>
/// <param name="MaxSites">The most sites and path rules that can be blocked at once, counted together.</param>
/// <param name="MinUninstallSeconds">The shortest an uninstall ever waits. The real wait is this or the unblock delay, whichever is longer.</param>
/// <param name="MinTemporarySeconds">The shortest time a temporary unblock may stay open.</param>
/// <param name="MaxTemporarySeconds">The longest time a temporary unblock may stay open.</param>
/// <param name="MaxTemporaryStartSeconds">The longest wait before a temporary unblock opens.</param>
/// <param name="SaveIntervalSeconds">How often the service saves the state while any countdown is running; the runtime reads it, the engine does not.</param>
public sealed record Policy(long DefaultDelaySeconds, long MinDelaySeconds, long MaxDelaySeconds, long RecoverySeconds, long LockoutSeconds, long MaxFailedAttempts, int Pbkdf2Iterations, long MaxSites = 500, long MinUninstallSeconds = 172_800, long MinTemporarySeconds = 300, long MaxTemporarySeconds = 14_400, long MaxTemporaryStartSeconds = 604_800, long SaveIntervalSeconds = 15)
{
    /// <summary>
    /// The values the installed service always uses: 30 minute delay, 60 second to 7 day range, 48 hour recovery, 15 minute lockout after 5 wrong passwords, at most 500 blocked sites and path rules together,
    /// an uninstall wait of at least 48 hours, a temporary unblock that stays open 5 minutes to 4 hours and opens within 7 days, and a state save every 15 seconds while a countdown runs.
    /// </summary>
    public static Policy Production { get; } = new(1800, 60, 604_800, 172_800, 900, 5, 210_000, 500, 172_800, 300, 14_400, 604_800, 15);

    /// <summary>
    /// Short waits and a low site cap (20) for sandbox runs and tests only. A temporary unblock may stay open for as little as 1 second, and the state is saved every 2 seconds while a countdown runs;
    /// the other temporary unblock limits are the production ones.
    /// </summary>
    public static Policy FastForTests { get; } = new(2, 1, 604_800, 3, 2, 5, 1000, 20, 2, 1, 14_400, 604_800, 2);
}

/// <summary>
/// The whole policy of SiteBlock in one class: it holds the state, applies commands, advances countdowns, and reports what the hosts file and the browsers' lists should contain.
/// It does no file or pipe work and never reads a clock, so tests can drive it with fake time. It is not thread-safe: the service calls it from one engine thread only.
/// </summary>
public sealed class Engine
{
    /// <summary>A command that cannot continue; carries the failure response to send back.</summary>
    private sealed class Rejection(Response response) : Exception(response.Error)
    {
        /// <summary>The failure response for the client.</summary>
        public Response Response { get; } = response;
    }

    /// <summary>A blocked site or path rule found by name: which list it sits in, its position there, and the text people read for it (the domain, or a rule such as youtube.com/shorts).</summary>
    private readonly record struct Target(bool IsRule, int Index, string Name);

    private PersistedState _state;
    // The result of the last hosts file enforcement pass, reported in every status. It starts true because the runtime enforces once at startup and then sets it.
    private bool _lastHostsHealthy = true;

    /// <summary>Creates an engine around loaded (or fresh) state and a policy. The state is copied, so later changes to the caller's object do not reach the engine.</summary>
    public Engine(PersistedState state, Policy policy)
    {
        ArgumentNullException.ThrowIfNull(state);
        _state = state.DeepCopy();
        Policy = policy ?? throw new ArgumentNullException(nameof(policy));
    }

    /// <summary>A copy of the current persisted state; the runtime saves it after every command and after ticks that change it. Changing the copy does not change the engine.</summary>
    public PersistedState State => _state.DeepCopy();

    /// <summary>The fixed numbers this engine applies.</summary>
    public Policy Policy { get; }

    /// <summary>Called once when the uninstall countdown finishes.</summary>
    public Action? OnUninstall { get; set; }

    /// <summary>
    /// Called with one plain sentence whenever a temporary unblock is approved, opens, ends on its own, or is cancelled or ended early. The service writes each sentence to its log.
    /// The sentences never name the site or rule, because the log file stays on disk and would become a dated list of which sites were opened.
    /// </summary>
    public Action<string>? OnTemporaryUnblockEvent { get; set; }

    /// <summary>
    /// Returns the security ID (SID) of the person signed in at the PC's screen, or null when it is not known. The service sets it in production to read the console session's user.
    /// While it returns null (the default, used by sandbox runs and tests), any caller may run setup. When it returns an ID, only an administrator or that user may.
    /// </summary>
    public Func<string?> ConsoleUser { get; set; } = () => null;

    /// <summary>The sites that are blocked right now: every site except the ones a temporary unblock has open. Sites with a pending unblock and sites whose temporary unblock still waits are included.</summary>
    private IEnumerable<BlockedSite> EnforcedSites => _state.Blocked.Where(site => !site.IsTemporarilyOpen);

    /// <summary>
    /// Every host of every blocked site, sorted, without duplicates. Sites with a pending unblock are included, because they stay blocked until the countdown ends.
    /// A site whose temporary unblock is open is left out, but a host that another site (one that is not open) also needs stays in the list.
    /// </summary>
    public List<string> BlockedHosts => SortedDistinct(EnforcedSites.SelectMany(site => site.Hosts));

    /// <summary>The host names iCloud Private Relay needs. They are kept on Windows too because the engine is shared, and blocking them on Windows does no harm.</summary>
    public static readonly IReadOnlyList<string> PrivateRelayHosts = ["mask-h2.icloud.com", "mask.icloud.com"];

    /// <summary>True while the adult content filter is in force, which is always, except once an uninstall has begun (the uninstaller then takes the filter's settings away). There is no command, password or wait that turns it off.</summary>
    public bool AdultFilterActive => !_state.Uninstalling;

    /// <summary>
    /// The host names browsers use for their own DNS-over-HTTPS by default (Firefox's Cloudflare, NextDNS and CIRA servers, and Comcast's). A browser that looks names up this way skips both the hosts file and the family DNS servers,
    /// so the hosts file always blocks these names and the browser falls back to the system's own lookups.
    /// </summary>
    public static readonly IReadOnlyList<string> DohBypassHosts = ["doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"];

    /// <summary>
    /// Everything the hosts file must block: every blocked site's hosts, plus the Private Relay names and the DNS-over-HTTPS names whenever the adult content filter is active, sorted and without duplicates.
    /// Path rules never add hosts, because the hosts file can only block whole names.
    /// </summary>
    public List<string> HostsToWrite => AdultFilterActive ? SortedDistinct(BlockedHosts.Concat(PrivateRelayHosts).Concat(DohBypassHosts)) : SortedDistinct(BlockedHosts);

    /// <summary>The path rules, or an empty list when there are none.</summary>
    private List<BlockedPath> PathRules => _state.BlockedPaths ?? [];

    /// <summary>
    /// What the browsers' block lists must hold, with whole-site and path entries kept apart (so the enforcer can cut a too-long list with the whole-site entries kept first).
    /// The whole-site part is the shortest list that covers every host of every blocked site; a path rule is left out when a whole-site block already covers its domain.
    /// Sites and rules with a pending unblock are included. A site or rule whose temporary unblock is open is left out. A path rule whose whole site is open is kept, because the rule is what still blocks that part.
    /// </summary>
    public BrowserBlockLists BrowserBlockLists
    {
        get
        {
            List<string> sites = ChromePolicy.UrlBlocklist(EnforcedSites);
            // The covering check runs against the sites that are still blocked, so a rule is dropped as redundant only when a site that is not open covers it.
            var covering = new HashSet<string>(sites, StringComparer.Ordinal);
            var rules = PathRules.Where(rule => !rule.IsTemporarilyOpen && !Covers(covering, rule.Domain)).ToList();
            return new BrowserBlockLists(
                sites,
                SortedDistinct(rules.Select(rule => PathRuleParser.ChromeEntry(rule.Domain, rule.Path))),
                sites.Select(site => $"*://*.{site}/*").ToList(),
                SortedDistinct(rules.Select(rule => PathRuleParser.FirefoxPattern(rule.Domain, rule.Path))));
        }
    }

    /// <summary>Both browsers' block lists. Its <c>Chrome</c> list is for Chrome, Edge and Brave and its <c>Firefox</c> list for Firefox, each sorted; this is the same value as <see cref="BrowserBlockLists"/>.</summary>
    public BrowserBlockLists BrowserBlockEntries => BrowserBlockLists;

    /// <summary>True when the set holds the host itself or one of its parent domains (whole labels only), so a whole-site entry already blocks it. "youtube.com" covers "m.youtube.com" but not "notyoutube.com".</summary>
    private static bool Covers(HashSet<string> list, string host)
    {
        if (list.Contains(host)) return true;
        int dot = host.IndexOf('.');
        while (dot >= 0)
        {
            if (list.Contains(host[(dot + 1)..])) return true;
            dot = host.IndexOf('.', dot + 1);
        }
        return false;
    }

    /// <summary>
    /// Records the original DNS servers the DNS enforcer found (keyed by network adapter GUID), or clears the record with null or an empty dictionary.
    /// The enforcer calls this before it overrides an adapter, so the originals are known to the engine (and saved with the state) before they are lost.
    /// </summary>
    public void SetSavedDNS(IReadOnlyDictionary<string, List<string>>? saved)
    {
        _state.SavedDNS = saved is null || saved.Count == 0 ? null : saved.ToDictionary(pair => pair.Key, pair => new List<string>(pair.Value), StringComparer.Ordinal);
    }

    /// <summary>Records whether the last hosts file enforcement pass left the file correct, so later status responses can report it.</summary>
    public void SetHostsHealthy(bool healthy) => _lastHostsHealthy = healthy;

    /// <summary>Builds the status picture sent to clients.</summary>
    public StatusSnapshot Snapshot(bool hostsFileHealthy) => new(
        BuildInfo.Version,
        _state.PasswordHash is not null,
        _state.Blocked.Select(site => new BlockedSiteStatus(site.Domain, [.. site.Hosts], site.PendingUnblock?.DisplaySeconds, site.TemporaryUnblock is { } unblock ? TemporaryStatus(unblock) : null)).ToList(),
        _state.DelaySeconds,
        _state.PendingDelayChange is { } change ? new PendingDelayStatus(change.NewDelaySeconds, change.Countdown.DisplaySeconds) : null,
        _state.PendingUninstall?.DisplaySeconds,
        _state.Recovery?.DisplaySeconds,
        _state.Lockout?.DisplaySeconds,
        hostsFileHealthy,
        // The filter cannot be switched off, so a service that has it always says so. (A service from before the filter existed sends no such key, which clients read as false.)
        true,
        PathRules.Select(rule => new BlockedPathStatus(rule.Domain, rule.Path, PathRuleParser.Display(rule.Domain, rule.Path), rule.PendingUnblock?.DisplaySeconds, rule.TemporaryUnblock is { } unblock ? TemporaryStatus(unblock) : null)).ToList());

    /// <summary>
    /// Describes a temporary unblock for clients. While it waits, OpensInSeconds counts down and SecondsRemaining is the whole window; once it is open, OpensInSeconds is null and SecondsRemaining counts down the window.
    /// Both are rounded up, so a running countdown never shows 0.
    /// </summary>
    private static TemporaryUnblockStatus TemporaryStatus(TemporaryUnblock unblock) =>
        new(unblock.StartsIn.IsFinished ? null : unblock.StartsIn.DisplaySeconds, unblock.Window.DisplaySeconds, unblock.WindowSeconds, unblock.IsOpen);

    // MARK: - Commands

    /// <summary>Runs one command for the given caller and always returns a response; it never throws. Every successful response carries the current status.</summary>
    public Response Handle(Request request, Peer peer)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(peer);
        try
        {
            return request.Command switch
            {
                Command.Status => Success(null),
                Command.Setup => Setup(request, peer),
                Command.Add => Add(request),
                Command.Unblock => Unblock(request),
                Command.CancelUnblock => CancelUnblock(request),
                Command.AddPath => AddPath(request),
                Command.UnblockPath => UnblockPath(request),
                Command.CancelUnblockPath => CancelUnblockPath(request),
                Command.TemporaryUnblock => ScheduleTemporaryUnblock(request, forRule: false),
                Command.TemporaryUnblockPath => ScheduleTemporaryUnblock(request, forRule: true),
                Command.SetDelay => SetDelay(request),
                Command.CancelDelayChange => CancelDelayChange(),
                Command.ChangePassword => ChangePassword(request),
                Command.Uninstall => Uninstall(request),
                Command.CancelUninstall => CancelUninstall(),
                Command.RecoveryStart => RecoveryStart(peer),
                Command.RecoveryCancel => RecoveryCancel(),
                _ => Response.Failure(ErrorCode.BadRequest, "The request has an unknown command."),
            };
        }
        catch (Rejection rejection)
        {
            return rejection.Response;
        }
        catch (Exception error)
        {
            return Response.Failure(ErrorCode.Internal, $"Something went wrong inside SiteBlock: {error.Message}");
        }
    }

    /// <summary>Wraps a confirmation message together with the current status.</summary>
    private Response Success(string? message) => Response.Success(Snapshot(_lastHostsHealthy), message);

    /// <summary>Builds the exception that makes Handle return a failure response.</summary>
    private static Rejection Reject(ErrorCode code, string message) => new(Response.Failure(code, message));

    /// <summary>Returns a required text argument, or rejects the request with badRequest when it is missing.</summary>
    private static string Require(string? value, string name) => value ?? throw Reject(ErrorCode.BadRequest, $"The request is missing '{name}'.");

    /// <summary>Returns a required number argument, or rejects the request with badRequest when it is missing.</summary>
    private static long Require(long? value, string name) => value ?? throw Reject(ErrorCode.BadRequest, $"The request is missing '{name}'.");

    /// <summary>Words for a length of time, through the shared Formatting rules. Formatting takes an int, so a value outside its range is clamped (only an absurd stored value can be that large).</summary>
    private static string Duration(long seconds) => Formatting.Duration((int)Math.Clamp(seconds, int.MinValue, int.MaxValue));

    /// <summary>Turns the typed site name into its canonical form, or rejects with invalidDomain and the normalizer's sentence.</summary>
    private static string Normalized(string raw)
    {
        try
        {
            return DomainNormalizer.Normalize(raw);
        }
        catch (DomainException error)
        {
            throw Reject(ErrorCode.InvalidDomain, error.Message);
        }
    }

    /// <summary>Describes a wait in the most useful unit: whole minutes (rounded up) for a minute or more, otherwise seconds (at least 1).</summary>
    private static string WaitText(long seconds)
    {
        if (seconds >= 60)
        {
            long minutes = (seconds + 59) / 60;
            return $"{minutes} {(minutes == 1 ? "minute" : "minutes")}";
        }
        long clean = Math.Max(1, seconds);
        return $"{clean} {(clean == 1 ? "second" : "seconds")}";
    }

    /// <summary>The password rule shared by every command that takes a password. Returns a failure response, or null when the password is right.</summary>
    private Response? CheckPassword(string password)
    {
        // 1. A running lockout refuses without looking at the password at all, so a script cannot keep guessing during it.
        if (_state.Lockout is { } lockout)
        {
            if (!lockout.IsFinished) return Response.Failure(ErrorCode.LockedOut, $"Too many wrong passwords. Password checks are locked for another {WaitText(lockout.DisplaySeconds)}.");
            // The lockout already ended but the next tick has not cleared it yet.
            _state.Lockout = null;
        }
        // 2. Without a password there is nothing to check against.
        if (_state.PasswordHash is not { } stored) return Response.Failure(ErrorCode.NotSetUp, "No password has been set yet. Set one first.");
        // 3. A wrong password counts toward the lockout.
        if (!PasswordHasher.Verify(password, stored))
        {
            _state.FailedAttempts += 1;
            if (_state.FailedAttempts >= Policy.MaxFailedAttempts)
            {
                _state.Lockout = new Countdown(Policy.LockoutSeconds);
                _state.FailedAttempts = 0;
                return Response.Failure(ErrorCode.WrongPassword, $"Wrong password. Too many wrong passwords, so password checks are locked for {WaitText(Policy.LockoutSeconds)}.");
            }
            long left = Policy.MaxFailedAttempts - _state.FailedAttempts;
            return Response.Failure(ErrorCode.WrongPassword, $"Wrong password. {left} {(left == 1 ? "try" : "tries")} left before password checks are locked for {WaitText(Policy.LockoutSeconds)}.");
        }
        // 4. A right password clears the wrong-password count.
        _state.FailedAttempts = 0;
        return null;
    }

    /// <summary>Sets the first password; fails when the caller is not allowed to, when one already exists, or when the new one is too weak.</summary>
    private Response Setup(Request request, Peer peer)
    {
        // Who may set the password is checked first, before the arguments and before "already set up", so another account on the PC learns nothing and cannot claim the password before the owner does (or right after a recovery clears it).
        // SIDs are compared without regard to letter case, because Windows treats "S-1-5-…" and "s-1-5-…" as the same ID.
        if (ConsoleUser() is string console && !peer.IsAdmin && !string.Equals(peer.UserId, console, StringComparison.OrdinalIgnoreCase))
        {
            throw Reject(ErrorCode.NotAllowed, "Only the administrator or the person signed in at this PC's screen can set the SiteBlock password.");
        }
        string password = Require(request.Password, "password");
        if (_state.PasswordHash is not null) throw Reject(ErrorCode.AlreadySetUp, "A password is already set.");
        _state.PasswordHash = MakeHash(password);
        return Success("Password set.");
    }

    /// <summary>Validates a new password and hashes it, rejecting with weakPassword or internal.</summary>
    private PasswordHash MakeHash(string password)
    {
        try
        {
            PasswordHasher.ValidateNew(password);
            return PasswordHasher.Make(password, Policy.Pbkdf2Iterations);
        }
        catch (PasswordException error)
        {
            throw error.Error is PasswordError.TooShort or PasswordError.WhitespaceOnly ? Reject(ErrorCode.WeakPassword, error.Message) : Reject(ErrorCode.Internal, error.Message);
        }
    }

    /// <summary>Blocks a site at once. If the site is already blocked with an unblock pending, or with a temporary unblock (waiting or open), it cancels that unblock instead.</summary>
    private Response Add(Request request)
    {
        string raw = Require(request.Domain, "domain");
        string domain = Normalized(raw);
        int index = _state.Blocked.FindIndex(site => site.Domain == domain);
        if (index >= 0)
        {
            // Re-adding a site that is waiting to unblock, or that has a temporary unblock, is a way to say "keep it blocked". Neither needs a password, because it only makes things stricter.
            if (ClearEveryUnblock(new Target(false, index, domain)) is string message) return Success(message);
            throw Reject(ErrorCode.AlreadyBlocked, $"{domain} is already blocked.");
        }
        // Every block must be undoable later, so blocking needs a password to exist. The check comes after the existing-site case so cancelling a pending unblock never needs one.
        if (_state.PasswordHash is null) throw Reject(ErrorCode.NotSetUp, "Set a password before blocking sites, so every block can be undone later.");
        // The cap applies only to a new site. Without it, any account on the PC could add thousands of sites with no password, and the owner would then need one password check and one wait per site to clear them.
        RequireRoomForOneMore();
        _state.Blocked.Add(new BlockedSite(domain, DomainExpander.Expand(domain)));
        return Success($"{domain} is now blocked.");
    }

    /// <summary>Rejects with tooManySites when sites and path rules together have already reached the cap. A path rule counts like a site, because each one costs the owner a password check and a wait to clear.</summary>
    private void RequireRoomForOneMore()
    {
        if (_state.Blocked.Count + PathRules.Count >= Policy.MaxSites)
        {
            throw Reject(ErrorCode.TooManySites, $"SiteBlock can block at most {Policy.MaxSites} sites and parts of sites together. Unblock one before adding another.");
        }
    }

    /// <summary>Starts the unblock countdown for a site after the password check. A second request keeps the running countdown rather than restarting it.</summary>
    private Response Unblock(Request request)
    {
        string raw = Require(request.Domain, "domain");
        string password = Require(request.Password, "password");
        string domain = Normalized(raw);
        int index = _state.Blocked.FindIndex(site => site.Domain == domain);
        if (index < 0) throw Reject(ErrorCode.NotBlocked, $"{domain} is not blocked.");
        // A permanent unblock cannot start while a temporary one exists. This check comes before the password check, so a request that is refused anyway never costs a password attempt.
        if (_state.Blocked[index].TemporaryUnblock is not null) throw Reject(ErrorCode.AlreadyPending, $"{domain} has a temporary unblock. Keep it blocked first if you want to unblock it for good.");
        if (CheckPassword(password) is { } denied) return denied;
        if (_state.Blocked[index].PendingUnblock is { } existing)
        {
            return Success($"{domain} is already waiting to unblock, in {Duration(existing.DisplaySeconds)}. You can cancel any time before then.");
        }
        _state.Blocked[index].PendingUnblock = new Countdown(_state.DelaySeconds);
        return Success($"{domain} will unblock in {Duration(_state.DelaySeconds)}. You can cancel any time before then.");
    }

    /// <summary>Stops a pending unblock, or ends a temporary unblock (waiting or open); needs no password because it makes the PC stricter.</summary>
    private Response CancelUnblock(Request request)
    {
        string raw = Require(request.Domain, "domain");
        string domain = Normalized(raw);
        int index = _state.Blocked.FindIndex(site => site.Domain == domain);
        if (index < 0) throw Reject(ErrorCode.NotBlocked, $"{domain} is not blocked.");
        return CancelAnyUnblock(new Target(false, index, domain));
    }

    /// <summary>
    /// The shared body of add and addPath for an entry that is already blocked: clears every unblock it holds and returns the reply, or null when it holds none.
    /// An entry holding both kinds at once (only a hand-edited file can hold that) has both cleared; the reply then speaks about the permanent unblock, and the temporary one still reports its own event.
    /// </summary>
    private string? ClearEveryUnblock(Target target)
    {
        bool hadPending = PendingUnblockOf(target) is not null;
        if (hadPending) ClearPendingUnblock(target);
        string? temporaryMessage = CancelTemporaryUnblock(target);
        return hadPending ? $"Unblock cancelled; {target.Name} stays blocked." : temporaryMessage;
    }

    /// <summary>The shared body of cancelUnblock and cancelUnblockPath. A pending unblock is cleared first. Otherwise a temporary unblock is ended, and when there is neither the request fails with nothingPending.</summary>
    private Response CancelAnyUnblock(Target target)
    {
        if (PendingUnblockOf(target) is not null)
        {
            ClearPendingUnblock(target);
            return Success($"Unblock cancelled; {target.Name} stays blocked.");
        }
        if (CancelTemporaryUnblock(target) is string message) return Success(message);
        throw Reject(ErrorCode.NothingPending, $"{target.Name} has no unblock waiting.");
    }

    /// <summary>
    /// Reads rule text such as youtube.com/shorts or a pasted link into a domain and a path. A problem with the site name rejects with invalidDomain; a problem with the path, or no path at all, rejects with invalidPath.
    /// Both carry the parser's own sentence.
    /// </summary>
    private static (string Domain, string Path) ParsedRule(string raw)
    {
        try
        {
            return PathRuleParser.Parse(raw);
        }
        catch (PathRuleException error)
        {
            throw Reject(ErrorCode.InvalidPath, error.Message);
        }
        catch (DomainException error)
        {
            throw Reject(ErrorCode.InvalidDomain, error.Message);
        }
    }

    /// <summary>The position of the path rule with this domain and path, or -1 when there is none.</summary>
    private int PathRuleIndex((string Domain, string Path) rule) => PathRules.FindIndex(r => r.Domain == rule.Domain && r.Path == rule.Path);

    /// <summary>
    /// Blocks part of a site at once. Fails with alreadyBlocked when the whole site is already blocked (the rule would add nothing) or the same rule exists;
    /// re-adding a rule that is waiting to unblock, or that has a temporary unblock, cancels it instead, like add.
    /// </summary>
    private Response AddPath(Request request)
    {
        string raw = Require(request.Domain, "domain");
        var rule = ParsedRule(raw);
        string text = PathRuleParser.Display(rule.Domain, rule.Path);
        if (_state.Blocked.Any(site => site.Domain == rule.Domain)) throw Reject(ErrorCode.AlreadyBlocked, $"{rule.Domain} is already fully blocked.");
        int index = PathRuleIndex(rule);
        if (index >= 0)
        {
            // Like add: re-adding a rule that is waiting to unblock, or that has a temporary unblock, keeps it blocked, with no password.
            if (ClearEveryUnblock(new Target(true, index, text)) is string message) return Success(message);
            throw Reject(ErrorCode.AlreadyBlocked, $"{text} is already blocked.");
        }
        // The same two checks as add: every block must be undoable later, and the cap counts sites and rules together.
        if (_state.PasswordHash is null) throw Reject(ErrorCode.NotSetUp, "Set a password before blocking sites, so every block can be undone later.");
        RequireRoomForOneMore();
        _state.BlockedPaths = [.. PathRules, new BlockedPath(rule.Domain, rule.Path)];
        return Success($"{text} is now blocked.");
    }

    /// <summary>Starts the unblock countdown for a path rule after the password check, with the same rules as unblock: a second request keeps the running countdown.</summary>
    private Response UnblockPath(Request request)
    {
        string raw = Require(request.Domain, "domain");
        string password = Require(request.Password, "password");
        var rule = ParsedRule(raw);
        string text = PathRuleParser.Display(rule.Domain, rule.Path);
        int index = PathRuleIndex(rule);
        if (index < 0) throw Reject(ErrorCode.NotBlocked, $"{text} is not blocked.");
        // Same as unblock: a temporary unblock must be cancelled first, and this is checked before the password.
        if (PathRules[index].TemporaryUnblock is not null) throw Reject(ErrorCode.AlreadyPending, $"{text} has a temporary unblock. Keep it blocked first if you want to unblock it for good.");
        if (CheckPassword(password) is { } denied) return denied;
        if (PathRules[index].PendingUnblock is { } existing)
        {
            return Success($"{text} is already waiting to unblock, in {Duration(existing.DisplaySeconds)}. You can cancel any time before then.");
        }
        PathRules[index].PendingUnblock = new Countdown(_state.DelaySeconds);
        return Success($"{text} will unblock in {Duration(_state.DelaySeconds)}. You can cancel any time before then.");
    }

    /// <summary>Stops a pending path-rule unblock, or ends a temporary unblock of the rule (waiting or open); needs no password because it makes the PC stricter.</summary>
    private Response CancelUnblockPath(Request request)
    {
        string raw = Require(request.Domain, "domain");
        var rule = ParsedRule(raw);
        string text = PathRuleParser.Display(rule.Domain, rule.Path);
        int index = PathRuleIndex(rule);
        if (index < 0) throw Reject(ErrorCode.NotBlocked, $"{text} is not blocked.");
        return CancelAnyUnblock(new Target(true, index, text));
    }

    // MARK: - Temporary unblocks

    /// <summary>The unblock countdown the target is waiting on, or null when it has none.</summary>
    private Countdown? PendingUnblockOf(Target target) => target.IsRule ? PathRules[target.Index].PendingUnblock : _state.Blocked[target.Index].PendingUnblock;

    /// <summary>Removes the target's pending unblock countdown, so the site or rule stays blocked.</summary>
    private void ClearPendingUnblock(Target target)
    {
        if (target.IsRule) PathRules[target.Index].PendingUnblock = null;
        else _state.Blocked[target.Index].PendingUnblock = null;
    }

    /// <summary>The target's temporary unblock, or null when it has none.</summary>
    private TemporaryUnblock? TemporaryUnblockOf(Target target) => target.IsRule ? PathRules[target.Index].TemporaryUnblock : _state.Blocked[target.Index].TemporaryUnblock;

    /// <summary>Stores (or, with null, removes) the target's temporary unblock.</summary>
    private void SetTemporaryUnblock(TemporaryUnblock? unblock, Target target)
    {
        if (target.IsRule) PathRules[target.Index].TemporaryUnblock = unblock;
        else _state.Blocked[target.Index].TemporaryUnblock = unblock;
    }

    /// <summary>
    /// Ends the target's temporary unblock, if it has one, and returns the sentence to tell the client: one for an unblock that was still waiting (the site never opened) and one for an unblock that was open (the site is blocked again now).
    /// Returns null when the target has no temporary unblock. Both cases are sent to <see cref="OnTemporaryUnblockEvent"/>.
    /// </summary>
    private string? CancelTemporaryUnblock(Target target)
    {
        if (TemporaryUnblockOf(target) is not { } unblock) return null;
        SetTemporaryUnblock(null, target);
        if (unblock.IsOpen)
        {
            OnTemporaryUnblockEvent?.Invoke("temporary unblock ended early");
            return $"{target.Name} is blocked again.";
        }
        OnTemporaryUnblockEvent?.Invoke("temporary unblock cancelled");
        return $"The temporary unblock is cancelled; {target.Name} stays blocked.";
    }

    /// <summary>
    /// Schedules a temporary unblock of a site (or of a path rule when <paramref name="forRule"/> is true). The checks run in a fixed order, and the password is checked last, so a malformed or refused request never costs a password attempt:
    /// missing arguments, the site or rule text, whether it is blocked, whether it already has an unblock, the window length, the start wait, and then the password.
    /// </summary>
    private Response ScheduleTemporaryUnblock(Request request, bool forRule)
    {
        // 1. Every required argument must be present. Only StartSeconds may be left out.
        string raw = Require(request.Domain, "domain");
        string password = Require(request.Password, "password");
        long windowSeconds = Require(request.Seconds, "seconds");
        // 2 and 3. The site name or rule text must be valid, and the site or rule must be on the block list.
        Target target = forRule ? RuleTarget(raw) : SiteTarget(raw);
        // 4. A site or rule can have only one unblock of either kind at a time.
        if (PendingUnblockOf(target) is not null) throw Reject(ErrorCode.AlreadyPending, $"{target.Name} is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.");
        if (TemporaryUnblockOf(target) is not null) throw Reject(ErrorCode.AlreadyPending, $"{target.Name} already has a temporary unblock.");
        // 5. How long it stays open.
        if (windowSeconds < Policy.MinTemporarySeconds) throw Reject(ErrorCode.InvalidDuration, $"It must stay open for at least {Duration(Policy.MinTemporarySeconds)}.");
        if (windowSeconds > Policy.MaxTemporarySeconds) throw Reject(ErrorCode.InvalidDuration, $"It can't stay open for more than {Duration(Policy.MaxTemporarySeconds)}.");
        // 6. When it opens: never sooner than the unblock delay (a temporary unblock must not be a way around the wait), and not later than the longest start wait. Left out, it opens after the delay.
        long startSeconds = request.StartSeconds ?? _state.DelaySeconds;
        if (startSeconds < _state.DelaySeconds) throw Reject(ErrorCode.InvalidDuration, $"It can't open sooner than your unblock delay of {Duration(_state.DelaySeconds)}.");
        if (startSeconds > Policy.MaxTemporaryStartSeconds) throw Reject(ErrorCode.InvalidDuration, $"It can't open later than {Duration(Policy.MaxTemporaryStartSeconds)} from now.");
        // 7. The password rule: lockout, no password set, wrong password.
        if (CheckPassword(password) is { } denied) return denied;
        // 8. Everything is valid, so the site starts waiting.
        SetTemporaryUnblock(new TemporaryUnblock(new Countdown(startSeconds), new Countdown(windowSeconds)), target);
        OnTemporaryUnblockEvent?.Invoke($"temporary unblock approved: opens in {Duration(startSeconds)} for {Duration(windowSeconds)}");
        return Success($"{target.Name} opens in {Duration(startSeconds)}, for {Duration(windowSeconds)}, then blocks again.");
    }

    /// <summary>Finds the site named in a request, rejecting with invalidDomain when the name is not valid and notBlocked when the site is not on the list.</summary>
    private Target SiteTarget(string raw)
    {
        string domain = Normalized(raw);
        int index = _state.Blocked.FindIndex(site => site.Domain == domain);
        if (index < 0) throw Reject(ErrorCode.NotBlocked, $"{domain} is not blocked.");
        return new Target(false, index, domain);
    }

    /// <summary>Finds the path rule named in a request, rejecting with invalidDomain or invalidPath when the text is not a valid rule and notBlocked when the rule is not on the list.</summary>
    private Target RuleTarget(string raw)
    {
        var rule = ParsedRule(raw);
        string text = PathRuleParser.Display(rule.Domain, rule.Path);
        int index = PathRuleIndex(rule);
        if (index < 0) throw Reject(ErrorCode.NotBlocked, $"{text} is not blocked.");
        return new Target(true, index, text);
    }

    /// <summary>Changes the unblock delay. A longer (or equal) delay applies at once; a shorter one has to wait out the current delay first.</summary>
    private Response SetDelay(Request request)
    {
        long seconds = Require(request.Seconds, "seconds");
        string password = Require(request.Password, "password");
        // The range check comes before the password check, so a malformed request never costs a password attempt.
        if (seconds < Policy.MinDelaySeconds || seconds > Policy.MaxDelaySeconds)
        {
            throw Reject(ErrorCode.InvalidDelay, $"The delay must be between {Duration(Policy.MinDelaySeconds)} and {Duration(Policy.MaxDelaySeconds)}.");
        }
        if (CheckPassword(password) is { } denied) return denied;
        if (seconds >= _state.DelaySeconds)
        {
            _state.DelaySeconds = seconds;
            _state.PendingDelayChange = null;
            return Success($"The unblock delay is now {Duration(seconds)}.");
        }
        _state.PendingDelayChange = new PendingDelayChange(seconds, new Countdown(_state.DelaySeconds));
        return Success($"The unblock delay will change to {Duration(seconds)} in {Duration(_state.DelaySeconds)}. You can cancel any time before then.");
    }

    /// <summary>Drops a pending shorter delay; needs no password because it keeps the longer delay.</summary>
    private Response CancelDelayChange()
    {
        if (_state.PendingDelayChange is null) throw Reject(ErrorCode.NothingPending, "No delay change is waiting.");
        _state.PendingDelayChange = null;
        return Success("Delay change cancelled.");
    }

    /// <summary>Replaces the password at once after checking the old one and validating the new one.</summary>
    private Response ChangePassword(Request request)
    {
        string password = Require(request.Password, "password");
        string newPassword = Require(request.NewPassword, "newPassword");
        if (CheckPassword(password) is { } denied) return denied;
        _state.PasswordHash = MakeHash(newPassword);
        return Success("Password changed.");
    }

    /// <summary>How long a new uninstall waits: the policy's minimum (48 hours when installed) or the current unblock delay, whichever is longer.</summary>
    public long UninstallWaitSeconds => Math.Max(Policy.MinUninstallSeconds, _state.DelaySeconds);

    /// <summary>Starts the uninstall countdown (see <see cref="UninstallWaitSeconds"/>) after the password check, unless one is already running. An uninstall already waiting keeps its own countdown.</summary>
    private Response Uninstall(Request request)
    {
        string password = Require(request.Password, "password");
        if (CheckPassword(password) is { } denied) return denied;
        if (_state.PendingUninstall is { } existing) return Success($"Uninstall is already waiting, in {Duration(existing.DisplaySeconds)}. You can cancel any time before then.");
        long wait = UninstallWaitSeconds;
        _state.PendingUninstall = new Countdown(wait);
        return Success($"SiteBlock will uninstall in {Duration(wait)}. Every site stays blocked until then, and you can cancel any time before then.");
    }

    /// <summary>Stops a pending uninstall; needs no password. Once the countdown has finished and the uninstall has started, it can no longer be cancelled.</summary>
    private Response CancelUninstall()
    {
        if (_state.PendingUninstall is null || _state.Uninstalling) throw Reject(ErrorCode.NothingPending, "No uninstall is waiting.");
        _state.PendingUninstall = null;
        return Success("Uninstall cancelled.");
    }

    /// <summary>Starts the forgotten-password reset countdown. Only an administrator (SYSTEM or an elevated caller) may start it, and only when there is a password to reset.</summary>
    private Response RecoveryStart(Peer peer)
    {
        if (!peer.IsAdmin) throw Reject(ErrorCode.NotRoot, "Password recovery can only be started by an administrator. Open Terminal or PowerShell with \"Run as administrator\" and run siteblock recover.");
        if (_state.PasswordHash is null) throw Reject(ErrorCode.NotSetUp, "No password has been set, so there is nothing to recover.");
        if (_state.Recovery is { } existing) return Success($"Password recovery is already running, with {Duration(existing.DisplaySeconds)} left.");
        _state.Recovery = new Countdown(Policy.RecoverySeconds);
        return Success($"Password recovery started. The password will be cleared in {Duration(Policy.RecoverySeconds)}. Blocked sites stay blocked.");
    }

    /// <summary>Stops a running password recovery; needs no password.</summary>
    private Response RecoveryCancel()
    {
        if (_state.Recovery is null) throw Reject(ErrorCode.NothingPending, "No password recovery is running.");
        _state.Recovery = null;
        return Success("Password recovery cancelled.");
    }

    // MARK: - Time

    /// <summary>Moves every temporary unblock forward by the elapsed seconds, on sites and on path rules. Returns true when at least one opened or ended. An ended one is removed and the site or rule stays on the block list.</summary>
    private bool AdvanceTemporaryUnblocks(double elapsed)
    {
        bool changed = false;
        foreach (BlockedSite site in _state.Blocked)
        {
            var (unblock, siteChanged) = Advanced(site.TemporaryUnblock, elapsed);
            if (siteChanged) changed = true;
            site.TemporaryUnblock = unblock;
        }
        foreach (BlockedPath rule in PathRules)
        {
            var (unblock, ruleChanged) = Advanced(rule.TemporaryUnblock, elapsed);
            if (ruleChanged) changed = true;
            rule.TemporaryUnblock = unblock;
        }
        return changed;
    }

    /// <summary>
    /// Moves one temporary unblock forward and reports what happened. If the start wait ran out and the window did not, the unblock has opened and is kept. If the window ran out too, the unblock has ended and null comes back.
    /// A gap long enough to cover both the opening and the end (for example a PC that slept) therefore just ends it, with no "opened" message. Each outcome is sent to <see cref="OnTemporaryUnblockEvent"/>.
    /// </summary>
    private (TemporaryUnblock? Unblock, bool Changed) Advanced(TemporaryUnblock? unblock, double elapsed)
    {
        if (unblock is null) return (null, false);
        bool wasOpen = unblock.IsOpen;
        unblock.Advance(elapsed);
        if (unblock.IsFinished)
        {
            OnTemporaryUnblockEvent?.Invoke("temporary unblock ended; the site is blocked again");
            return (null, true);
        }
        if (unblock.IsOpen && !wasOpen)
        {
            OnTemporaryUnblockEvent?.Invoke("temporary unblock opened");
            return (unblock, true);
        }
        return (unblock, false);
    }

    /// <summary>
    /// Advances every countdown by the elapsed seconds and applies the ones that finished. Returns true when something finished or a temporary unblock opened, meaning the state must be saved now.
    /// Negative, NaN or infinite input changes nothing.
    /// </summary>
    public bool Tick(double elapsed)
    {
        if (!double.IsFinite(elapsed) || !(elapsed > 0)) return false;
        foreach (BlockedSite site in _state.Blocked) site.PendingUnblock?.Advance(elapsed);
        foreach (BlockedPath rule in PathRules) rule.PendingUnblock?.Advance(elapsed);
        _state.PendingDelayChange?.Countdown.Advance(elapsed);
        _state.PendingUninstall?.Advance(elapsed);
        _state.Recovery?.Advance(elapsed);
        _state.Lockout?.Advance(elapsed);

        // Sites and path rules go first so the hosts file and the browsers' lists lose them on the next pass.
        // A temporary unblock that opens or ends changes what must be blocked, so it counts as a change to save.
        bool changed = AdvanceTemporaryUnblocks(elapsed);
        if (_state.Blocked.RemoveAll(site => site.PendingUnblock?.IsFinished == true) > 0) changed = true;
        // Path rules whose unblock finished go the same way; the list goes back to null when the last one leaves, so the saved file looks like one from before path rules existed.
        if (_state.BlockedPaths is { } rules)
        {
            var remaining = rules.Where(rule => rule.PendingUnblock?.IsFinished != true).ToList();
            if (remaining.Count != rules.Count)
            {
                _state.BlockedPaths = remaining.Count == 0 ? null : remaining;
                changed = true;
            }
        }

        if (_state.PendingDelayChange is { } change && change.Countdown.IsFinished)
        {
            _state.DelaySeconds = change.NewDelaySeconds;
            _state.PendingDelayChange = null;
            changed = true;
        }
        if (_state.Lockout is { } lockout && lockout.IsFinished)
        {
            _state.Lockout = null;
            changed = true;
        }
        if (_state.Recovery is { } recovery && recovery.IsFinished)
        {
            // A finished recovery clears the password (so setup works again) but leaves every block in place.
            _state.PasswordHash = null;
            _state.FailedAttempts = 0;
            _state.Lockout = null;
            _state.Recovery = null;
            changed = true;
        }
        // The uninstalling flag guards against calling OnUninstall again on every later tick, so it fires exactly once.
        if (_state.PendingUninstall is { } uninstall && uninstall.IsFinished && !_state.Uninstalling)
        {
            _state.Uninstalling = true;
            changed = true;
            OnUninstall?.Invoke();
        }
        return changed;
    }

    /// <summary>The distinct strings, sorted by ordinal comparison (the order Swift's sort gives for ASCII names).</summary>
    private static List<string> SortedDistinct(IEnumerable<string> values)
    {
        var list = new HashSet<string>(values, StringComparer.Ordinal).ToList();
        list.Sort(StringComparer.Ordinal);
        return list;
    }
}

using System.Globalization;
using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>The color a site row wears. A plain blocked row with nothing counting down is neutral gray; brick red while an unblock of either kind waits (the site is still blocked); pine green while a temporary unblock has the site open.</summary>
public enum SiteTone
{
    /// <summary>The neutral gray card: blocked, nothing counting down.</summary>
    Neutral,
    /// <summary>Brick red: an unblock is waiting, so the site is still blocked.</summary>
    Blocked,
    /// <summary>Pine green: a temporary unblock has the site open.</summary>
    Open,
}

/// <summary>The lock in front of a row's name, so the row's state never depends on color alone.</summary>
public enum LockIcon
{
    /// <summary>A closed lock: blocked, nothing counting down.</summary>
    Closed,
    /// <summary>A lock with a clock: an unblock is waiting.</summary>
    Clock,
    /// <summary>An open lock: a temporary unblock has the site open.</summary>
    Open,
}

/// <summary>The one button on a row's title line.</summary>
public enum RowButton
{
    /// <summary>No button (no password exists yet, or an unblock form is open).</summary>
    None,
    /// <summary>"Unblock…", which opens the "For a while" / "For good" choice.</summary>
    Unblock,
    /// <summary>"Keep blocked", which cancels a waiting unblock.</summary>
    KeepBlocked,
    /// <summary>"Block now", which ends an open temporary unblock.</summary>
    BlockNow,
}

/// <summary>How far the person has got in starting an unblock on one row.</summary>
public enum UnblockStep
{
    /// <summary>Nothing is open; the row shows "Unblock…".</summary>
    Closed,
    /// <summary>The small choice between "For a while" and "For good" is showing.</summary>
    Choosing,
    /// <summary>The password form for the permanent unblock is showing.</summary>
    ForGood,
    /// <summary>The temporary unblock form is showing.</summary>
    ForAWhile,
}

/// <summary>Whether a row is a whole site or a blocked part of a site.</summary>
public enum RowKind
{
    /// <summary>A whole site, such as reddit.com.</summary>
    Site,
    /// <summary>A blocked part of a site, such as youtube.com/shorts.</summary>
    Rule,
}

/// <summary>What a row needs to know about the site or rule it shows, taken from the latest status.</summary>
/// <param name="Kind">Site or rule.</param>
/// <param name="Title">The domain, or the rule text such as youtube.com/shorts. It is also what is sent back to the service.</param>
/// <param name="PendingSeconds">Seconds until a permanent unblock finishes, or null when none is pending.</param>
/// <param name="Temporary">The temporary unblock, or null when there is none.</param>
/// <param name="Hosts">For a site, every host name written to the hosts file; empty for a rule.</param>
/// <param name="RuleDomain">For a rule, its domain; null for a site.</param>
/// <param name="RulePath">For a rule, its path; null for a site.</param>
public sealed record RowItem(RowKind Kind, string Title, long? PendingSeconds, TemporaryUnblockStatus? Temporary, IReadOnlyList<string> Hosts, string? RuleDomain = null, string? RulePath = null)
{
    /// <summary>The row for one blocked site.</summary>
    public static RowItem FromSite(BlockedSiteStatus site) => new(RowKind.Site, site.Domain, site.UnblockSecondsRemaining, site.TemporaryUnblock, site.Hosts);

    /// <summary>The row for one blocked part of a site.</summary>
    public static RowItem FromRule(BlockedPathStatus rule) => new(RowKind.Rule, rule.Rule, rule.UnblockSecondsRemaining, rule.TemporaryUnblock, [], rule.Domain, rule.Path);

    /// <summary>A key that tells rows apart across status updates: the kind plus the title.</summary>
    public string Key => (Kind == RowKind.Site ? "site:" : "rule:") + Title;

    /// <summary>Where this row's messages show.</summary>
    public FeedbackScope Scope => Kind == RowKind.Site ? FeedbackScope.Site(Title) : FeedbackScope.Rule(Title);

    /// <summary>True when nothing waits or is open on this row, which is the only time a new unblock can be started.</summary>
    public bool CanStartUnblock => PendingSeconds is null && Temporary is null;

    /// <summary>True when the two items show the same thing, comparing the host lists entry by entry.</summary>
    public bool Equals(RowItem? other) =>
        other is not null && Kind == other.Kind && Title == other.Title && PendingSeconds == other.PendingSeconds && Equals(Temporary, other.Temporary) && Hosts.SequenceEqual(other.Hosts) && RuleDomain == other.RuleDomain && RulePath == other.RulePath;

    /// <summary>A hash that agrees with <see cref="Equals(RowItem?)"/>.</summary>
    public override int GetHashCode() => HashCode.Combine(Kind, Title, PendingSeconds, Temporary, Hosts.Count);
}

/// <summary>Everything a row shows at one moment: its color, its lock, its button, its countdown line and its disclosure.</summary>
/// <param name="Tone">The row's color.</param>
/// <param name="Icon">The lock in front of the name.</param>
/// <param name="Button">The button on the title line.</param>
/// <param name="ButtonLabel">The button's label ("Unblock…", "Keep blocked", "Block now"), or null for no button.</param>
/// <param name="LineLead">The bold start of the countdown line ("Still blocked" for a permanent unblock), or null.</param>
/// <param name="LineText">The countdown line, such as "· unblocks in 29:41" or "Opens in 42:10 for 1 hour — still blocked", or null when nothing counts down.</param>
/// <param name="ShowsUnblockFlow">True when the choice or one of the two forms shows under the title line.</param>
/// <param name="DetailLabel">The disclosure's label: "24 hosts" for a site, "What this blocks" for a rule.</param>
/// <param name="DetailHelp">The disclosure's tooltip.</param>
/// <param name="RuleSentence">For a rule, the sentence the open disclosure shows; null for a site.</param>
public sealed record RowPresentation(SiteTone Tone, LockIcon Icon, RowButton Button, string? ButtonLabel, string? LineLead, string? LineText, bool ShowsUnblockFlow, string DetailLabel, string DetailHelp, string? RuleSentence)
{
    /// <summary>The lead of a permanent unblock's line.</summary>
    public const string StillBlocked = "Still blocked";

    /// <summary>
    /// Works out what a row shows. <paramref name="pendingLeft"/> and <paramref name="temporaryLeft"/> are the live seconds left on the pending unblock and on the temporary unblock's current countdown (until it opens while waiting, until it closes while open).
    /// <paramref name="canUnblock"/> is false while no password exists, which hides "Unblock…".
    /// </summary>
    public static RowPresentation Build(RowItem item, UnblockStep step, bool canUnblock, int pendingLeft, int temporaryLeft)
    {
        ArgumentNullException.ThrowIfNull(item);
        TemporaryUnblockStatus? temporary = item.Temporary;
        bool isOpen = temporary?.IsOpen == true;
        bool counting = item.PendingSeconds is not null || temporary is not null;

        SiteTone tone = isOpen ? SiteTone.Open : counting ? SiteTone.Blocked : SiteTone.Neutral;
        LockIcon icon = isOpen ? LockIcon.Open : counting ? LockIcon.Clock : LockIcon.Closed;

        RowButton button;
        if (counting) button = isOpen ? RowButton.BlockNow : RowButton.KeepBlocked;
        else button = canUnblock && step == UnblockStep.Closed ? RowButton.Unblock : RowButton.None;

        string? lead = null;
        string? line = null;
        if (temporary is not null)
        {
            if (isOpen) line = temporaryLeft > 0 ? $"Unblocked — blocks again in {Formatting.Clock(temporaryLeft)}" : "Blocking again…";
            else line = temporaryLeft > 0 ? $"Opens in {Formatting.Clock(temporaryLeft)} for {TemporaryUnblockOptions.Label(CountdownMath.Clamp(temporary.WindowSeconds))} — still blocked" : "Opening now…";
        }
        else if (item.PendingSeconds is not null)
        {
            lead = StillBlocked;
            line = pendingLeft > 0 ? $"· unblocks in {Formatting.Clock(pendingLeft)}" : "· unblocking now…";
        }

        string detailLabel = item.Kind == RowKind.Site
            ? $"{item.Hosts.Count.ToString(CultureInfo.InvariantCulture)} {(item.Hosts.Count == 1 ? "host" : "hosts")}"
            : "What this blocks";
        string detailHelp = item.Kind == RowKind.Site ? "Every name SiteBlock writes to the hosts file for this site" : "Which addresses this rule blocks";
        string? ruleSentence = item.Kind == RowKind.Rule
            ? $"Blocks every address on {item.RuleDomain} and its subdomains whose path starts with {item.RulePath}. The rest of the site stays open."
            : null;

        return new RowPresentation(tone, icon, button, LabelFor(button), lead, line, item.CanStartUnblock && step != UnblockStep.Closed, detailLabel, detailHelp, ruleSentence);
    }

    /// <summary>The label of a row button, or null for none.</summary>
    public static string? LabelFor(RowButton button) => button switch
    {
        RowButton.Unblock => "Unblock…",
        RowButton.KeepBlocked => "Keep blocked",
        RowButton.BlockNow => "Block now",
        _ => null,
    };
}

/// <summary>
/// One row of the blocked list and the person's progress in it: which unblock step is open, whether the disclosure is open, the "For good" password and the "For a while" form.
/// The list keeps the same object for the same site or rule across status updates, so typed text survives a poll. Call its methods on the screen's thread.
/// </summary>
public sealed class BlockedRowModel : ObservableModel
{
    private readonly StatusModel _status;
    private RowItem _item;
    private UnblockStep _step = UnblockStep.Closed;
    private bool _showDetail;
    private string _forGoodPassword = "";
    private TemporaryUnblockFormModel? _temporaryForm;
    private bool _focusPassword;

    /// <summary>Creates the row for <paramref name="item"/>.</summary>
    public BlockedRowModel(StatusModel status, RowItem item)
    {
        _status = status ?? throw new ArgumentNullException(nameof(status));
        _item = item ?? throw new ArgumentNullException(nameof(item));
    }

    /// <summary>The site or rule as of the latest status.</summary>
    public RowItem Item { get => _item; internal set => SetField(ref _item, value); }

    /// <summary>Which unblock step is open.</summary>
    public UnblockStep Step { get => _step; private set => SetField(ref _step, value); }

    /// <summary>Whether the disclosure (host names or the rule sentence) is open.</summary>
    public bool ShowDetail { get => _showDetail; private set => SetField(ref _showDetail, value); }

    /// <summary>The password typed in the "For good" form.</summary>
    public string ForGoodPassword { get => _forGoodPassword; set => SetField(ref _forGoodPassword, value ?? ""); }

    /// <summary>The "For a while" form while it is open, otherwise null.</summary>
    public TemporaryUnblockFormModel? TemporaryForm { get => _temporaryForm; private set => SetField(ref _temporaryForm, value); }

    /// <summary>Set to true when the password field of the open form should take the cursor (after a refusal, or when the "For good" form opens); the view sets it back to false once it has moved the cursor.</summary>
    public bool FocusPasswordRequested { get => _focusPassword; set => SetField(ref _focusPassword, value); }

    /// <summary>What the row shows right now, counting the time since the latest status arrived.</summary>
    public RowPresentation Present()
    {
        TemporaryUnblockStatus? temporary = Item.Temporary;
        int pendingLeft = Item.PendingSeconds is { } pending ? _status.Remaining(pending) : 0;
        int temporaryLeft = temporary is null ? 0 : _status.Remaining(temporary.IsOpen ? temporary.SecondsRemaining : temporary.OpensInSeconds ?? 0);
        return RowPresentation.Build(Item, Step, _status.Snapshot?.PasswordSet == true, pendingLeft, temporaryLeft);
    }

    /// <summary>The sentence above the "For good" password field, naming the current delay.</summary>
    public string ForGoodExplanation(long delaySeconds) =>
        $"Enter your password to start the countdown. It stays blocked for {Formatting.Duration(CountdownMath.Clamp(delaySeconds))} first, and you can cancel any time before then.";

    /// <summary>True when the row is a plain closed row (title line and disclosure only), which is the height the list box is sized from.</summary>
    public bool IsPlainClosed => !ShowDetail && Step == UnblockStep.Closed && Item.CanStartUnblock && _status.Feedback?.Scope != Item.Scope;

    /// <summary>True when "Start countdown" may be pressed.</summary>
    public bool CanStartCountdown => ForGoodPassword.Length > 0 && !_status.IsBusy;

    /// <summary>"Unblock…": opens the choice between "For a while" and "For good".</summary>
    public void OpenChoice() => Step = UnblockStep.Choosing;

    /// <summary>"For a while": opens the temporary unblock form with nothing picked.</summary>
    public void ChooseForAWhile()
    {
        TemporaryForm = new TemporaryUnblockFormModel(CountdownMath.Clamp(_status.Snapshot?.DelaySeconds ?? 0));
        Step = UnblockStep.ForAWhile;
    }

    /// <summary>"For good": opens the password form and asks for the cursor in its field.</summary>
    public void ChooseForGood()
    {
        Step = UnblockStep.ForGood;
        FocusPasswordRequested = true;
    }

    /// <summary>Closes whichever unblock form is open and forgets what was typed in it.</summary>
    public void CloseForm()
    {
        ForGoodPassword = "";
        TemporaryForm = null;
        Step = UnblockStep.Closed;
    }

    /// <summary>Opens or closes the disclosure.</summary>
    public void ToggleDetail() => ShowDetail = !ShowDetail;

    /// <summary>
    /// "Start countdown": sends the typed password to start the permanent unblock. The field is emptied first, so the password never stays on screen. The form closes when the service accepts; after a refusal it stays open and asks for the cursor.
    /// Returns whether the service accepted it; does nothing (false) without a password or while busy.
    /// </summary>
    public async Task<bool> StartCountdownAsync()
    {
        if (!CanStartCountdown) return false;
        string typed = ForGoodPassword;
        ForGoodPassword = "";
        bool accepted = Item.Kind == RowKind.Site ? await _status.UnblockAsync(Item.Title, typed) : await _status.UnblockPathAsync(Item.Title, typed);
        if (accepted) CloseForm();
        else FocusPasswordRequested = true;
        return accepted;
    }

    /// <summary>
    /// "Schedule unblock": sends what the "For a while" form collected. The form's password is emptied at once; the form closes only when the service accepts, and after a refusal it keeps the picks and asks for the cursor in the password field.
    /// Returns whether the service accepted it.
    /// </summary>
    public async Task<bool> ScheduleTemporaryAsync()
    {
        if (TemporaryForm is not { } form || form.TakeChoice(_status.IsBusy) is not { } choice) return false;
        bool accepted = Item.Kind == RowKind.Site ? await _status.TemporaryUnblockAsync(Item.Title, choice) : await _status.TemporaryUnblockPathAsync(Item.Title, choice);
        if (accepted) CloseForm();
        else form.FocusPasswordRequested = true;
        return accepted;
    }

    /// <summary>"Keep blocked" or "Block now": cancels the waiting unblock or ends the open temporary unblock. Needs no password, because it only makes the PC stricter.</summary>
    public Task<bool> KeepBlockedAsync() => Item.Kind == RowKind.Site ? _status.CancelUnblockAsync(Item.Title) : _status.CancelUnblockPathAsync(Item.Title);
}

/// <summary>
/// The blocked list: one <see cref="BlockedRowModel"/> per site and per rule, kept across status updates so typed text survives, plus the headings and notes around them.
/// Both groups share one scroll box. With sites, the heading above the box is "Blocked sites" and the rules get their own heading and note inside the box; with only rules, the heading above the box is "Blocked parts of sites" and its note is the first thing inside.
/// </summary>
public sealed class BlockedListModel
{
    /// <summary>The message shown before anything is blocked.</summary>
    public const string EmptyText = "No sites blocked yet.";

    /// <summary>The heading of the site group.</summary>
    public const string SitesHeading = "Blocked sites";

    /// <summary>The heading of the rule group.</summary>
    public const string RulesHeading = "Blocked parts of sites";

    /// <summary>The one line under the rule group's heading, naming the browsers that can block a part of a site. Browsers outside this list only get the whole-site block.</summary>
    public const string LimitsNote = "Works in Chrome, Firefox, Edge and Brave. Other browsers can only block whole sites.";

    /// <summary>How many closed rows the box shows at once.</summary>
    public const int VisibleRows = 4;

    /// <summary>The gap between two rows, in pixels.</summary>
    public const double RowSpacing = 8;

    private readonly StatusModel _status;
    private readonly Dictionary<string, BlockedRowModel> _rows = new(StringComparer.Ordinal);

    /// <summary>Creates an empty list for the given status model.</summary>
    public BlockedListModel(StatusModel status) => _status = status ?? throw new ArgumentNullException(nameof(status));

    /// <summary>The site rows in the service's order.</summary>
    public IReadOnlyList<BlockedRowModel> SiteRows { get; private set; } = [];

    /// <summary>The rule rows in the service's order.</summary>
    public IReadOnlyList<BlockedRowModel> RuleRows { get; private set; } = [];

    /// <summary>True when nothing is blocked, which shows <see cref="EmptyText"/> instead of the box.</summary>
    public bool IsEmpty => SiteRows.Count == 0 && RuleRows.Count == 0;

    /// <summary>The heading above the box.</summary>
    public string TopHeading => SiteRows.Count == 0 ? RulesHeading : SitesHeading;

    /// <summary>The count next to the heading above the box.</summary>
    public int TopCount => SiteRows.Count == 0 ? RuleRows.Count : SiteRows.Count;

    /// <summary>True when the rule note is the first thing inside the box (there are no sites).</summary>
    public bool NoteAtTop => SiteRows.Count == 0 && RuleRows.Count > 0;

    /// <summary>True when the rules get their own heading and note inside the box, under the sites.</summary>
    public bool ShowsInnerRuleHeading => SiteRows.Count > 0 && RuleRows.Count > 0;

    /// <summary>The height of the box: <see cref="VisibleRows"/> closed rows of <paramref name="closedRowHeight"/> and the gaps between them. It never depends on how many rows exist, so the panel keeps its size.</summary>
    public static double BoxHeight(double closedRowHeight) => closedRowHeight * VisibleRows + RowSpacing * (VisibleRows - 1);

    /// <summary>Brings the rows up to date with a status: existing rows get the new data (keeping what was typed in them), new ones are created and rows that disappeared are dropped.</summary>
    public void Update(StatusSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int delay = CountdownMath.Clamp(snapshot.DelaySeconds);
        SiteRows = snapshot.Blocked.Select(site => Row(RowItem.FromSite(site), seen, delay)).ToList();
        RuleRows = (snapshot.BlockedPaths ?? []).Select(rule => Row(RowItem.FromRule(rule), seen, delay)).ToList();
        foreach (string key in _rows.Keys.Where(key => !seen.Contains(key)).ToList()) _rows.Remove(key);
    }

    /// <summary>Drops every row, which forgets every open form and typed password. The panel calls it when it closes.</summary>
    public void Reset()
    {
        _rows.Clear();
        SiteRows = [];
        RuleRows = [];
    }

    /// <summary>Returns the existing row for the item's key with its data replaced, or a new row.</summary>
    private BlockedRowModel Row(RowItem item, HashSet<string> seen, int delaySeconds)
    {
        seen.Add(item.Key);
        if (_rows.TryGetValue(item.Key, out BlockedRowModel? row))
        {
            row.Item = item;
            // A delay change while the "For a while" form is open moves its soonest choice.
            if (row.TemporaryForm is { } form) form.DelaySeconds = delaySeconds;
            return row;
        }
        row = new BlockedRowModel(_status, item);
        _rows[item.Key] = row;
        return row;
    }
}

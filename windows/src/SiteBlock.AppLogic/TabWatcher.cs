using System.Text.RegularExpressions;
using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>Turns the text of a browser's address bar into an address the rule matcher can read.</summary>
public static partial class BrowserAddress
{
    /// <summary>Schemes that browsers show without "//", such as about:blank and data:..., so text starting with one already has its scheme.</summary>
    [GeneratedRegex("^(about|blob|chrome|data|edge|brave|file|javascript|mailto|view-source):", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex SlashlessScheme();

    /// <summary>A scheme with "//" at the very start of the text, such as "https://"; only the start counts, so an address inside the query ("?next=https://…") is not taken for the text's own scheme.</summary>
    [GeneratedRegex("^[a-z][a-z0-9+.-]*://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex LeadingScheme();

    /// <summary>
    /// Browsers hide "https://" (and sometimes "www.") in the address bar, so text with no scheme gets "https://" in front. Text that already starts with a scheme ("http://…", "about:blank") is returned trimmed and otherwise unchanged; empty text gives an empty string.
    /// </summary>
    public static string ToUrl(string? text)
    {
        string trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0) return "";
        if (LeadingScheme().IsMatch(trimmed) || SlashlessScheme().IsMatch(trimmed)) return trimmed;
        return "https://" + trimmed;
    }
}

/// <summary>
/// Sends a Chrome, Edge or Brave window's visible tab to SiteBlock's blocked page once when it is on a blocked site or a blocked part of a site. That covers a tab that was already open when the site was blocked,
/// a new tab the browser opened over a connection it already had (the hosts file only stops new ones), a browser that has not read its new block list yet, and a page that moved onto a blocked part of a site
/// without loading (YouTube does this when you tap Shorts). While a supported browser runs and a rule exists, it reads each window's address bar through <see cref="IBrowserTabs"/> every half second when a path rule
/// exists and every four seconds otherwise (<see cref="WatchedPathRule.CheckInterval"/>), asks <see cref="TabReloadDecider"/> which windows to act on (the window id is the tab id), reads the address again, and acts only
/// when it still matches a rule. When the tab cannot be sent to the blocked page, its reload button is pressed instead, which shows the browser's own block page once the browser knows the rule.
/// A changed rule list is looked at at once. A beat that comes while the previous tick still runs is skipped, never queued.
/// </summary>
public sealed class TabWatcher : IDisposable
{
    private readonly IBrowserTabs _tabs;
    private readonly IClock _clock;
    private readonly IAppLog _log;
    private readonly Lock _gate = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly TabReloadDecider _decider = new();
    private IReadOnlyList<WatchedPathRule> _rules = [];
    // Moves to the blocked page that did not happen (the move and the reload after it both failed), by browser process and tab: the address the tab was on, how many have failed there, when the next try may start (clock
    // milliseconds; long.MaxValue after the last allowed try), and whether the tab was just handed back to the decider for that try. Only the tick touches it, one tick at a time.
    private readonly Dictionary<(int ProcessId, string TabId), (string Url, int Failures, long RetryAt, bool HandedBack)> _failedMoves = [];
    // A tab that keeps failing to move is tried at most this many times at one address, at least RetryDelayMs apart, so an address bar or button that cannot be used never turns into
    // tree searches every look, and a move that worked but reported an error never turns into a move every look.
    private const int MaxMoveAttempts = 3;
    private const long RetryDelayMs = 5_000;
    private int _tickRunning;
    private int _started;
    // Cancelled when the rules change: a wait under way ends at once, and a wait about to begin is skipped. The beat replaces it after it has looked.
    private CancellationTokenSource _wake = new();

    /// <summary>Creates the watcher. It does nothing until <see cref="Start"/> is called.</summary>
    public TabWatcher(IBrowserTabs tabs, IClock clock, IAppLog? log = null)
    {
        _tabs = tabs ?? throw new ArgumentNullException(nameof(tabs));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _log = log ?? NullAppLog.Instance;
    }

    /// <summary>The rules being watched for, as last given to <see cref="SetRules"/>.</summary>
    public IReadOnlyList<WatchedPathRule> Rules
    {
        get
        {
            lock (_gate) return _rules;
        }
    }

    /// <summary>The browsers that refused to be read. Windows asks no permission for UI Automation, so this is always empty; it exists so the panel logic matches the Mac's.</summary>
    public IReadOnlyList<string> DeniedBrowserNames { get; } = [];

    /// <summary>
    /// Replaces the rules to watch for. The status model calls it with every status it applies. A list equal to the current one changes nothing; a different one is used at once: the beat's wait is cut short,
    /// so a newly blocked site is looked for right away, and the interval is set again for the new list.
    /// </summary>
    public void SetRules(IEnumerable<WatchedPathRule> rules)
    {
        ArgumentNullException.ThrowIfNull(rules);
        List<WatchedPathRule> copy = [.. rules];
        lock (_gate)
        {
            if (copy.SequenceEqual(_rules)) return;
            _rules = copy;
            _wake.Cancel();
        }
    }

    /// <summary>
    /// Starts the beat: after each wait of <see cref="WatchedPathRule.CheckInterval"/> for the current rules, a tick starts on a pool thread, unless the previous one still runs. A change of rules ends the wait early.
    /// Calling it again does nothing.
    /// </summary>
    public void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) != 0) return;
        CancellationToken token = _stop.Token;
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                TimeSpan interval;
                CancellationToken wake;
                lock (_gate)
                {
                    interval = WatchedPathRule.CheckInterval(_rules);
                    wake = _wake.Token;
                }
                // Rules that changed before this wait began are looked at without waiting; a change during the wait cancels it.
                if (!wake.IsCancellationRequested)
                {
                    using var either = CancellationTokenSource.CreateLinkedTokenSource(token, wake);
                    try
                    {
                        await _clock.Delay(interval, either.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        if (token.IsCancellationRequested) return;
                    }
                }
                // The change is about to be looked at, so the next change needs a fresh token. A change after this point cancels the fresh one and gets its own look.
                lock (_gate)
                {
                    if (_wake.IsCancellationRequested)
                    {
                        _wake.Dispose();
                        _wake = new CancellationTokenSource();
                    }
                }
                // Fire and forget: a slow tick does not delay the beat, and the next beats are skipped until it ends.
                _ = TryRunTickAsync();
            }
        }, CancellationToken.None);
    }

    /// <summary>Stops the beat. A tick that is running finishes on its own.</summary>
    public void Dispose() => _stop.Cancel();

    /// <summary>Runs one tick on a pool thread unless one is already running. Completes with true when this call ran a tick and false when it was skipped.</summary>
    public async Task<bool> TryRunTickAsync()
    {
        if (Interlocked.CompareExchange(ref _tickRunning, 1, 0) != 0) return false;
        try
        {
            await Task.Run(RunTick).ConfigureAwait(false);
            return true;
        }
        finally
        {
            Volatile.Write(ref _tickRunning, 0);
        }
    }

    /// <summary>
    /// One look at the browsers. With no rules or no browser it forgets everything and touches nothing. Otherwise, for each browser process whose windows can be read, it acts on each window the decider names, after reading its address again and finding it still on a blocked site or part of a site.
    /// A process that cannot be read this tick keeps its memory. Memory of processes that are gone is dropped. It never throws.
    /// </summary>
    private void RunTick()
    {
        IReadOnlyList<WatchedPathRule> rules = Rules;
        // With no rules there is nothing to look for, so no browser is touched at all.
        if (rules.Count == 0)
        {
            _decider.ForgetAll();
            // Nothing is remembered about any tab now, so no failed move is either; a tab seen again later starts with all its tries.
            _failedMoves.Clear();
            return;
        }
        IReadOnlyList<BrowserProcess> browsers;
        try
        {
            browsers = _tabs.RunningBrowsers();
        }
        catch (Exception)
        {
            return;
        }
        if (browsers.Count == 0)
        {
            _decider.ForgetAll();
            // Nothing is remembered about any tab now, so no failed move is either; a tab seen again later starts with all its tries.
            _failedMoves.Clear();
            return;
        }

        var ruleList = rules as IReadOnlyCollection<WatchedPathRule> ?? [.. rules];
        foreach (BrowserProcess browser in browsers)
        {
            ReleaseDueRetries(browser.ProcessId);
            IReadOnlyList<BrowserWindowAddress> windows;
            try
            {
                windows = _tabs.ReadWindows(browser.ProcessId);
            }
            catch (Exception)
            {
                // A browser that quit or stopped answering is skipped this tick, and its memory is kept because it is not passed to the decider.
                continue;
            }
            List<string> toMove = _decider.TabsToReload(browser.ProcessId, windows.Select(window => (window.WindowId, window.Url)), ruleList);
            // A tab handed back for a retry is returned by the decider only while it is still on a blocked address. When it was not returned, it has left (or could not be
            // read this look), so its failure record goes and a later return starts with all its tries.
            foreach (var key in _failedMoves.Keys.Where(key => key.ProcessId == browser.ProcessId && _failedMoves[key].HandedBack && !toMove.Contains(key.TabId)).ToList()) _failedMoves.Remove(key);
            foreach (string windowId in toMove) ActIfStillBlocked(browser, windowId, ruleList);
        }

        // Memory about browsers that quit is dropped, so a new process that reuses an id starts clean.
        var running = browsers.Select(browser => browser.ProcessId).ToHashSet();
        _decider.ForgetProcesses(running);
        // A failed move is forgotten once its browser quit, or once the decider no longer remembers the tab (it left the blocked site or part), so a later return starts fresh.
        foreach (var key in _failedMoves.Keys.ToList())
        {
            // A tab handed back for a retry is not remembered by the decider on purpose, so only the others count as having left.
            if (!running.Contains(key.ProcessId) || (!_failedMoves[key].HandedBack && !_decider.Remembered(key.ProcessId).ContainsKey(key.TabId))) _failedMoves.Remove(key);
        }
    }

    /// <summary>Hands back to the decider every tab of one browser whose retry is due, so this tick's list returns it for another try.</summary>
    private void ReleaseDueRetries(int processId)
    {
        long now = _clock.MonotonicMilliseconds;
        foreach (var (key, failure) in _failedMoves.Where(entry => entry.Key.ProcessId == processId).ToList())
        {
            if (failure.HandedBack || failure.RetryAt > now || failure.Failures >= MaxMoveAttempts) continue;
            _decider.Forget(processId, key.TabId);
            _failedMoves[key] = failure with { HandedBack = true };
        }
    }

    /// <summary>
    /// Records a move to the blocked page that did not happen (the reload after it failed too). The tab stays remembered by the decider (so the next tick does not try at once); a retry is scheduled RetryDelayMs later,
    /// until MaxMoveAttempts have failed at that address, after which the tab is left alone until its address changes.
    /// </summary>
    private void NoteFailedMove(int processId, string tabId)
    {
        var key = (processId, tabId);
        string url = _decider.Remembered(processId).TryGetValue(tabId, out string? remembered) ? remembered : "";
        int failures = _failedMoves.TryGetValue(key, out var before) && before.Url == url ? before.Failures + 1 : 1;
        _failedMoves[key] = (url, failures, failures >= MaxMoveAttempts ? long.MaxValue : _clock.MonotonicMilliseconds + RetryDelayMs, HandedBack: false);
    }

    /// <summary>
    /// Reads one window's address again and, only when it still matches a rule, sends the tab to the blocked page for that rule; when that fails, it presses the reload button instead. The page may have moved on since
    /// the list was read, which is why the address is read again. Errors are ignored: the window may be gone.
    /// </summary>
    private void ActIfStillBlocked(BrowserProcess browser, string windowId, IReadOnlyCollection<WatchedPathRule> rules)
    {
        try
        {
            // An address that cannot be read again right now (the person clicked into the address bar, say) is not a decision to leave the tab alone, so it is tried again later.
            if (_tabs.CurrentUrl(browser.ProcessId, windowId) is not { } current)
            {
                NoteFailedMove(browser.ProcessId, windowId);
                return;
            }
            if (TabRuleMatcher.MatchingRule(current, rules) is not { } rule) return;
            // The line names the browser only: the log never holds an address, a domain or a path rule.
            string done;
            try
            {
                _tabs.Open(browser.ProcessId, windowId, BlockedPage.Address(rule.DisplayText));
                done = $"sent a {browser.DisplayName} tab to the blocked page";
            }
            catch (Exception)
            {
                // The tab could not be moved; a reload shows the browser's own block page when the browser already knows the rule. A reload that fails too reaches the outer catch.
                _tabs.Reload(browser.ProcessId, windowId);
                done = $"reloaded a {browser.DisplayName} tab on a blocked site or part of a site";
            }
            _failedMoves.Remove((browser.ProcessId, windowId));
            _log.Info(done);
        }
        catch (Exception)
        {
            // Neither the move nor the reload happened (the window closed, stopped answering, or its address bar and reload button could not be used). The decider already counted this tab as handled at
            // this address, so a later retry is scheduled instead of leaving the tab on the blocked part for as long as it stays there.
            NoteFailedMove(browser.ProcessId, windowId);
        }
    }
}

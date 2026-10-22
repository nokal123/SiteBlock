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
/// Reloads a Chrome, Edge or Brave window's visible tab once when it has moved onto a blocked part of a site without loading a page (YouTube does this when you tap Shorts), so the browser's own block list shows its block page.
/// Every 0.5 seconds, while at least one path rule exists and a supported browser runs, it reads each window's address bar through <see cref="IBrowserTabs"/>, asks <see cref="TabReloadDecider"/> which windows to reload (the window id is the tab id), reads the address again, and reloads only when it still matches a rule.
/// A beat that comes while the previous tick still runs is skipped, never queued.
/// </summary>
public sealed class TabWatcher : IDisposable
{
    /// <summary>How often the watcher looks at the browsers.</summary>
    public static readonly TimeSpan TickInterval = TimeSpan.FromSeconds(0.5);

    private readonly IBrowserTabs _tabs;
    private readonly IClock _clock;
    private readonly IAppLog _log;
    private readonly Lock _gate = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly TabReloadDecider _decider = new();
    private IReadOnlyList<WatchedPathRule> _rules = [];
    private int _tickRunning;
    private int _started;

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

    /// <summary>Replaces the rules to watch for. The status model calls it with every status it applies. The new list is used from the next tick.</summary>
    public void SetRules(IEnumerable<WatchedPathRule> rules)
    {
        ArgumentNullException.ThrowIfNull(rules);
        List<WatchedPathRule> copy = [.. rules];
        lock (_gate) _rules = copy;
    }

    /// <summary>Starts the beat: every 0.5 seconds a tick starts on a pool thread, unless the previous one still runs. Calling it again does nothing.</summary>
    public void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) != 0) return;
        CancellationToken token = _stop.Token;
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await _clock.Delay(TickInterval, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
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
    /// One look at the browsers. With no rules or no browser it forgets everything and touches nothing. Otherwise, for each browser process whose windows can be read, it reloads each window the decider names, after reading its address again and finding it still on a blocked part of a site.
    /// A process that cannot be read this tick keeps its memory. Memory of processes that are gone is dropped. It never throws.
    /// </summary>
    private void RunTick()
    {
        IReadOnlyList<WatchedPathRule> rules = Rules;
        // With no rules there is nothing to look for, so no browser is touched at all.
        if (rules.Count == 0)
        {
            _decider.ForgetAll();
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
            return;
        }

        var ruleList = rules as IReadOnlyCollection<WatchedPathRule> ?? [.. rules];
        foreach (BrowserProcess browser in browsers)
        {
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
            List<string> toReload = _decider.TabsToReload(browser.ProcessId, windows.Select(window => (window.WindowId, window.Url)), ruleList);
            foreach (string windowId in toReload) ReloadIfStillBlocked(browser, windowId, ruleList);
        }

        // Memory about browsers that quit is dropped, so a new process that reuses an id starts clean.
        _decider.ForgetProcesses(browsers.Select(browser => browser.ProcessId).ToHashSet());
    }

    /// <summary>Reads one window's address again and presses its reload button only when the address still matches a rule, because the page may have moved on since the list was read. Errors are ignored: the window may be gone.</summary>
    private void ReloadIfStillBlocked(BrowserProcess browser, string windowId, IReadOnlyCollection<WatchedPathRule> rules)
    {
        try
        {
            // An address that cannot be read again right now (the person clicked into the address bar, say) is not a decision to leave the tab alone, so it is tried again next tick.
            if (_tabs.CurrentUrl(browser.ProcessId, windowId) is not { } current)
            {
                _decider.Forget(browser.ProcessId, windowId);
                return;
            }
            if (TabRuleMatcher.MatchingRule(current, rules) is null) return;
            _tabs.Reload(browser.ProcessId, windowId);
            // The line names the browser only: the log never holds an address, a domain or a path rule.
            _log.Info($"reloaded a {browser.DisplayName} tab on a blocked part of a site");
        }
        catch (Exception)
        {
            // The reload did not happen (the window closed, stopped answering, or its reload button could not be pressed). The decider already counted this tab as handled at
            // this address, so it is forgotten, and the next tick tries again rather than leaving the tab on the blocked part for as long as it stays there.
            _decider.Forget(browser.ProcessId, windowId);
        }
    }
}

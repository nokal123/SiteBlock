using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// Keeps the registry policy of Chrome, Edge, Brave and Firefox equal to what <see cref="WindowsBrowserPolicy.Desired"/> wants, on every enforcement pass (06-windows.md § BrowserPolicyEnforcer).
/// For each browser it compares every value SiteBlock owns by name, type and content, and every owned list subkey value by value, and rewrites only what differs.
/// Values and subkeys SiteBlock does not own are never touched.
/// </summary>
public sealed class BrowserPolicyEnforcer : IBrowserPolicyEnforcer
{
    // A failure message that repeats is logged at most this often (milliseconds), so a problem that happens every tick does not fill the log.
    private const long RepeatedFailureLogIntervalMs = 60_000;

    // The shortest time between two policy refreshes (milliseconds). A change that comes sooner is refreshed when this has passed, so a run of changes never makes Windows apply policy over and over.
    internal const long MinRefreshIntervalMs = 5_000;

    private readonly IPolicyStore _store;
    private readonly IPolicyRefresher _refresher;
    private readonly Func<long> _now;
    private readonly Log _log;
    // True when a pass changed the registry and the browsers have not yet been asked to read it again.
    private bool _refreshWanted;
    // When the last refresh was asked for (milliseconds from the clock), or null before the first one.
    private long? _lastRefresh;
    // When each failure message was last logged (Environment.TickCount64), tracked per message because several browsers can fail in one pass.
    private readonly Dictionary<string, long> _lastFailures = new(StringComparer.Ordinal);
    // The browsers whose list was too long on the last pass and has already been reported, so the cut is logged once and not on every tick.
    private readonly HashSet<BrowserTarget> _reportedCuts = [];

    /// <summary>Creates an enforcer that reads and writes through the given store and tells the browsers about its changes through the refresher. The clock (milliseconds) defaults to <see cref="Environment.TickCount64"/>.</summary>
    public BrowserPolicyEnforcer(IPolicyStore store, IPolicyRefresher refresher, Log log, Func<long>? now = null)
    {
        _store = store;
        _refresher = refresher;
        _log = log;
        _now = now ?? (() => Environment.TickCount64);
    }

    /// <summary>
    /// Runs one pass for all four browsers and returns true when every browser ended correct. A pass that changes anything a command did not ask for logs "browser policy repaired (&lt;browser&gt;)".
    /// After a pass that changed anything, the browsers are asked to read their policy again, at most once every <see cref="MinRefreshIntervalMs"/>; a change inside that time is refreshed by the first pass after it.
    /// The uninstaller passes empty lists with <paramref name="adultFilter"/> false, which removes every owned value and list subkey and then deletes keys left empty.
    /// </summary>
    public bool Enforce(BrowserBlockLists lists, bool adultFilter, bool causedByCommand)
    {
        bool healthy = true;
        foreach (BrowserTarget target in Enum.GetValues<BrowserTarget>())
        {
            ReportCut(target, lists);
            var desired = WindowsBrowserPolicy.Desired(target, lists, adultFilter);
            try
            {
                bool changed = EnforceTarget(desired);
                // Only the uninstall turns the filter off; then the keys SiteBlock emptied are removed too, deepest first.
                if (!adultFilter) changed |= RemoveEmptyKeys(desired);
                if (changed) _refreshWanted = true;
                if (changed && !causedByCommand) _log.Write($"browser policy repaired ({target.DisplayName()})");
            }
            catch (Exception error)
            {
                // Any failure is caught per browser, so one broken key never stops the other browsers from being repaired in this pass.
                healthy = false;
                LogFailure($"browser policy for {target.DisplayName()} could not be written: {error.GetType().Name}: {error.Message}");
            }
        }
        if (healthy) _lastFailures.Clear();
        RefreshIfDue();
        return healthy;
    }

    /// <summary>Asks the browsers to read their policy again when a change is waiting and the last request is at least <see cref="MinRefreshIntervalMs"/> old. A failed request is logged and tried again by the next pass.</summary>
    private void RefreshIfDue()
    {
        if (!_refreshWanted) return;
        long now = _now();
        if (_lastRefresh is long last && now - last < MinRefreshIntervalMs) return;
        // The time is taken before the call, so a request that fails also waits out the interval and a broken refresh is not retried on every tick.
        _lastRefresh = now;
        try
        {
            _refresher.Refresh();
            _refreshWanted = false;
        }
        catch (Exception error)
        {
            LogFailure($"browsers could not be told to read their policy again: {error.GetType().Name}: {error.Message}");
        }
    }

    /// <summary>Brings one browser's key in line with the wanted values and lists. Returns true when anything was written or deleted.</summary>
    private bool EnforceTarget(RegistryPolicy desired)
    {
        bool changed = false;
        foreach (var (subkey, ownedNames) in desired.OwnedValueNames)
        {
            string keyPath = Join(desired.KeyPath, subkey);
            var actual = _store.ReadValues(keyPath) ?? new Dictionary<string, RegValue>();
            var wanted = desired.Values.GetValueOrDefault(subkey) ?? new Dictionary<string, RegValue>();
            foreach (string name in ownedNames.Order(StringComparer.Ordinal))
            {
                bool has = actual.TryGetValue(name, out RegValue current);
                if (wanted.TryGetValue(name, out RegValue value))
                {
                    // A value of the right name but the wrong type counts as wrong, because a browser ignores a policy of the wrong type.
                    if (!has || current != value)
                    {
                        _store.SetValue(keyPath, name, value);
                        changed = true;
                    }
                }
                else if (has)
                {
                    _store.DeleteValue(keyPath, name);
                    changed = true;
                }
            }
        }
        foreach (string listSubkey in desired.OwnedListSubkeys.Order(StringComparer.Ordinal))
        {
            string keyPath = Join(desired.KeyPath, listSubkey);
            if (desired.Lists.TryGetValue(listSubkey, out var entries))
            {
                // The list is replaced as a whole, so a stray value such as "1001" added by hand never survives.
                var actual = _store.ReadValues(keyPath);
                if (actual is null || !WindowsBrowserPolicy.ListMatches(entries, actual))
                {
                    _store.ReplaceList(keyPath, entries);
                    changed = true;
                }
            }
            else if (_store.KeyExists(keyPath))
            {
                _store.DeleteKey(keyPath);
                changed = true;
            }
        }
        return changed;
    }

    /// <summary>
    /// After an uninstall pass, deletes the keys SiteBlock emptied: owned value subkeys (Firefox's DNSOverHTTPS), the parents of list subkeys inside the policy key (Firefox's WebsiteFilter),
    /// and the policy key itself, each only when nothing else is left in it. Returns true when a key was deleted.
    /// </summary>
    private bool RemoveEmptyKeys(RegistryPolicy desired)
    {
        var candidates = new List<string>();
        foreach (string subkey in desired.OwnedValueNames.Keys) if (subkey.Length > 0) candidates.Add(Join(desired.KeyPath, subkey));
        foreach (string listSubkey in desired.OwnedListSubkeys)
        {
            // Each parent between the list subkey and the policy key, for example WebsiteFilter for WebsiteFilter\Block.
            string[] parts = listSubkey.Split('\\');
            for (int i = parts.Length - 1; i >= 1; i--) candidates.Add(Join(desired.KeyPath, string.Join('\\', parts[..i])));
        }
        candidates.Add(desired.KeyPath);
        bool changed = false;
        // The deepest keys go first, so a parent is checked only after its children are gone.
        foreach (string keyPath in candidates.Distinct(StringComparer.OrdinalIgnoreCase).OrderByDescending(path => path.Count(c => c == '\\')))
        {
            if (_store.KeyIsEmpty(keyPath))
            {
                _store.DeleteKey(keyPath);
                changed = true;
            }
        }
        return changed;
    }

    /// <summary>Logs once when a browser's list had to be cut to the 1,000 entries the browser reads, and forgets the report when the list is short enough again.</summary>
    private void ReportCut(BrowserTarget target, BrowserBlockLists lists)
    {
        var (sites, paths) = target.Lists(lists);
        int dropped = BrowserPolicy.Capped(sites, paths).DroppedCount;
        if (dropped == 0)
        {
            _reportedCuts.Remove(target);
        }
        else if (_reportedCuts.Add(target))
        {
            _log.Write($"browser block list for {target.DisplayName()} cut to {BrowserPolicy.MaxListEntries} entries; {dropped} path rules or sites are not enforced in that browser");
        }
    }

    /// <summary>Joins a key path and a relative subkey path ("" means the key itself).</summary>
    private static string Join(string keyPath, string subkey) => subkey.Length == 0 ? keyPath : keyPath + "\\" + subkey;

    /// <summary>Logs a failure message unless the same message was logged within the last minute.</summary>
    private void LogFailure(string message)
    {
        long now = Environment.TickCount64;
        if (_lastFailures.TryGetValue(message, out long at) && now - at < RepeatedFailureLogIntervalMs) return;
        _lastFailures[message] = now;
        _log.Write(message);
    }
}

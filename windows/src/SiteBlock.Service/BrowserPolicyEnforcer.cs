using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>
/// Keeps the registry policy of Chrome, Edge, Brave and Firefox equal to what <see cref="WindowsBrowserPolicy.Desired"/> wants, on every enforcement pass (06-windows.md § BrowserPolicyEnforcer).
/// For each browser it compares every value SiteBlock owns by name, type and content, and every owned list subkey value by value, and rewrites only what differs.
/// Values and subkeys SiteBlock does not own are never touched. The same values are also kept in the computer's Local Group Policy file; after that file changes, Windows is asked to apply it, which makes Windows
/// signal running browsers to read their policy again.
/// </summary>
public sealed class BrowserPolicyEnforcer : IBrowserPolicyEnforcer
{
    // A failure message that repeats is logged at most this often (milliseconds), so a problem that happens every tick does not fill the log.
    private const long RepeatedFailureLogIntervalMs = 60_000;

    // The shortest time between two policy refreshes (milliseconds). A change that comes sooner is refreshed when this has passed, so a run of changes never makes Windows apply policy over and over.
    internal const long MinRefreshIntervalMs = 5_000;
    // How long after a refresh request a registry change found by a pass is not logged as a repair (milliseconds). Windows applies the policy file by clearing each list and writing it again,
    // so a pass in the middle of that finds a list short and writes it back, which is not tampering.
    internal const long RefreshQuietMs = 30_000;

    private readonly IPolicyStore _store;
    private readonly IPolicyRefresher _refresher;
    private readonly string? _localPolicyFile;
    private readonly string? _localPolicyIni;
    private readonly Func<long> _now;
    private readonly Log _log;
    // True when a pass changed the Local Group Policy file and Windows has not yet been asked to apply it.
    private bool _refreshWanted;
    // When the last refresh was asked for (milliseconds from the clock), or null before the first one.
    private long? _lastRefresh;
    // When each failure message was last logged (Environment.TickCount64), tracked per message because several browsers can fail in one pass.
    private readonly Dictionary<string, long> _lastFailures = new(StringComparer.Ordinal);
    // The browsers whose list was too long on the last pass and has already been reported, so the cut is logged once and not on every tick.
    private readonly HashSet<BrowserTarget> _reportedCuts = [];

    /// <summary>
    /// Creates an enforcer that writes the registry through the given store and keeps the Local Group Policy file and its gpt.ini at the given paths (null paths leave Local Group Policy alone),
    /// asking Windows to apply that file through the refresher. The clock (milliseconds) defaults to <see cref="Environment.TickCount64"/>.
    /// </summary>
    public BrowserPolicyEnforcer(IPolicyStore store, IPolicyRefresher refresher, Log log, string? localPolicyFile = null, string? localPolicyIni = null, Func<long>? now = null)
    {
        _store = store;
        _refresher = refresher;
        _log = log;
        _localPolicyFile = localPolicyFile;
        _localPolicyIni = localPolicyIni;
        _now = now ?? (() => Environment.TickCount64);
    }

    /// <summary>
    /// Runs one pass for all four browsers and returns true when every browser ended correct. A pass that changes anything a command did not ask for logs "browser policy repaired (&lt;browser&gt;)".
    /// It then makes SiteBlock's entries in the Local Group Policy file match, and after that file changed, asks Windows to apply it, at most once every <see cref="MinRefreshIntervalMs"/>; a change inside that time
    /// is refreshed by the first pass after it.
    /// The uninstaller passes empty lists with <paramref name="adultFilter"/> false, which removes every owned value and list subkey and then deletes keys left empty.
    /// </summary>
    public bool Enforce(BrowserBlockLists lists, bool adultFilter, bool causedByCommand)
    {
        bool healthy = true;
        var allDesired = new List<RegistryPolicy>();
        // Inside the quiet time after a refresh request, Windows may be rewriting the lists itself, so what a pass puts back is not reported as tampering.
        bool quiet = _lastRefresh is long refreshed && _now() - refreshed < RefreshQuietMs;
        foreach (BrowserTarget target in Enum.GetValues<BrowserTarget>())
        {
            ReportCut(target, lists);
            var desired = WindowsBrowserPolicy.Desired(target, lists, adultFilter);
            allDesired.Add(desired);
            try
            {
                bool changed = EnforceTarget(desired);
                // Only the uninstall turns the filter off; then the keys SiteBlock emptied are removed too, deepest first.
                if (!adultFilter) changed |= RemoveEmptyKeys(desired);
                if (changed && !causedByCommand && !quiet) _log.Write($"browser policy repaired ({target.DisplayName()})");
            }
            catch (Exception error)
            {
                // Any failure is caught per browser, so one broken key never stops the other browsers from being repaired in this pass.
                healthy = false;
                LogFailure($"browser policy for {target.DisplayName()} could not be written: {error.GetType().Name}: {error.Message}");
            }
        }
        if (healthy) _lastFailures.Clear();
        if (EnforceLocalPolicy(allDesired)) _refreshWanted = true;
        RefreshIfDue();
        return healthy;
    }

    /// <summary>
    /// Makes SiteBlock's entries in the Local Group Policy file equal to the wanted values (<see cref="LocalGroupPolicy.Merged"/>), keeping every other entry, and raises the computer version in gpt.ini so
    /// Windows applies the file. Returns true when the file was written. A file that does not follow the format is left alone and reported, because rewriting it would lose the owner's own settings.
    /// A failure never affects the registry pass, which already ran.
    /// </summary>
    private bool EnforceLocalPolicy(IReadOnlyList<RegistryPolicy> desired)
    {
        if (_localPolicyFile is null || _localPolicyIni is null) return false;
        try
        {
            List<PolEntry> existing = File.Exists(_localPolicyFile) ? RegistryPol.Parse(File.ReadAllBytes(_localPolicyFile)) : [];
            if (LocalGroupPolicy.Merged(existing, desired) is not { } merged) return false;
            // A file that does not exist yet and would hold nothing is not created.
            if (merged.Count == 0 && !File.Exists(_localPolicyFile)) return false;
            WriteReplacing(_localPolicyFile, RegistryPol.Serialize(merged));
            string? ini = File.Exists(_localPolicyIni) ? File.ReadAllText(_localPolicyIni) : null;
            // gpt.ini is plain ASCII text, as Windows writes it.
            WriteReplacing(_localPolicyIni, System.Text.Encoding.ASCII.GetBytes(LocalGroupPolicy.UpdatedGptIni(ini)));
            return true;
        }
        catch (PolFormatException error)
        {
            LogFailure($"the Local Group Policy file was left alone because it could not be read: {error.Message}");
            return false;
        }
        catch (Exception error)
        {
            LogFailure($"the Local Group Policy file could not be written: {error.GetType().Name}: {error.Message}");
            return false;
        }
    }

    /// <summary>Writes the bytes to a temporary file beside the target and then moves it over the target, so Windows never reads a half-written file.</summary>
    private static void WriteReplacing(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".siteblock-tmp";
        File.WriteAllBytes(temp, bytes);
        File.Move(temp, path, overwrite: true);
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
            _log.Write("asked Windows to apply the Local Group Policy, so running browsers read the new block lists");
        }
        catch (Exception error)
        {
            LogFailure($"Windows could not be asked to apply the Local Group Policy: {error.GetType().Name}: {error.Message}");
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

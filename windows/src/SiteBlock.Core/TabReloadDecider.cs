namespace SiteBlock.Core;

/// <summary>
/// Decides which browser tabs the tab watcher should reload, and remembers which tab it already reloaded at which address, so a tab that is showing the browser's block page is not reloaded over and over.
/// It holds no browser access; the tab watcher feeds it the tab lists it reads. It is not thread-safe, because the tab watcher uses it from one loop.
/// </summary>
public sealed class TabReloadDecider
{
    /// <summary>For each browser process id, the address the watcher last acted on for each of its tabs (keyed by tab id). A tab appears here only while its address matches a rule.</summary>
    private readonly Dictionary<int, Dictionary<string, string>> _memory = [];

    /// <summary>
    /// Takes the complete tab list of one browser process and returns the ids of the tabs to reload now, in the order they were given.
    /// A tab is returned when its address matches a rule and the watcher has not already acted on that tab at that address; the address is then remembered.
    /// A tab that still matches at the address already remembered is left alone. A tab that no longer matches is forgotten, so going back to the blocked part later reloads it again, and so are tabs missing from the list.
    /// With no rules it returns nothing and forgets everything about the process.
    /// </summary>
    public List<string> TabsToReload(int processId, IEnumerable<(string Id, string Url)> tabs, IReadOnlyCollection<WatchedPathRule> rules)
    {
        ArgumentNullException.ThrowIfNull(tabs);
        ArgumentNullException.ThrowIfNull(rules);
        // With no rules there is nothing to act on, and nothing worth remembering.
        if (rules.Count == 0)
        {
            _memory.Remove(processId);
            return [];
        }
        Dictionary<string, string> previous = _memory.TryGetValue(processId, out var known) ? known : [];
        var updated = new Dictionary<string, string>(StringComparer.Ordinal);
        var toReload = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (id, url) in tabs)
        {
            // A tab id that appears twice in one list is handled once, by its first appearance, whether that one matches or not; later appearances are ignored.
            if (!seen.Add(id)) continue;
            // A tab that does not match is simply left out of the new memory, which is how it is forgotten.
            if (TabRuleMatcher.MatchingRule(url, rules) is null) continue;
            if (!previous.TryGetValue(id, out var remembered) || remembered != url) toReload.Add(id);
            updated[id] = url;
        }
        // Only the tabs seen in this list survive, so the memory of tabs that closed is dropped here too.
        if (updated.Count == 0) _memory.Remove(processId);
        else _memory[processId] = updated;
        return toReload;
    }

    /// <summary>Drops what is remembered about every process that is not in <paramref name="running"/>, because those browsers have quit.</summary>
    public void ForgetProcesses(IReadOnlySet<int> running)
    {
        ArgumentNullException.ThrowIfNull(running);
        foreach (int processId in _memory.Keys.ToList())
        {
            if (!running.Contains(processId)) _memory.Remove(processId);
        }
    }

    /// <summary>Drops everything that is remembered.</summary>
    public void ForgetAll() => _memory.Clear();

    /// <summary>A copy of the address remembered for each tab of one process, keyed by tab id; empty when nothing is remembered. Read-only, for tests.</summary>
    public IReadOnlyDictionary<string, string> Remembered(int processId) =>
        _memory.TryGetValue(processId, out var tabs) ? new Dictionary<string, string>(tabs, StringComparer.Ordinal) : new Dictionary<string, string>();
}

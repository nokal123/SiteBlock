import Foundation

/// Decides which browser tabs the tab watcher should reload, and remembers which tab it already reloaded at which address, so a tab that is showing the browser's block page is not reloaded over and over.
public struct TabReloadDecider: Sendable {
    /// For each browser process id, the address the watcher last acted on for each of its tabs (keyed by tab id). A tab appears here only while its address matches a rule.
    private var memory: [Int32: [String: String]] = [:]

    /// Creates a decider that has not acted on any tab yet.
    public init() {}

    /// Takes the complete tab list of one browser process and returns the ids of the tabs to reload now, in the order they were given. A tab is returned when its address matches a rule and the watcher has not already acted on that tab at that address; the address is then remembered. A tab that still matches at the address already remembered is left alone. A tab that no longer matches is forgotten, so going back to the blocked part later reloads it again, and so are tabs missing from the list. With no rules it returns nothing and forgets everything about the process.
    public mutating func tabsToReload(processID: Int32, tabs: [(id: String, url: String)], rules: [WatchedPathRule]) -> [String] {
        // With no rules there is nothing to act on, and nothing worth remembering.
        guard !rules.isEmpty else {
            memory[processID] = nil
            return []
        }
        let previous = memory[processID] ?? [:]
        var updated: [String: String] = [:]
        var toReload: [String] = []
        var seen: Set<String> = []
        for tab in tabs {
            // A tab id that appears twice in one list is handled once, by its first appearance, whether that one matches or not; later appearances are ignored.
            guard seen.insert(tab.id).inserted else { continue }
            // A tab that does not match is simply left out of the new memory, which is how it is forgotten.
            guard TabRuleMatcher.matchingRule(url: tab.url, rules: rules) != nil else { continue }
            if previous[tab.id] != tab.url { toReload.append(tab.id) }
            updated[tab.id] = tab.url
        }
        // Only the tabs seen in this list survive, so the memory of tabs that closed is dropped here too.
        memory[processID] = updated.isEmpty ? nil : updated
        return toReload
    }

    /// Drops what is remembered about every process that is not in `running`, because those browsers have quit.
    public mutating func forgetProcesses(except running: Set<Int32>) {
        memory = memory.filter { running.contains($0.key) }
    }

    /// Drops everything that is remembered.
    public mutating func forgetAll() {
        memory.removeAll()
    }

    /// The address remembered for each tab of one process, keyed by tab id; empty when nothing is remembered. Read-only, for tests.
    public func remembered(processID: Int32) -> [String: String] {
        memory[processID] ?? [:]
    }
}

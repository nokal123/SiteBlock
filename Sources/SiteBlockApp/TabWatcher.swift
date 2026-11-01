import AppKit
import CoreServices
import Foundation
import SiteBlockCore
import os

/// Watches the open tabs of Chrome, Edge, Brave and Safari and sends a tab to the SiteBlock blocked page (see `BlockedPage`) once when its address is on a blocked site or a blocked part of a site. The browsers' own defences miss two cases that this catches. A running browser keeps the copy of its block list it read earlier and keeps sending a site's pages down a connection it already has open, so a site blocked a moment ago still loads in it (a new tab included) until the browser restarts. And a site can move to a blocked part of itself without loading a new page (YouTube does this when you tap Shorts: the address becomes youtube.com/shorts/..., but no page load happens). The watcher does nothing unless a rule exists and a supported browser is running.
///
/// All the mutable state is either behind `shared` (the rules and the "a tick is running" flag, which other threads touch) or used only on `queue` (everything else), which is why the class can be marked `@unchecked Sendable`.
final class TabWatcher: @unchecked Sendable {
    /// How much later than due a tick may start, as a share of the time between ticks (50 ms for half-second ticks, 400 ms for four-second ticks). It lets macOS group the timer with other wake-ups to save power.
    private static let tickLeewayShare = 0.1
    /// How long to wait, in seconds, before asking macOS again about a browser that has not allowed control. It lets a person turn the permission on in System Settings later without restarting the app.
    private static let permissionRecheckSeconds = 10.0
    /// The reason given to macOS for keeping the app awake while it checks tabs.
    private static let activityReason = "Checking browser tabs for blocked sites"
    /// The macOS error number for "not allowed to send Apple Events to this app", which also arrives when the permission is switched off after it was granted.
    private static let notPermittedCode = Int(errAEEventNotPermitted)

    /// What macOS last said about one browser process, and when it was asked.
    private struct PermissionRecord {
        /// The answer.
        var permission: AutomationPermission
        /// When the answer came, on the monotonic clock.
        var checkedAt: ContinuousClock.Instant
    }

    /// The values that the main thread, the timer and the work queue all touch.
    private struct Shared {
        /// The whole-site and path rules to watch for, as last given to `setRules`.
        var rules: [WatchedPathRule] = []
        /// True while a tick is queued or running. A timer firing during that time does nothing, so slow ticks never pile up.
        var tickRunning = false
    }

    /// The shared values, behind a lock so `setRules` takes effect at once even while a tick is stuck waiting for the person to answer a macOS prompt.
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// The serial queue that runs every tick and owns the state below.
    private let queue = DispatchQueue(label: "com.nokal.siteblock.app.tabs", qos: .userInitiated)
    /// The repeating timer. It runs on its own queue (not `queue`), so it can still fire, and skip, while a tick is busy.
    private let timer: DispatchSourceTimer
    /// Where blocked tabs and permission changes are logged.
    private let log = Logger(subsystem: "com.nokal.siteblock.app", category: "tabs")
    /// Called, on the work queue, with the sorted names of the running browsers whose permission is denied, each time that list changes.
    private let onDeniedBrowsersChanged: @Sendable ([String]) -> Void

    // Everything below is used only on `queue`.

    /// Remembers which tab was sent to the blocked page from which address, so a tab whose change did not take is not sent again and again.
    private var decider = TabReloadDecider()
    /// The macOS "this app is doing work" token that keeps App Nap (which slows timers of apps without a visible window) from delaying the checks. It is held while at least one rule exists.
    private var activity: NSObjectProtocol?
    /// The last permission answer for each running browser process.
    private var permissions: [pid_t: PermissionRecord] = [:]
    /// The bundle identifiers for which the macOS permission question has already been asked in this run of the app.
    private var askedBundleIDs: Set<String> = []
    /// The last permission logged for each bundle identifier, so only changes are written to the log.
    private var loggedPermissions: [String: AutomationPermission] = [:]
    /// The denied-browser list most recently sent to `onDeniedBrowsersChanged`.
    private var publishedDeniedNames: [String] = []

    /// Creates the watcher and starts its timer. `onDeniedBrowsersChanged` is called on the work queue whenever the list of denied browsers changes.
    init(onDeniedBrowsersChanged: @escaping @Sendable ([String]) -> Void) {
        self.onDeniedBrowsersChanged = onDeniedBrowsersChanged
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.nokal.siteblock.app.tabs.timer", qos: .userInitiated))
        let seconds = WatchedPathRule.checkSeconds(for: [])
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: Self.leeway(for: seconds))
        timer.setEventHandler { [weak self] in self?.timerFired() }
        timer.resume()
    }

    /// The leeway for ticks that come every `seconds` seconds.
    private static func leeway(for seconds: Double) -> DispatchTimeInterval {
        .milliseconds(Int(seconds * tickLeewayShare * 1000))
    }

    /// Stops the timer and lets macOS go back to napping the app.
    deinit {
        timer.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Replaces the list of rules to watch for. The status model calls it with `watchedTabRules` of every status snapshot it applies. When the list differs from the last one, the tabs are checked at once, so a site blocked in the app is caught right away, and the time between ticks is set for the new list (see `WatchedPathRule.checkSeconds`). An unchanged list leaves the timer alone.
    func setRules(_ rules: [WatchedPathRule]) {
        let changed = shared.withLock { state -> Bool in
            guard state.rules != rules else { return false }
            state.rules = rules
            return true
        }
        guard changed else { return }
        let seconds = WatchedPathRule.checkSeconds(for: rules)
        // Re-arming a dispatch timer is safe from any thread; a tick still running when it fires is skipped as usual.
        timer.schedule(deadline: .now(), repeating: seconds, leeway: Self.leeway(for: seconds))
    }

    // MARK: - Timer

    /// Runs on every timer beat. It starts a tick on the work queue unless the previous one is still queued or running, in which case this beat is skipped, not queued.
    private func timerFired() {
        let claimed = shared.withLock { state -> Bool in
            if state.tickRunning { return false }
            state.tickRunning = true
            return true
        }
        guard claimed else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.tick()
            self.shared.withLock { $0.tickRunning = false }
        }
    }

    // MARK: - One tick

    /// One look at the browsers: find the tabs sitting on a blocked site or a blocked part of one, and send each one to the blocked page once.
    private func tick() {
        let rules = shared.withLock { $0.rules }
        // With no rules there is nothing to watch for, so no Apple Event is sent and the app may nap.
        guard !rules.isEmpty else {
            idle()
            return
        }
        // The app stays awake whenever a rule exists, even with no browser open, so the first check after a browser starts is not delayed by App Nap.
        beginActivity()
        let browsers = BrowserTabs.runningBrowsers()
        // With no supported browser running there are no tabs to look at, and nothing about earlier browser processes is worth keeping.
        guard !browsers.isEmpty else {
            decider.forgetAll()
            permissions.removeAll()
            publishDeniedNames([])
            return
        }

        var deniedNames: Set<String> = []
        for browser in browsers {
            let permission = currentPermission(of: browser)
            if permission == .denied { deniedNames.insert(browser.name) }
            // Only a browser that allowed control is read; in the others only the browser's own block list and the hosts file apply.
            guard permission == .allowed else { continue }
            check(browser, rules: rules)
        }
        publishDeniedNames(deniedNames.sorted())

        // Memory about browsers that quit is dropped, so a new browser process that reuses a process id starts clean.
        let running = Set(browsers.map { $0.pid })
        decider.forgetProcesses(except: running)
        permissions = permissions.filter { running.contains($0.key) }
    }

    /// The state when there are no rules: forget what was remembered, let the app nap, and report no denied browsers.
    private func idle() {
        decider.forgetAll()
        permissions.removeAll()
        endActivity()
        publishDeniedNames([])
    }

    /// Reads one browser's tabs and sends those on a blocked site or a blocked part of one to the blocked page.
    private func check(_ browser: RunningBrowser, rules: [WatchedPathRule]) {
        let tabs: [BrowserTab]
        do {
            tabs = try BrowserTabs.readTabs(browser)
        } catch {
            // A timeout, a browser that just quit and similar errors only skip this browser for this tick; its memory is kept. A permission that was switched off is the exception: it is recorded at once so the banner can show.
            if let failure = error as? BrowserTabsError, failure.code == Self.notPermittedCode { recordPermission(.denied, for: browser) }
            return
        }
        // The decider knows tabs by their key (window id and tab id joined), and this table finds each tab again from its key.
        let tabsByKey = Dictionary(tabs.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let toBlock = decider.tabsToReload(processID: browser.pid, tabs: tabs.map { (id: $0.key, url: $0.url) }, rules: rules)
        for key in toBlock {
            guard let tab = tabsByKey[key] else { continue }
            // The address is read again right before the change, because the page may have moved on since the list was read, and in Safari a tab that opened or closed in between shifts the positions so the same position may now be another tab. Only a tab whose address still matches is changed.
            // The decider already counts this tab as handled, so any failure (the tab moved on or closed, or the browser timed out while busy loading) makes it forget the tab, and the next tick tries again instead of leaving the tab on the blocked site until its address changes.
            guard let current = try? BrowserTabs.currentURL(browser, windowID: tab.windowID, tabID: tab.tabID), let rule = TabRuleMatcher.matchingRule(url: current, rules: rules), (try? BrowserTabs.open(BlockedPage.address(ruleText: rule.displayText), in: browser, windowID: tab.windowID, tabID: tab.tabID, currentURL: current)) != nil else {
                decider.forget(processID: browser.pid, tabID: key)
                continue
            }
            log.info("sent a \(browser.name, privacy: .public) tab to the blocked page: \(rule.displayText, privacy: .public)")
        }
    }

    // MARK: - Permission

    /// The permission for one browser process. The first time a browser (by bundle identifier) is seen in this run, macOS is asked with its prompt allowed. A browser that has not allowed control is asked about again, without a prompt, at most every ten seconds, so turning it on in System Settings takes effect without a restart. An allowed browser is not asked again.
    private func currentPermission(of browser: RunningBrowser) -> AutomationPermission {
        let now = ContinuousClock.now
        if let record = permissions[browser.pid] {
            if record.permission == .allowed { return .allowed }
            if now - record.checkedAt < .seconds(Self.permissionRecheckSeconds) { return record.permission }
        }
        let ask = !askedBundleIDs.contains(browser.bundleID)
        // With ask true this call waits for the person to answer the macOS prompt, which is why it runs here on the work queue and never on the main thread. Timer beats during the wait are skipped.
        let answer = BrowserTabs.permission(pid: browser.pid, ask: ask)
        // Only a real answer ends the asking. If the browser was still starting up, the question is asked again at the next check.
        if ask, answer == .allowed || answer == .denied { askedBundleIDs.insert(browser.bundleID) }
        recordPermission(answer, for: browser)
        return answer
    }

    /// Stores a permission answer for a browser process and logs it when it differs from the last one logged for that browser.
    private func recordPermission(_ permission: AutomationPermission, for browser: RunningBrowser) {
        permissions[browser.pid] = PermissionRecord(permission: permission, checkedAt: ContinuousClock.now)
        // "Not asked" and "unavailable" are passing states, not decisions, so only allowed and denied are logged.
        guard permission == .allowed || permission == .denied, loggedPermissions[browser.bundleID] != permission else { return }
        loggedPermissions[browser.bundleID] = permission
        log.info("permission to control \(browser.name, privacy: .public): \(permission == .allowed ? "allowed" : "denied", privacy: .public)")
    }

    /// Sends the denied-browser list to the owner, but only when it differs from the list sent last.
    private func publishDeniedNames(_ names: [String]) {
        guard names != publishedDeniedNames else { return }
        publishedDeniedNames = names
        onDeniedBrowsersChanged(names)
    }

    // MARK: - App Nap

    /// Tells macOS the app is doing work that must not be delayed, unless that is already so. Without it, App Nap would stretch the timer to many seconds because the app has no visible window.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: Self.activityReason)
    }

    /// Tells macOS the work is over, so the app may nap again.
    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

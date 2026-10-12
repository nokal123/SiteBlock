import AppKit
import CoreServices
import Foundation
import SiteBlockCore
import os

/// Watches the open tabs of Chrome, Edge and Brave and reloads a tab once when it has moved onto a blocked part of a site without loading a new page (YouTube does this when you tap Shorts: the address becomes youtube.com/shorts/..., but no page load happens, so the browser's block list is not applied). A reload is a real page load, so the browser's own block list then shows its block page. The watcher does nothing unless a path rule exists and a supported browser is running.
///
/// All the mutable state is either behind `shared` (the rules and the "a tick is running" flag, which other threads touch) or used only on `queue` (everything else), which is why the class can be marked `@unchecked Sendable`.
final class TabWatcher: @unchecked Sendable {
    /// How often, in seconds, the watcher looks at the tabs.
    private static let tickSeconds = 0.5
    /// How much later than due a tick may start, in milliseconds. It lets macOS group the timer with other wake-ups to save power.
    private static let tickLeewayMilliseconds = 100
    /// How long to wait, in seconds, before asking macOS again about a browser that has not allowed control. It lets a person turn the permission on in System Settings later without restarting the app.
    private static let permissionRecheckSeconds = 10.0
    /// The reason given to macOS for keeping the app awake while it checks tabs.
    private static let activityReason = "Checking browser tabs for blocked parts of sites"
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
        /// The path rules to watch for, as last given to `setRules`.
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
    /// Where reloads and permission changes are logged.
    private let log = Logger(subsystem: "com.nokal.siteblock.app", category: "tabs")
    /// Called, on the work queue, with the sorted names of the running browsers whose permission is denied, each time that list changes.
    private let onDeniedBrowsersChanged: @Sendable ([String]) -> Void

    // Everything below is used only on `queue`.

    /// Remembers which tab was reloaded at which address, so a tab showing a block page is not reloaded again and again.
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
        timer.schedule(deadline: .now() + Self.tickSeconds, repeating: Self.tickSeconds, leeway: .milliseconds(Self.tickLeewayMilliseconds))
        timer.setEventHandler { [weak self] in self?.timerFired() }
        timer.resume()
    }

    /// Stops the timer and lets macOS go back to napping the app.
    deinit {
        timer.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Replaces the list of path rules to watch for. The status model calls it with the rules of every status snapshot it applies. The new list is used from the next tick.
    func setRules(_ rules: [WatchedPathRule]) {
        shared.withLock { $0.rules = rules }
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

    /// One look at the browsers: find the tabs sitting on a blocked part of a site and reload each one once.
    private func tick() {
        let rules = shared.withLock { $0.rules }
        // With no rules there is nothing to watch for, so no Apple Event is sent and the app may nap.
        guard !rules.isEmpty else {
            idle()
            return
        }
        // The app stays awake whenever a rule exists, even with no browser open, so the first check after a browser starts is not delayed by App Nap.
        beginActivity()
        let browsers = ChromiumTabs.runningBrowsers()
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
            // Only a browser that allowed control is read; the others keep working as before (the block list applies on reload or a direct open).
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

    /// Reads one browser's tabs and reloads those that moved onto a blocked part of a site.
    private func check(_ browser: (pid: pid_t, bundleID: String, name: String), rules: [WatchedPathRule]) {
        let tabs: [(windowID: String, tabID: String, url: String)]
        do {
            tabs = try ChromiumTabs.readTabs(pid: browser.pid)
        } catch {
            // A timeout, a browser that just quit and similar errors only skip this browser for this tick; its memory is kept. A permission that was switched off is the exception: it is recorded at once so the banner can show.
            if let failure = error as? ChromiumTabsError, failure.code == Self.notPermittedCode { recordPermission(.denied, for: browser) }
            return
        }
        // The decider only needs tab ids and addresses; the window ids are kept here to find each tab again.
        let windowByTab = Dictionary(tabs.map { ($0.tabID, $0.windowID) }, uniquingKeysWith: { first, _ in first })
        let toReload = decider.tabsToReload(processID: browser.pid, tabs: tabs.map { (id: $0.tabID, url: $0.url) }, rules: rules)
        for tabID in toReload {
            guard let windowID = windowByTab[tabID] else { continue }
            // The address is read again right before the reload, because the page may have moved on since the list was read (and a reload then would hit the wrong page). Errors are ignored: the tab may be gone.
            guard let current = try? ChromiumTabs.currentURL(pid: browser.pid, windowID: windowID, tabID: tabID), let rule = TabRuleMatcher.matchingRule(url: current, rules: rules) else { continue }
            guard (try? ChromiumTabs.reload(pid: browser.pid, windowID: windowID, tabID: tabID)) != nil else { continue }
            let ruleText = PathRuleParser.display(domain: rule.domain, path: rule.path)
            log.info("reloaded a \(browser.name, privacy: .public) tab on a blocked part of a site: \(ruleText, privacy: .public)")
        }
    }

    // MARK: - Permission

    /// The permission for one browser process. The first time a browser (by bundle identifier) is seen in this run, macOS is asked with its prompt allowed. A browser that has not allowed control is asked about again, without a prompt, at most every ten seconds, so turning it on in System Settings takes effect without a restart. An allowed browser is not asked again.
    private func currentPermission(of browser: (pid: pid_t, bundleID: String, name: String)) -> AutomationPermission {
        let now = ContinuousClock.now
        if let record = permissions[browser.pid] {
            if record.permission == .allowed { return .allowed }
            if now - record.checkedAt < .seconds(Self.permissionRecheckSeconds) { return record.permission }
        }
        let ask = !askedBundleIDs.contains(browser.bundleID)
        // With ask true this call waits for the person to answer the macOS prompt, which is why it runs here on the work queue and never on the main thread. Timer beats during the wait are skipped.
        let answer = ChromiumTabs.permission(pid: browser.pid, ask: ask)
        // Only a real answer ends the asking. If the browser was still starting up, the question is asked again at the next check.
        if ask, answer == .allowed || answer == .denied { askedBundleIDs.insert(browser.bundleID) }
        recordPermission(answer, for: browser)
        return answer
    }

    /// Stores a permission answer for a browser process and logs it when it differs from the last one logged for that browser.
    private func recordPermission(_ permission: AutomationPermission, for browser: (pid: pid_t, bundleID: String, name: String)) {
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

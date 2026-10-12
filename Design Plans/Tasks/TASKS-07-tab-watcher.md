# Tasks: Tab Watcher
> **Corresponds to:** [02-core-components.md](../02-core-components.md) § TabRuleMatcher, § TabReloadDecider; [03-daemon-cli-app.md](../03-daemon-cli-app.md) § TabWatcher, § ChromiumTabs, § SiteBlock.app Menu Bar App; [04-infrastructure.md](../04-infrastructure.md) § Build Script, § Automatic Package Builds; [05-testing-and-operations.md](../05-testing-and-operations.md) § Unit Tests, § Installed-System Verification

**Scope:** Add the tab watcher to the menu bar app. It reloads a Chrome, Edge or Brave tab that moves to a blocked part of a site without loading a page, so the browser's own block list then shows its block page. This covers two pure logic types in `SiteBlockCore`, the Apple Events bridge, the watcher, the permission banner, the Info.plist key, the failed-test annotations in the package workflow, and the tests.

**Prerequisites:** [TASKS-06-audit-fixes.md](TASKS-06-audit-fixes.md) complete. Path rules already exist end to end (`PathRuleParser`, `addPath`, `StatusSnapshot.blockedPaths`, and the browser block lists). `scripts/test.sh` passes.

**Code conventions:** same as TASKS-02. Every type and method has a `///` comment above it saying what it does in plain English, and the non-obvious decisions are commented where they are made. Update a comment in the same edit whenever the behavior it describes changes.

---

## Step 1: TabRuleMatcher

**File:** `Sources/SiteBlockCore/TabRuleMatcher.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § TabRuleMatcher
**Purpose:** Decide whether the address in a tab falls under a path rule, with the same matching the browsers apply to their block lists.

**Sub-steps:**
- 1a. `public struct WatchedPathRule: Hashable, Sendable` with `public let domain: String` and `public let path: String`, and a public initializer.
- 1b. `public enum TabRuleMatcher` with `static func matches(url: String, rule: WatchedPathRule) -> Bool`, implementing the six matching steps in order: parse with `URLComponents(string:)`; scheme `http` or `https` compared without regard to case; host through `DomainNormalizer.normalize`; host equals the domain or ends with `"." + domain`; `percentEncodedPath` (or `/` when empty) starts with the rule's path as a case-sensitive string prefix; port, user info, query and fragment ignored.
- 1c. `static func matchingRule(url: String, rules: [WatchedPathRule]) -> WatchedPathRule?` returning the first rule in list order that matches.

**Dependencies:** `DomainNormalizer` (already in `SiteBlockCore`).

**Acceptance Criteria:**
- [ ] `https://m.youtube.com/shorts/abc` matches the rule `youtube.com` with `/shorts`; `https://notyoutube.com/shorts` and `https://youtube.com/Shorts` do not.
- [ ] `chrome://settings`, `about:blank` and text that cannot be parsed return no match and do not crash.
- [ ] `swift build` gives no warnings.

---

## Step 2: TabReloadDecider

**File:** `Sources/SiteBlockCore/TabReloadDecider.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § TabReloadDecider
**Purpose:** Pick the tabs to reload and remember which tab was acted on at which address, so a tab is reloaded once per blocked address.

**Sub-steps:**
- 2a. `public struct TabReloadDecider: Sendable` holding a dictionary from process ID (`Int32`) to a dictionary from tab ID to the address last acted on.
- 2b. `public mutating func tabsToReload(processID: Int32, tabs: [(id: String, url: String)], rules: [WatchedPathRule]) -> [String]`. For each tab, in input order: a match with a different or missing remembered address is returned and remembered; a match with the same remembered address is skipped; a non-match drops that tab's memory. Memory for tab IDs not in the list is dropped. With no rules it returns nothing and clears that process's memory.
- 2c. `public mutating func forgetProcesses(except running: Set<Int32>)`, `public mutating func forgetAll()`, and `public func remembered(processID: Int32) -> [String: String]`.
- 2d. A process that is not passed to `tabsToReload` keeps its memory untouched. The decider never clears memory for processes it was not asked about.

**Dependencies:** Step 1.

**Acceptance Criteria:**
- [ ] Calling `tabsToReload` twice with the same blocked tab returns the tab the first time and nothing the second time.
- [ ] After a tab leaves the blocked part and returns, it is returned again.
- [ ] `swift build` gives no warnings.

---

## Step 3: ChromiumTabs

**File:** `Sources/SiteBlockApp/ChromiumTabs.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § ChromiumTabs
**Purpose:** Talk to Chrome, Edge and Brave over Apple Events. The file imports only Foundation, AppKit and CoreServices and uses no other app file, so a test harness can compile it alone.

**Sub-steps:**
- 3a. The supported browsers: `com.google.Chrome` ("Google Chrome"), `com.microsoft.edgemac` ("Microsoft Edge"), `com.brave.Browser` ("Brave"). The scripting codes: window class `cwin`, tab class `CrTb`, property `id` = `ID  `, property `URL` = `URL `, reload event class `CrSu` and event ID `Rlod`.
- 3b. `static func runningBrowsers() -> [(pid: pid_t, bundleID: String, name: String)]` from `NSWorkspace.shared.runningApplications`, skipping terminated applications. Every process is addressed by its process ID with `NSAppleEventDescriptor(processIdentifier:)`.
- 3c. `enum AutomationPermission` (`.allowed`, `.denied`, `.notAsked`, `.unavailable`) and `static func permission(pid: pid_t, ask: Bool) -> AutomationPermission` using `AEDeterminePermissionToAutomateTarget`. Map `noErr` to allowed, -1743 to denied, -1744 to notAsked, and anything else to unavailable. Comment that `ask: true` blocks until the person answers the prompt.
- 3d. Object specifiers as `NSAppleEventDescriptor` records of type `obj ` (keys `want`, `from`, `form`, `seld`) using `formUniqueID` for "window id W" and "tab id T", `formAbsolutePosition` with `kAEAll` for "every", and `formPropertyID` for properties. IDs go back out with the descriptor type they arrived in.
- 3e. `static func readTabs(pid: pid_t) throws -> [(windowID: String, tabID: String, url: String)]`: get the window IDs, then per window get the tab IDs, the tab addresses, and the tab IDs again. Use a window's tabs only when both ID lists are equal and the address list has the same count. IDs may arrive as integers or text and are stored as text.
- 3f. `static func currentURL(pid:windowID:tabID:) throws -> String` and `static func reload(pid:windowID:tabID:) throws`.
- 3g. Send every event with `sendEvent(options: [.waitForReply], timeout: 2)`.

**Dependencies:** none inside the package.

**Acceptance Criteria:**
- [ ] With Chrome running and the permission allowed, `readTabs` returns one entry per open tab, and `reload` reloads exactly the named tab.
- [ ] With the permission denied, `permission(pid:ask: false)` returns `.denied` and the other functions throw instead of hanging.
- [ ] `swift build` gives no warnings.

---

## Step 4: TabWatcher and StatusModel wiring

**Files:** `Sources/SiteBlockApp/TabWatcher.swift`, `Sources/SiteBlockApp/StatusModel.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § TabWatcher, § SiteBlock.app Menu Bar App
**Purpose:** Run the watch loop in the menu bar app and feed it the daemon's path rules.

**Sub-steps:**
- 4a. A watcher class on its own serial queue with a repeating timer every 0.5 seconds (leeway 0.1 seconds). A tick still running when the next is due makes the next tick be skipped, never queued.
- 4b. `func setRules(_ rules: [WatchedPathRule])`. `StatusModel` calls it every time it applies a snapshot, passing `snapshot.blockedPaths` mapped to `domain` and `path`.
- 4c. The eight tick steps in the design, in order: no rules clears the decider and ends the activity; no running browser forgets all memory and reports no denied browsers but keeps the activity; hold one `ProcessInfo.beginActivity` for as long as at least one rule exists; look up the permission (ask once per bundle identifier per app run, recheck a denial with `ask: false` at most every 10 seconds); read the tabs and skip a process on error; ask the decider, re-read each tab's current address, and reload only when it still matches; log each reload; forget exited processes.
- 4d. Logging with `os.Logger(subsystem: "com.nokal.siteblock.app", category: "tabs")` at info level, naming the rule and never the full address, and logging permission changes.
- 4e. `deniedBrowserNames: [String]` (sorted display names of running supported browsers whose permission is denied), published to `StatusModel` on the main actor whenever it changes.
- 4f. The watcher sends no Apple Events when there are no rules or no supported browser is running.

**Dependencies:** Steps 1 to 3.

**Acceptance Criteria:**
- [ ] With no path rule, a Chrome process receives no Apple Events from SiteBlock.
- [ ] A tab that switches to the blocked part of a site with `history.pushState` is reloaded once, and is not reloaded again while it stays on that address.
- [ ] `swift build -c release --product SiteBlockApp` succeeds with no warnings.

---

## Step 5: Permission banner

**File:** `Sources/SiteBlockApp/Views/BannersView.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (Panel states)

**Sub-steps:**
- 5a. When at least one path rule exists and `deniedBrowserNames` is not empty, show a banner: "Let SiteBlock control <names> so blocked parts of sites close right away." The names are joined with the word "and".
- 5b. Add an "Open Settings" button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.
- 5c. Match the style of the existing banners, and keep the text as short as given.

**Dependencies:** Step 4.

**Acceptance Criteria:**
- [ ] With the permission denied for Chrome and a path rule present, the panel shows the banner naming Google Chrome. Turning the permission on in System Settings removes the banner within about 10 seconds, without restarting the app.

---

## Step 6: Info.plist and the package workflow

**Files:** `Resources/Info.plist`, `.github/workflows/package.yml`
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Build Script, § Upgrade Behavior, § Automatic Package Builds

**Sub-steps:**
- 6a. Add `NSAppleEventsUsageDescription` to `Resources/Info.plist` with the text "SiteBlock checks the address of each open tab so a blocked part of a site closes as soon as you go to it." Without this key macOS refuses the app's Apple Events without asking. The app is signed ad hoc without the hardened runtime, so no entitlement is added.
- 6b. In the "Run the tests" step of the workflow, turn each failed test line (a line containing `✘`) into a GitHub error annotation, so failing test names are readable on the public run page without logging in. The step must still fail when a test fails.

**Acceptance Criteria:**
- [ ] `plutil -lint build/SiteBlock.app/Contents/Info.plist` is OK and contains the new key.
- [ ] Running the step's shell commands locally against test output that contains a `✘` line prints one `::error` line per failed test and exits with a non-zero code. A run with no failed test prints no `::error` line.

---

## Step 7: Tests

**Files:** `Tests/SiteBlockCoreTests/TabRuleMatcherTests.swift`, `Tests/SiteBlockCoreTests/TabReloadDeciderTests.swift`
**Reference:** [05-testing-and-operations.md](../05-testing-and-operations.md) § Unit Tests (TabRuleMatcherTests, TabReloadDeciderTests), § Installed-System Verification (Live tab-watcher test)

**Sub-steps:**
- 7a. Run the `qa-engineer` agent to write the unit tests for both Core types. Its expected values come from the design sections named above, not from the implementation. Cover the cases listed under TabRuleMatcherTests and TabReloadDeciderTests, including the adversarial ones.
- 7b. Run the `test-rigor-auditor` agent in a fresh invocation on the new test files and the same design sections, and send its findings back to the `qa-engineer` agent until the auditor is satisfied.
- 7c. Run the live test from the design: a sandbox daemon with a path rule, the built app started with `SITEBLOCK_SOCKET` pointing at it, and a separate visible Chrome instance driven over the Chrome DevTools Protocol that loads a page and then calls `history.pushState` onto the blocked path. The macOS prompt must be answered with Allow.

**Acceptance Criteria:**
- [ ] `scripts/test.sh` passes in full.
- [ ] In the live test, the watcher reloads the pushState tab exactly once and leaves the other tabs alone.

---

## Step 8: Verify

- [ ] `swift build` and `swift build -c release --product SiteBlockApp` give no warnings.
- [ ] `scripts/test.sh` passes in full.
- [ ] `scripts/build.sh` produces `build/SiteBlock.app` with the new Info.plist key, and `codesign --verify build/SiteBlock.app` succeeds.

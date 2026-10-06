# Tasks: Source Fixes From the Test Audits
> **Corresponds to:** [02-core-components.md](../02-core-components.md), [03-daemon-cli-app.md](../03-daemon-cli-app.md)

**Scope:** Fix one real defect (countdowns starting from a stale clock) and move three pieces of daemon logic into `SiteBlockCore`, so unit tests can reach them. Behavior does not change except in Step 1.

**Prerequisites:** All earlier task files are complete, and `scripts/test.sh` passes.

**Code conventions:** same as TASKS-02.

---

## Step 1: Bring countdowns up to date before every command

**File:** `Sources/siteblockd/DaemonRuntime.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime ("Before every command")

**Purpose:** The tick measures elapsed time since the previous tick. A command that starts a countdown between two ticks must not have the time before the command subtracted from it. Today the first tick after an `unblock` subtracts up to one full tick interval of time that passed before the unblock existed. With the 2-second production tick, the unblock then finishes up to 2 seconds early.

**Sub-steps:**
- 1a. Before `engine.handle`, on the engine queue, read `ContinuousClock.now`. Call `engine.tick(elapsed:)` with the time since the last tick or command (clamped as in the tick), and set the "last tick" time to now. Apply whatever that tick finished, exactly as a timer tick would: save, then run the enforcement pass if something changed.
- 1b. The timer tick keeps measuring from that same "last tick" time. One clock variable is shared by commands and ticks, so no stretch of time is ever counted twice or skipped.

**Acceptance Criteria:**
- [ ] In sandbox mode with `--tick 1`, an `unblock` sent at a random point in the tick cycle never leaves the hosts file earlier than 2.0 seconds after the request was sent (2-second delay). Check this 10 times.

---

## Step 2: Move the watchdog's uninstall rule into SiteBlockCore

**Files:** `Sources/SiteBlockCore/Models.swift` (or a new `Sources/SiteBlockCore/UninstallRule.swift`), `Sources/siteblockd/LaunchdGuard.swift`, `Sources/siteblockd/Uninstaller.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § LaunchdGuard and Watchdog

**Sub-steps:**
- 2a. Make `PersistedState.hasFinishedUninstall` public in `SiteBlockCore`. It is true only when `uninstalling` is true and `pendingUninstall` exists and is finished.
- 2b. Add `public enum UninstallRule` with `static func watchdogShouldStandDown(stateFileData: Data?) -> Bool`. It decodes the data with `JSONCoding`. It returns `hasFinishedUninstall` for a state that decodes, and `false` for `nil` data or data that does not decode.
- 2c. The watchdog and the daemon both call these, so no copy of the rule is left in `siteblockd`.

---

## Step 3: Extract the connection limiter

**Files:** new `Sources/SiteBlockCore/ConnectionLimiter.swift`, `Sources/siteblockd/SocketServer.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SocketServer step 4

**Sub-steps:**
- 3a. `public final class ConnectionLimiter` with `init(perUserLimit: Int = 4, total: Int = 32, rootReserved: Int = 4)`, `func admit(uid: uid_t) -> Bool`, and `func release(uid: uid_t)`. It is thread-safe, using an `NSLock`.
- 3b. The rules:
  - Root (uid 0) is admitted while fewer than `total` connections are open.
  - A non-root user is admitted while it holds fewer than `perUserLimit` connections and all non-root users together hold fewer than `total - rootReserved`.
  - `release` never lets a count go below zero.
  - The peer-credential failure ID, `UInt32.max`, is treated as an ordinary non-root user.
- 3c. `SocketServer` uses it, and its behavior is unchanged.

---

## Step 4: Pin two boundaries in code and design

**Files:** `Sources/siteblockd/SocketServer.swift`, `Sources/SiteBlockCore/StateStore.swift` (check only)
**Reference:** [01-overview-and-data.md](../01-overview-and-data.md) § Wire Protocol; [02-core-components.md](../02-core-components.md) § StateStore

**Sub-steps:**
- 4a. A request whose line, not counting the newline, is 65,536 bytes or shorter is accepted. One byte more is rejected with `badRequest`. Make the code match this exactly.
- 4b. Check that a `state.json` missing any required field (for example `{}` or `{"version":1}`) fails to decode and is treated as corrupt. That is the current behavior, so this is only a confirmation. Do not change it.

---

## Step 5: Verify

- [ ] `swift build` gives no warnings.
- [ ] `scripts/test.sh` passes in full. Any test that fails because of Step 1 is a test that depended on the early finish; report it rather than editing it.

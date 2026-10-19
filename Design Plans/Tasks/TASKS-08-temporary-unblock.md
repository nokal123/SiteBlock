# Tasks: Temporary Unblock
> **Corresponds to:** [01-overview-and-data.md](../01-overview-and-data.md) § Data Model, § Wire Protocol, § Fixed Policy Values; [02-core-components.md](../02-core-components.md) § Models and Protocol Types, § Engine, § StateStore, § Formatting, § TemporaryUnblockOptions; [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime, § siteblock CLI, § SiteBlock.app Menu Bar App, § TabWatcher; [05-testing-and-operations.md](../05-testing-and-operations.md) § Unit Tests, § Integration Tests

**Scope:** Add the temporary unblock. A person can open a blocked site or path rule for a chosen window of time, after a start wait that is never shorter than the unblock delay, and the site is blocked again on its own when the window ends. This covers the data model and protocol types, the Engine commands, the tick rule and the lists the daemon enforces, the daemon runtime and its log lines, the CLI, the menu bar app's choice, form and rows, the tab watcher's rule filter, and the tests.

**Prerequisites:** [TASKS-07-tab-watcher.md](TASKS-07-tab-watcher.md) complete. Sites, path rules, `pendingUnblock`, `cancelUnblock`, the tick and the enforcement passes already work end to end. `scripts/test.sh` passes.

**Code conventions:** same as TASKS-02. Every type and method has a `///` comment above it saying what it does in plain English, and the non-obvious decisions are commented where they are made. Update a comment in the same edit whenever the behavior it describes changes.

---

## Step 1: Models and protocol types

**Files:** `Sources/SiteBlockCore/Models.swift`, `Sources/SiteBlockCore/Protocol.swift`
**Reference:** [01-overview-and-data.md](../01-overview-and-data.md) § Data Model (TemporaryUnblock), § Wire Protocol; [02-core-components.md](../02-core-components.md) § Models and Protocol Types
**Purpose:** Define what is stored for a temporary unblock and what is sent over the socket.

**Sub-steps:**
- 1a. `public struct TemporaryUnblock: Codable, Equatable, Sendable` with `startsIn: Countdown`, `window: Countdown`, and two computed properties: `isOpen` (`startsIn.remainingSeconds <= 0 && window.remainingSeconds > 0`) and `isFinished` (both countdowns `<= 0`).
- 1b. Add `temporaryUnblock: TemporaryUnblock?` to `BlockedSite` and `BlockedPath`, defaulting to `nil` in their initializers. The key is optional in the file: a `state.json` without it must decode with `nil`. A missing key that failed to decode would make the file count as corrupt, and the block list would be discarded.
- 1c. `Request` gets `startSeconds: Int?`.
- 1d. The `Command` enum gets `temporaryUnblock` and `temporaryUnblockPath`. The `ErrorCode` enum gets `invalidDuration` and `alreadyPending`.
- 1e. `public struct TemporaryUnblockStatus: Codable, Equatable, Sendable` with `opensInSeconds: Int?`, `secondsRemaining: Int`, `windowSeconds: Int` and `isOpen: Bool`. `BlockedSiteStatus` and `BlockedPathStatus` get `temporaryUnblock: TemporaryUnblockStatus?`, decoded as `nil` when the key is missing.

**Dependencies:** none.

**Acceptance Criteria:**
- [ ] A `state.json` text with no `temporaryUnblock` key decodes, and a state holding a waiting and an open temporary unblock survives an encode and decode with the same values.
- [ ] A status reply without `temporaryUnblock` decodes with `nil` on both sites and path rules.
- [ ] `swift build` gives no warnings.

---

## Step 2: Engine commands

**File:** `Sources/SiteBlockCore/Engine.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § Engine (Policy, Temporary unblock commands, Command rules, Status of a temporary unblock); [01-overview-and-data.md](../01-overview-and-data.md) § Wire Protocol (Commands)
**Purpose:** Accept, refuse, clear and report temporary unblocks, with every check in the documented order.

**Sub-steps:**
- 2a. Add `minTemporarySeconds`, `maxTemporarySeconds` and `maxTemporaryStartSeconds` to `Policy`. `Policy.production` holds 300, 14400 and 604800. `Policy.fastForTests` has `minTemporarySeconds` 1 and the production values for the other two.
- 2b. Add `temporaryUnblock` and `temporaryUnblockPath`, with the eight checks in the order given in [02-core-components.md](../02-core-components.md) § Engine. Sites and rules share one implementation. Every check before the password check returns before the lockout and password rule runs, so a refused request never counts a wrong password.
- 2c. `cancelUnblock` and `cancelUnblockPath` clear a `pendingUnblock` first. When there is none, they clear a `temporaryUnblock` with the waiting message or the open message. When there is neither, they fail `nothingPending`.
- 2d. `add` and `addPath` clear a `temporaryUnblock` (waiting or open) on an entry that is already blocked, with no password and the same sentence the cancel commands use for that case.
- 2e. `unblock` and `unblockPath` fail `alreadyPending` when the entry has a `temporaryUnblock`, before the password check.
- 2f. `snapshot(hostsFileHealthy:)` fills `temporaryUnblock` on each site and path rule status as described under "Status of a temporary unblock".
- 2g. `var onTemporaryUnblockEvent: ((String) -> Void)?` is called with one sentence when a temporary unblock is approved, cancelled while waiting, or ended early (here), and when one opens or ends (Step 3). The sentences are the ones listed in [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime.

**Dependencies:** Step 1.

**Acceptance Criteria:**
- [ ] A request with a missing field, or a window or start wait out of range, leaves `failedAttempts` at 0, even with a wrong password.
- [ ] No sequence of commands leaves a site or rule with both a `pendingUnblock` and a `temporaryUnblock`.
- [ ] `swift build` gives no warnings.

---

## Step 3: Tick and enforced lists

**File:** `Sources/SiteBlockCore/Engine.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § Engine (Temporary unblock tick rule, `blockedHosts`, Browser block list)
**Purpose:** Open and end temporary unblocks as time passes, and keep the lists the daemon writes in step with them.

**Sub-steps:**
- 3a. In `tick(elapsed:)`, advance each site's and rule's `temporaryUnblock`: `startsIn` first, then the part of `elapsed` it did not use goes to `window`. When `startsIn` was already 0, all of `elapsed` goes to `window`. Neither goes below 0.
- 3b. Return `true` on the tick where a temporary unblock opens and on the tick where it finishes, and call `onTemporaryUnblockEvent` once for each. Set a finished one to `nil`; the site or rule stays on the list. A gap that covers both finishes it in that tick, with the ended sentence only.
- 3c. `blockedHosts` leaves out the hosts of every site whose temporary unblock is open. A host that another blocked site, one that is not open, lists stays. A waiting temporary unblock leaves the site fully blocked.
- 3d. `browserBlockEntries`, and the `browserBlockLists` it is built from, take the sites that are not open and the path rules that are not open. A path rule on a site whose whole site is open is included.
- 3e. `hostsToWrite` keeps adding the Private Relay and DNS-over-HTTPS names to `blockedHosts` while the adult content filter is active.

**Dependencies:** Steps 1 and 2.

**Acceptance Criteria:**
- [ ] While a temporary unblock waits, `blockedHosts` and `browserBlockEntries` hold the site. While it is open they leave it out. After it ends they hold it again.
- [ ] A tick whose `elapsed` is longer than the start wait plus the window removes the temporary unblock in that one tick and returns `true`.
- [ ] `swift build` gives no warnings.

---

## Step 4: Daemon runtime and log lines

**File:** `Sources/siteblockd/DaemonRuntime.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime (Temporary unblocks, Logging, Temporary unblock log lines)
**Purpose:** Make the hosts file and the browser policy files follow a temporary unblock in the same tick that opens or ends it, save it, and log it.

**Sub-steps:**
- 4a. Confirm that the enforcement pass runs right after `engine.tick` in the timer tick, and that the catch-up before a command saves and enforces when `engine.tick` returns `true`. A tick that opens or ends a temporary unblock must rewrite the hosts file and the browser policy files in that same tick, and the rewrite must count as a change made on purpose, so it is not logged as tampering.
- 4b. Make the "any countdown running" check count a site or rule that has a `temporaryUnblock`, so the state is saved at least every `policy.saveIntervalSeconds` (15 seconds in production) while one is waiting or open.
- 4c. Set `engine.onTemporaryUnblockEvent` so that each sentence is written to the log. The five lines are in [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime: approved (site or rule, start wait and window), opened, ended, cancelled while waiting, and ended early. Each opening and ending is logged once, whether it happened in a timer tick or in the catch-up before a command.
- 4d. Update the logging comments to say that passwords are never logged and that a domain or rule appears only in the temporary unblock lines.
- 4e. In the request handler that checks site names and rule text on the connection's thread, include `temporaryUnblock` (site name) and `temporaryUnblockPath` (rule text). A request that is missing its password or window skips the check, so the engine answers `badRequest` first.

**Dependencies:** Steps 2 and 3.

**Acceptance Criteria:**
- [ ] In a sandbox run with `--policy-fast`, the site's lines leave the sandbox hosts file in the tick that opens the temporary unblock and return in the tick that ends it.
- [ ] The log holds one approved line, one opened line and one ended line for a full run, and no password.
- [ ] Restarting the daemon in the middle of a start wait or a window continues from the last saved remaining times.

---

## Step 5: CLI

**File:** `Sources/siteblock/main.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § siteblock CLI, § Path rules in the app and CLI
**Purpose:** Schedule, cancel and show temporary unblocks from Terminal.

**Sub-steps:**
- 5a. Add `--for <duration>` and `--in <duration>` to `unblock`. With `--for`, send `temporaryUnblock` for a site and `temporaryUnblockPath` for text that has a path, with `seconds` set from `--for` and `startSeconds` set from `--in` when it is given. Without `--for`, run the permanent unblock.
- 5b. Read both durations with `Formatting.parseDuration`. A value it rejects is a usage error (exit code 64) and is never sent. `--in` without `--for` is also a usage error. Check every option before asking for the password.
- 5c. Ask for the password after the options are checked, the same way `unblock` does.
- 5d. `cancel` sends `cancelUnblock` for a site and `cancelUnblockPath` for a rule, prints the daemon's message for a temporary unblock, and exits `0`.
- 5e. Add `Formatting.compact` to `SiteBlockCore` (see [02-core-components.md](../02-core-components.md) § Formatting). `status` uses it to print `opens in 42m, for 1h` under a site or rule while its temporary unblock waits, and `OPEN — blocks again in 37m` while it is open.
- 5f. Update the usage text.

**Dependencies:** Steps 2 and 4.

**Acceptance Criteria:**
- [ ] `siteblock unblock reddit.com --for 30m --in 1h` with the password on standard input schedules a temporary unblock, and `siteblock status` shows the waiting line.
- [ ] A `--for` value that is not a duration exits with code 64 and sends nothing to the daemon.
- [ ] `swift build` gives no warnings.

---

## Step 6: Menu bar app choice, form and rows

**Files:** `Sources/SiteBlockCore/TemporaryUnblockOptions.swift`, `Sources/SiteBlockApp/Views/TemporaryUnblockForm.swift`, `Sources/SiteBlockApp/Views/BlockedListView.swift`, `Sources/SiteBlockApp/StatusModel.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § TemporaryUnblockOptions; [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (Panel states: the blocked list, the temporary unblock form, the temporary unblock rows)
**Purpose:** Let a person schedule, see, cancel and end a temporary unblock from the panel.

**Sub-steps:**
- 6a. `public enum TemporaryUnblockOptions` in `SiteBlockCore` with `windowChoices`, `startChoices(delaySeconds:)`, and `label(forSeconds:)`, exactly as described in [02-core-components.md](../02-core-components.md) § TemporaryUnblockOptions. The form's menus come from here so they can be unit-tested without a window.
- 6b. In `StatusModel`, add async methods that send `temporaryUnblock` or `temporaryUnblockPath` with the window, start wait and password. "Keep blocked" and "Block now" use the cancel methods.
- 6c. A plain blocked row's "Unblock…" button opens a small choice inside the row: "For a while" first, then "For good", and a "Cancel" button. "For good" shows the password form with "Start countdown" and "Cancel".
- 6d. `TemporaryUnblockForm` is the "For a while" form: a menu picker "How long?" with nothing selected ("Choose…"); a menu picker "Opens in" with the unblock delay (labelled "(soonest)") and the longer choices, starting on the soonest; one gray line with the clock times, recalculated when either picker changes and once a minute; and a password field.
- 6e. "Schedule unblock" stays disabled until a window is chosen and a password is typed. It empties the password field when pressed, and the form closes only when the daemon accepts the request. "Cancel" closes the form.
- 6f. A waiting temporary unblock keeps the blocked row's red box and adds a live line "Opens in 42:10 for 1 hour — still blocked", and a "Keep blocked" button. An open one shows a green box, a live line "Unblocked — blocks again in 37:05", and a "Block now" button. Neither button asks for a password. A row with a pending permanent unblock shows the countdown and "Keep blocked" button described in [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SiteBlock.app Menu Bar App.
- 6g. Path-rule rows get the same choice, form and rows, and send `temporaryUnblockPath`.
- 6h. Keep the text short, and match the structure, styles and comment conventions of the existing views.

**Dependencies:** Steps 1 to 3.

**Acceptance Criteria:**
- [ ] Opening the form shows no window selected, and "Schedule unblock" is disabled until all three conditions hold.
- [ ] A scheduled temporary unblock shows the red waiting row with a clock icon, then the green open row when the start wait ends, then the plain gray blocked row when the window ends.
- [ ] "Keep blocked" and "Block now" return the row to the plain blocked state without asking for a password.
- [ ] `swift build -c release --product SiteBlockApp` succeeds with no warnings.

---

## Step 7: Tab watcher rule filter

**File:** `Sources/SiteBlockApp/StatusModel.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § TabWatcher, § SiteBlock.app Menu Bar App (StatusModel)
**Purpose:** Keep the tab watcher from reloading tabs on a part of a site that the browsers are not blocking.

**Sub-steps:**
- 7a. When `StatusModel` maps `snapshot.blockedPaths` to `WatchedPathRule` values for `TabWatcher.setRules`, leave out every rule whose `temporaryUnblock` is open.
- 7b. Keep rules whose temporary unblock is waiting, and keep rules on a site whose whole site is temporarily open, because the browsers still block both.
- 7c. When every rule is left out, the watcher receives an empty list and sends no Apple Events.

**Dependencies:** Steps 1 and 2.

**Acceptance Criteria:**
- [ ] With a path rule whose temporary unblock is open, a Chrome tab on that part of the site is not reloaded, and the watcher sends no Apple Events when it is the only rule.
- [ ] After the window ends, the rule is passed to the watcher again on the next snapshot.

---

## Step 8: Tests

**Files:** `Tests/SiteBlockCoreTests/`, `Tests/IntegrationTests/`
**Reference:** [05-testing-and-operations.md](../05-testing-and-operations.md) § Unit Tests (EngineTemporaryUnblockTests, TemporaryUnblockPersistenceTests, TemporaryUnblockOptionsTests, FormattingTests), § Integration Tests

**Sub-steps:**
- 8a. Run the `qa-engineer` agent to write the unit tests listed under EngineTemporaryUnblockTests, TemporaryUnblockPersistenceTests, TemporaryUnblockOptionsTests and the `compact` cases of FormattingTests. Its expected values come from the design sections named above, not from the implementation. Include the adversarial cases: the boundary values of the window and the start wait, a gap that covers the whole start wait and window, a host shared with another blocked site, and a path rule on a site whose whole site is open.
- 8b. Run the `qa-engineer` agent to write the integration tests listed in the temporary unblock bullets: the full cycle under `--policy-fast`, a restart in the middle, cancelling and ending early, and the CLI flow. Change the existing log test so it matches the logging rule in [05-testing-and-operations.md](../05-testing-and-operations.md) § Integration Tests.
- 8c. Run the `test-rigor-auditor` agent in a fresh invocation on the new test files and the same design sections, passing no reasoning from the author. Send its findings back to a new `qa-engineer` invocation until the auditor is satisfied.

**Dependencies:** Steps 1 to 6.

**Acceptance Criteria:**
- [ ] `scripts/test.sh` passes in full.
- [ ] The auditor reports no confirmation tests and no uncovered case from the lists in [05-testing-and-operations.md](../05-testing-and-operations.md).

---

## Step 9: Verify

- [ ] `swift build` and `swift build -c release --product SiteBlockApp` give no warnings.
- [ ] `scripts/test.sh` passes in full.
- [ ] `scripts/build.sh` produces `build/SiteBlock.app`, and `codesign --verify build/SiteBlock.app` succeeds.
- [ ] Against a sandbox daemon started with `--policy-fast`, the built app schedules a temporary unblock from "For a while", shows the waiting row and then the open row, and "Block now" ends it with no password.

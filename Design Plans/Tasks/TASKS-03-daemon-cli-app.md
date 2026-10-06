# Tasks: siteblockd, siteblock CLI and SiteBlock.app
> **Corresponds to:** [03-daemon-cli-app.md](../03-daemon-cli-app.md)

**Scope:** Implement the three executables on top of `SiteBlockCore`.

**Prerequisites:** [TASKS-02-core-library.md](TASKS-02-core-library.md) complete and building.

**Code conventions:** same as TASKS-02 (a `///` comment on every type and method; comment non-obvious decisions).

---

## Step 1: siteblockd entry point and plists

**Files:** `Sources/siteblockd/main.swift`, `Sources/siteblockd/LaunchdPlists.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § siteblockd Entry Point; [04-infrastructure.md](../04-infrastructure.md) § Launchd Jobs

**Sub-steps:**
- 1a. Hand-written flag parsing (no ArgumentParser dependency). Enforce that `--tick` and `--policy-fast` need `--sandbox`, exit 64 otherwise.
- 1b. `LaunchdPlists.xml(for: Job, paths: Paths) -> String` producing the plist XML for daemon, watchdog and app agent exactly as listed in the design. Escape `&`, `<`, `>` in paths.
- 1c. `--print-plist` prints and exits 0.
- 1d. Ignore `SIGPIPE` process-wide (`signal(SIGPIPE, SIG_IGN)`).

**Acceptance Criteria:**
- [ ] `siteblockd --print-plist daemon | plutil -lint -` reports OK; same for `watchdog` and `app`.
- [ ] `siteblockd --tick 1 --daemon` exits 64.

---

## Step 2: SocketServer

**File:** `Sources/siteblockd/SocketServer.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SocketServer

**Sub-steps:**
- 2a. `final class SocketServer` with `init(path: String, handler: @escaping (Request, uid_t) -> Response)`, `start() throws`, `stop()`.
- 2b. Accept loop on a dedicated `Thread`. Handle each connection on a concurrent `DispatchQueue` so a slow client cannot block others; the handler itself hops to the engine queue (done in the runtime).
- 2c. Peer credentials with `LOCAL_PEERCRED` and `xucred`, falling back to `UInt32.max`.
- 2d. 64 KB limit, 5-second timeouts, `badRequest` for invalid JSON.

**Acceptance Criteria:**
- [ ] A slow client that sends nothing does not stop other clients from being served.

---

## Step 3: HostsEnforcer

**File:** `Sources/siteblockd/HostsEnforcer.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § HostsEnforcer

**Sub-steps:**
- 3a. `final class HostsEnforcer` with `init(paths: Paths, log: Logger)` and `enforce(blockedHosts:causedByCommand:) -> Bool`.
- 3b. Atomic write via temp file + `rename`. In production only, `chown(0, 0)` the temp file and flush the DNS cache by running the two commands with `Process` and a 5-second wait.

---

## Step 4: LaunchdGuard, watchdog loop, Uninstaller

**Files:** `Sources/siteblockd/LaunchdGuard.swift`, `Sources/siteblockd/Uninstaller.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § LaunchdGuard and Watchdog, § Uninstaller

**Sub-steps:**
- 4a. A small `runProcess(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32` helper (in a `ProcessRunner.swift` file) used by everything that runs commands.
- 4b. `LaunchdGuard.isLoaded`, `ensureLoaded` as designed; it writes the plist, fixes ownership, restores the program from the backup path, and bootstraps.
- 4c. `runWatchdog(paths:)` loop: every 5 s, decode `state.json` (ignore errors), stand down when `uninstalling` is true or the install folder is gone, else `ensureLoaded(.daemon)`.
- 4d. `Uninstaller.run(paths:enforcer:)` with the production steps, and the sandbox variant that removes the sandbox socket and calls `exit(0)`. Detached shell via `posix_spawn` with `POSIX_SPAWN_SETSID`.

---

## Step 5: DaemonRuntime

**File:** `Sources/siteblockd/DaemonRuntime.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime

**Sub-steps:**
- 5a. Startup steps 1–7 in order.
- 5b. Serial engine queue; a `DispatchSourceTimer` for the tick on that queue.
- 5c. Command path: `engine.handle` → save → enforce → set hosts health → re-snapshot so the response's `hostsFileHealthy` is current.
- 5d. `SIGTERM` handled with a `DispatchSourceSignal` (after `signal(SIGTERM, SIG_IGN)`): save and `exit(0)`.
- 5e. A tiny `Logger` struct that writes `ISO8601 timestamp + message` lines to standard error.

**Acceptance Criteria:**
- [ ] `siteblockd --daemon --sandbox /tmp/sbx --tick 0.2 --policy-fast` starts, creates `/tmp/sbx/siteblock.sock`, and answers `status`.

---

## Step 6: siteblock CLI

**File:** `Sources/siteblock/main.swift` (split into `Commands.swift` and `PasswordPrompt.swift` if long)
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § siteblock CLI

**Sub-steps:**
- 6a. Every subcommand in the usage block, the exit codes, `readpassphrase` when stdin is a TTY (`isatty(0)`), else read a line from stdin. `setup` and `passwd` ask for the new password twice when interactive; when not interactive they read one line for each prompt in order.
- 6b. `status` output format: first line `SiteBlock 1.0.0 — unblock delay: 30 minutes`, then `Blocked sites (N):` with lines `  reddit.com (24 hosts)` or `  reddit.com (24 hosts) — unblocks in 29:41`, then any banners. `No sites blocked.` when empty. `Password not set — run 'siteblock setup'.` when not set up.
- 6c. Durations parsed with `Formatting.parseDuration`.

---

## Step 7: SiteBlock.app

**Files:** `Sources/SiteBlockApp/SiteBlockApp.swift`, `StatusModel.swift`, `Views/*.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SiteBlock.app Menu Bar App

**Sub-steps:**
- 7a. `@main struct SiteBlockApp: App` with `MenuBarExtra { MainPanel(model:) } label: { Image(systemName: ...) }.menuBarExtraStyle(.window)`. Call `NSApplication.shared.setActivationPolicy(.accessory)` in an `NSApplicationDelegateAdaptor` so it runs with no Dock icon even when launched as a bare executable.
- 7b. `StatusModel` (`@MainActor final class: ObservableObject`) with published `snapshot`, `connection` (`.connecting`, `.connected`, `.notRunning(String)`), `lastError`, `lastMessage`. Run `DaemonClient.send` on a background `DispatchQueue` and publish results on the main queue. Polling timer as designed; `panelVisible` toggled from `onAppear`/`onDisappear`.
- 7c. Views for every state in the design. Live countdowns are computed from the last snapshot plus local elapsed time since it arrived, so the clock ticks smoothly between polls.
- 7d. Clear password fields after every submit, success or failure.

**Acceptance Criteria:**
- [ ] `swift build -c release --product SiteBlockApp` succeeds.
- [ ] Launched with `SITEBLOCK_SOCKET` pointing at a sandbox daemon, the panel shows the sandbox's blocked sites.

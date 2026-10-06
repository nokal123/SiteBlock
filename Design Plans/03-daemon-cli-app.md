# Daemon, Watchdog, CLI and Menu Bar App
> Part of the SiteBlock Design Plans
> See also: [02-core-components.md](02-core-components.md), [04-infrastructure.md](04-infrastructure.md)

## Table of Contents
1. [siteblockd Entry Point](#1-siteblockd-entry-point-sourcessiteblockdmainswift)
2. [Daemon Runtime](#2-daemonruntime-sourcessiteblockddaemonruntimeswift)
3. [SocketServer](#3-socketserver-sourcessiteblockdsocketserverswift)
4. [HostsEnforcer](#4-hostsenforcer-sourcessiteblockdhostsenforcerswift)
5. [LaunchdGuard and Watchdog](#5-launchdguard-and-watchdog-sourcessiteblockdlaunchdguardswift)
6. [Uninstaller](#6-uninstaller-sourcessiteblockduninstallerswift)
7. [siteblock CLI](#7-siteblock-cli-sourcessiteblockmainswift)
8. [SiteBlock.app Menu Bar App](#8-siteblockapp-menu-bar-app-sourcessiteblockapp)

---

### 1. siteblockd Entry Point (`Sources/siteblockd/main.swift`)

**Purpose:** Reads command-line flags and starts either the daemon or the watchdog.

**Flags:**
- `--daemon` — run the main service.
- `--watchdog` — run the watchdog loop.
- `--sandbox <dir>` — use `Paths.sandbox(root: dir)` instead of the real system paths, and turn off everything that touches the real system: no DNS cache flush, no `launchctl` calls, no watchdog checks. Used by integration tests.
- `--tick <seconds>` — enforcement interval, default `2`. Only accepted together with `--sandbox`.
- `--policy-fast` — use `Policy.fastForTests`: delay floor 1 second, recovery 3 seconds, lockout 2 seconds, PBKDF2 iterations 1000. Only accepted together with `--sandbox`, so the installed daemon can never be started with short waits.
- `--version` — print the version and exit.
- `--print-plist <daemon|watchdog|app>` — print that job's launchd plist XML and exit. The install script uses it so the plist text has one source.

Exactly one of `--daemon`, `--watchdog`, `--version` or `--print-plist` is required. Unknown flags print usage to standard error and exit with code 64 (the Unix code for "command used incorrectly").

---

### 2. DaemonRuntime (`Sources/siteblockd/DaemonRuntime.swift`)

**Purpose:** Wires the `Engine` to the outside world: the socket, the hosts file, the state file, the clock and the watchdog.

**Startup:**
1. Create the state folder with mode `0700` if missing.
2. Load state with `StateStore`. If there is none, start from a fresh `PersistedState` with the policy's default delay.
3. If the loaded state has `uninstalling == true`, finish the uninstall (see § Uninstaller) and exit. This covers a crash in the middle of an uninstall.
4. Create the `Engine`, set `onUninstall`.
5. Run one enforcement pass immediately so blocks apply at boot before any client connects.
6. Start the `SocketServer`.
7. Start the tick timer.

**Concurrency:** All engine access happens on one serial `DispatchQueue` named `siteblockd.engine`. The socket server reads requests on its own queue, then hops onto the engine queue to handle each one. This means a command and a tick can never run at the same time.

**Tick (every `tick` seconds, on the engine queue):**
1. Measure elapsed time since the last tick with `ContinuousClock.now`, clamped to the range 0 to 604800 seconds (7 days). `ContinuousClock` keeps counting while the Mac sleeps and cannot be changed by the user, so time spent asleep counts toward a countdown.
2. Call `engine.tick(elapsed:)`.
3. Run an enforcement pass with `HostsEnforcer`.
4. Save the state if the tick reported a change, or if any countdown is running and 15 seconds have passed since the last save.
5. Ask the `StateStore` whether the primary and backup state files still hold exactly the bytes it last wrote. If either file is missing or different, save again from the in-memory state and log "state file repaired". While the daemon runs, its in-memory state is the source of truth, so deleting or editing `state.json` by hand is undone within one tick.
6. In production mode, every 5 seconds, call `LaunchdGuard.ensureLoaded(.watchdog)`.

**After every command:** save the state, then run an enforcement pass, so a newly added site is blocked before the response is sent.

**Logging:** Log lines go to standard error with an ISO 8601 timestamp; launchd sends them to the log file named in the plist. Every command is logged by name and outcome. Passwords are never logged.

**Signals:** `SIGTERM` (the polite stop signal launchd sends) saves state and exits with code 0. launchd restarts the daemon because of `KeepAlive`.

---

### 3. SocketServer (`Sources/siteblockd/SocketServer.swift`)

**Purpose:** Accepts connections on the Unix socket and turns each into one `Request` and one `Response`.

**Behavior:**
1. Remove any stale socket file at the path, create an `AF_UNIX` `SOCK_STREAM` socket, `bind`, then `chmod` the path to `0666` so the logged-in user's app can connect, then `listen` with a backlog of 16.
2. Accept on a dedicated thread. For each accepted connection, set `SO_RCVTIMEO` and `SO_SNDTIMEO` to 5 seconds and `SO_NOSIGPIPE` so a vanished client cannot crash the daemon.
3. Read the peer user ID with `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &xucred)` and take `cr_uid`. If the call fails, use `UInt32.max` (an ID that is never root), so a failure can never grant root-only commands.
4. Read bytes until `\n`, end of stream, or 64 KB. Over the limit returns `badRequest`. Invalid JSON returns `badRequest` with the decoding message.
5. Hand the request and peer uid to the handler closure and write back the encoded response plus `\n`, then close.

---

### 4. HostsEnforcer (`Sources/siteblockd/HostsEnforcer.swift`)

**Purpose:** Makes the real hosts file match the engine's block list, and reports whether it does.

**Key Methods:**
- `func enforce(blockedHosts: [String]) -> Bool` — returns `true` when the file is correct after the pass.

**Steps:**
1. Read the hosts file as UTF-8. If it does not exist, treat it as empty. If it cannot be read, log and return `false`.
2. Compute `HostsFileEditor.render`. If the result equals the current text, return `true` without writing.
3. Otherwise write the new text to `<hosts>.siteblock.tmp` in the same folder, set mode `0644` and (in production) owner `root:wheel`, then `rename` over the hosts file.
4. In production, flush the name cache: run `/usr/bin/dscacheutil -flushcache` and `/usr/bin/killall -HUP mDNSResponder`, waiting at most 5 seconds for each.
5. Log "hosts file repaired" when the change was not caused by a command, so tampering shows up in the log.

---

### 5. LaunchdGuard and Watchdog (`Sources/siteblockd/LaunchdGuard.swift`)

**Purpose:** Keeps both background jobs loaded. The daemon guards the watchdog and the watchdog guards the daemon.

**Key Methods:**
- `static func isLoaded(_ job: Job) -> Bool` — runs `/bin/launchctl print system/<label>` and returns `true` on exit code 0.
- `static func ensureLoaded(_ job: Job)` — when the job is not loaded: write its plist from `LaunchdPlists.xml(for:)` if the file is missing or different, set the plist to `root:wheel` mode `0644`, make sure the program exists (copy from the backup path if missing, mode `0755`), then run `/bin/launchctl bootstrap system <plist>`. It logs what it repaired.
- `enum Job { case daemon, watchdog }` with each job's label and plist path.

**Watchdog loop (`siteblockd --watchdog`):** every 5 seconds, read `state.json`. When the file's `uninstalling` is `true` or the install folder is gone, do nothing (the uninstall is in progress). Otherwise call `ensureLoaded(.daemon)`. The watchdog never touches the hosts file or the socket.

**Plist text** is generated in code (`Sources/siteblockd/LaunchdPlists.swift`) rather than read from disk, so a deleted plist can always be recreated. Both plists set `RunAtLoad` and `KeepAlive` to `true`, `ProcessType` to `Interactive`, and `StandardErrorPath` to the log file. See [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs.

---

### 6. Uninstaller (`Sources/siteblockd/Uninstaller.swift`)

**Purpose:** Removes SiteBlock from the Mac when the uninstall countdown finishes.

**Steps, in order:**
1. Save the state with `uninstalling = true`, so the watchdog stops guarding.
2. Remove the managed section from the hosts file (enforce with an empty block list) and flush the name cache.
3. Delete the backup program, `/usr/local/bin/siteblock`, the app LaunchAgent plist, both LaunchDaemon plists, and the socket file.
4. Start a detached `/bin/sh` that waits 1 second, then runs `launchctl bootout system/com.nokal.siteblock.watchdog`, then `launchctl bootout system/com.nokal.siteblock.daemon`, then deletes `/Library/Application Support/SiteBlock` and `/Applications/SiteBlock.app`. The daemon is stopped by the last `bootout`, so the shell must be detached (started with `setsid` through `posix_spawn` with `POSIX_SPAWN_SETSID`) to outlive it.

In sandbox mode, steps 3 and 4 are replaced by deleting the sandbox's own plist and socket files and exiting with code 0.

---

### 7. siteblock CLI (`Sources/siteblock/main.swift`)

**Purpose:** A Terminal interface for every command, mainly for scripting, recovery and checking status without the app.

**Usage:**
```
siteblock status
siteblock setup                     # asks for a new password twice
siteblock add <site> [<site> ...]
siteblock unblock <site>            # asks for the password
siteblock cancel <site>             # cancel a pending unblock
siteblock delay                     # show the current delay
siteblock delay <duration>          # e.g. 45m, 2h; asks for the password
siteblock delay --cancel
siteblock passwd                    # asks for old and new password
siteblock uninstall                 # asks for the password
siteblock uninstall --cancel
sudo siteblock recover              # start the 48-hour password reset
siteblock recover --cancel
siteblock version
```

**Behavior:**
- Passwords are read with `readpassphrase` (a C function that turns off echo on the terminal so the password does not show while typing). When standard input is not a terminal, the password is read from the first line of standard input, which lets tests pipe it in.
- `status` prints the delay, then each blocked site with its host count and any countdown, then any pending delay change, uninstall, recovery or lockout.
- Exit codes: `0` success, `1` the daemon refused the command (the error sentence is printed to standard error), `2` the daemon is not running, `64` usage error.
- `add` with several sites sends one request per site and keeps going after a failure, then exits `1` if any failed.

---

### 8. SiteBlock.app Menu Bar App (`Sources/SiteBlockApp/`)

**Purpose:** The everyday interface: a shield icon in the menu bar that opens a panel to add, view and unblock sites.

**Files:**
- `SiteBlockApp.swift` — the `@main` `App` with one `MenuBarExtra` using `.menuBarExtraStyle(.window)` (a panel that drops down from the icon). The icon is the SF Symbol (one of Apple's built-in icons) `shield.lefthalf.filled`, or `shield.slash` when the daemon cannot be reached.
- `StatusModel.swift` — an `ObservableObject` that holds the latest `StatusSnapshot`, the connection state and the last error. It polls `status` once per second while the panel is open and every 30 seconds otherwise, on a background queue, and publishes on the main queue. It exposes one async method per command.
- `Views/MainPanel.swift` — the panel layout, 360 points wide.
- `Views/SetupView.swift`, `Views/BlockedListView.swift`, `Views/SettingsView.swift`.

**Panel states:**
1. **Not running:** "The SiteBlock service isn't running." and the Terminal command to reinstall.
2. **Not set up:** two password fields (new and confirm) and a "Set password" button. Shows the minimum length rule and a warning that the password cannot be shown again.
3. **Normal:**
   - A text field "Add a site (e.g. reddit.com)" and a "Block" button. Enter also submits. Errors appear in red under the field.
   - The blocked list. Each row shows the domain, a disclosure arrow that lists the expanded host names, and either an "Unblock…" button or, when pending, a live countdown such as "Unblocks in 29:41" with a "Keep blocked" button that cancels.
   - Pressing "Unblock…" replaces the row's button with a password field and "Start countdown" and "Cancel" buttons.
   - A footer with "Settings" and "Quit".
   - Banners at the top for a pending delay change, uninstall, recovery or lockout, each with its countdown and a cancel button where cancelling is allowed.
4. **Settings:** current delay with a picker of 5 minutes, 15 minutes, 30 minutes, 1 hour, 2 hours, 6 hours, 12 hours, 24 hours and 7 days plus a password field; a change-password form; and an "Uninstall SiteBlock…" button that asks for the password and explains that the uninstall waits for the current delay.

**Behavioral notes:** The app holds no state of its own beyond what is on screen; the daemon is always the source of truth. Quitting the app does not stop any blocking. The app is launched at login by a LaunchAgent (see [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs), and it sets `LSUIElement` so it has no Dock icon.

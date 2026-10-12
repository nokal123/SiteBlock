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
9. [ChromePolicyEnforcer](#9-chromepolicyenforcer-sourcessiteblockdchromepolicyenforcerswift)
10. [AppGuard](#10-appguard-sourcessiteblockdappguardswift)
11. [DNSEnforcer](#11-dnsenforcer-sourcessiteblockddnsenforcerswift)
12. [Adult filter in the app and CLI](#12-adult-filter-in-the-app-and-cli)
13. [BrowserPolicyEnforcer](#13-browserpolicyenforcer-sourcessiteblockdbrowserpolicyenforcerswift)
14. [Path rules in the app and CLI](#14-path-rules-in-the-app-and-cli)
15. [TabWatcher](#15-tabwatcher-sourcessiteblockapptabwatcherswift)
16. [ChromiumTabs](#16-chromiumtabs-sourcessiteblockappchromiumtabsswift)

---

### 1. siteblockd Entry Point (`Sources/siteblockd/main.swift`)

**Purpose:** Reads command-line flags and starts either the daemon or the watchdog.

**Flags:**
- `--daemon` — run the main service.
- `--watchdog` — run the watchdog loop.
- `--sandbox <dir>` — use `Paths.sandbox(root: dir)` instead of the real system paths, and turn off everything that touches the real system: no DNS cache flush, no `launchctl` calls, no watchdog checks. Used by integration tests. Refused with exit code 64 when the process runs as root, so `sudo siteblockd --daemon --sandbox /etc` cannot start a second daemon that fights the real one over `/etc/hosts`.
- `--tick <seconds>` — enforcement interval, default `2`. Only accepted together with `--sandbox`.
- `--policy-fast` — use `Policy.fastForTests`: default unblock delay 2 seconds, delay floor 1 second, recovery 3 seconds, lockout 2 seconds, PBKDF2 iterations 1000, at most 20 sites. Only accepted together with `--sandbox`, so the installed daemon can never be started with short waits.
- `--version` — print the version and exit.
- `--print-plist <daemon|watchdog|app>` — print that job's launchd plist XML and exit. The install script uses it so the plist text has one source.

Exactly one of `--daemon`, `--watchdog`, `--version` or `--print-plist` is required. Unknown flags print usage to standard error and exit with code 64 (the Unix code for "command used incorrectly").

---

### 2. DaemonRuntime (`Sources/siteblockd/DaemonRuntime.swift`)

**Purpose:** Wires the `Engine` to the outside world: the socket, the hosts file, the state file, the clock and the watchdog.

**Startup:**
1. Create the state folder with mode `0700` if missing.
2. Load state with `StateStore`. If there is none, start from a fresh `PersistedState` with the policy's default delay.
3. If the loaded state has `uninstalling == true` and `pendingUninstall` is a finished countdown, finish the uninstall (see § Uninstaller) and exit. This covers a crash in the middle of an uninstall. If `uninstalling` is `true` without a finished `pendingUninstall`, someone set the flag by hand to skip the password and the wait, so the daemon sets it back to `false`, logs it, saves, and runs normally. The watchdog applies the same rule before it stands down.
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
6. Every 5 seconds, on a separate guard timer: in production call `LaunchdGuard.ensureLoaded(.watchdog)`, then (in production and sandbox) run `AppGuard` (see § AppGuard). The timer is cancelled when an uninstall begins.

**Before every command:** on the engine queue, advance every countdown by the time since the last tick or command, apply anything that finished (saving and enforcing as a tick would), and record now as the last tick time. Commands and ticks share this one clock reading, so a countdown started by a command is never charged for time that passed before it existed, and no stretch of time is counted twice.

**After every command:** save the state, then run an enforcement pass, so a newly added site is blocked before the response is sent.

**During an uninstall:** once the uninstall has begun (including when the catch-up before a command is what finished its countdown), `status` is answered from memory with no save and no enforcement pass, so a status poll from the app can never write blocks back into the hosts file the uninstaller just cleaned. Every other command is refused with a message that SiteBlock is uninstalling.

**Second daemon:** at startup the socket server first tries to connect to an existing socket file. If a live daemon answers, the new process exits with code 1 and leaves the socket alone. Only a socket nobody answers on (left by a killed daemon) is removed and replaced.

**Logging:** Log lines go to standard error with an ISO 8601 timestamp; launchd sends them to the log file named in the plist. Successful commands other than `status` are logged by name and user ID, and so is every password check, right or wrong. Other rejected commands (such as an invalid domain or a malformed request) are counted per user ID and logged as one summary line per minute, such as "37 rejected requests from uid 501 in the last minute", so a flood of bad requests cannot fill the disk. Passwords and domains are never logged. macOS's log rotation tool, `newsyslog`, rotates both log files (see [04-infrastructure.md](04-infrastructure.md) § Install Script).

**Process runner:** every external command (`launchctl`, `dscacheutil`, `killall`, `pkill`) runs through `ProcessRunner.run`, which waits at most the given timeout and then kills the command. Its captured output is read only after the reader thread has finished, so a grandchild process that keeps the output pipe open cannot cause a data race.

**Signals:** `SIGTERM` (the polite stop signal launchd sends) saves state and exits with code 0. launchd restarts the daemon because of `KeepAlive`.

---

### 3. SocketServer (`Sources/siteblockd/SocketServer.swift`)

**Purpose:** Accepts connections on the Unix socket and turns each into one `Request` and one `Response`.

**Behavior:**
1. Remove any stale socket file at the path, create an `AF_UNIX` `SOCK_STREAM` socket, and `bind` it with the process umask (the mask that limits the permissions of newly created files) temporarily set to `0o111`. The socket file is then created with mode `0666`, so the logged-in user's app can connect, without a `chmod` by path, which would follow a symlink swapped in after `bind`. Then `listen` with a backlog of 16.
2. Accept on a dedicated thread. For each accepted connection, set `SO_RCVTIMEO` and `SO_SNDTIMEO` to 2 seconds and `SO_NOSIGPIPE` so a vanished client cannot crash the daemon.
3. Read the peer user ID with `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &xucred)` and take `cr_uid`, right after `accept`. If the call fails, use `UInt32.max` (an ID that is never root), so a failure can never grant root-only commands.
4. Limit open connections with `ConnectionLimiter` ([02-core-components.md](02-core-components.md) § ConnectionLimiter): at most 4 at a time per non-root user ID, and at most 32 in total, of which the last 4 are kept for root. A connection over its limit is closed at once without a reply. This stops one account from holding every slot with idle connections and locking everyone else out.
5. Read bytes until `\n`, end of stream, or 64 KB. Over the limit returns `badRequest`. Invalid JSON returns `badRequest` with the decoding message. A client that sends no complete line within 2 seconds receives `badRequest` with "No request arrived within 2 seconds." and is disconnected.
6. Hand the request and peer uid to the handler closure and write back the encoded response plus `\n`, then close. For `add`, `unblock` and `cancelUnblock`, the handler runs `DomainNormalizer.normalize` on the `domain` argument on the connection's own thread and answers `invalidDomain` at once when it fails, so a flood of bad names never waits on the engine queue. A valid request goes to the engine with its original text, and the engine normalizes it once itself.

---

### 4. HostsEnforcer (`Sources/siteblockd/HostsEnforcer.swift`)

**Purpose:** Makes the real hosts file match the engine's block list, and reports whether it does.

**Key Methods:**
- `func enforce(blockedHosts: [String], causedByCommand: Bool) -> Bool` — returns `true` when the file is correct after the pass. The runtime always passes `engine.hostsToWrite`, which includes the Private Relay names whenever a site is blocked.

**Steps:**
1. Read the hosts file as UTF-8. If it does not exist, treat it as empty. If it cannot be read, log and return `false`.
2. Compute `HostsFileEditor.render`. If the result equals the current text, return `true` without writing.
3. Otherwise, in production, clear the user and system immutable and append-only flags (`UF_IMMUTABLE`, `SF_IMMUTABLE`, `UF_APPEND`, `SF_APPEND`, which `chflags` sets to make a file unchangeable) on the hosts file and on its folder `/private/etc`. Root may clear them at macOS's normal security level, so `chflags uchg /etc/hosts` cannot freeze the file.
4. Write the new text to a temp file in the same folder with a random name (`.hosts.siteblock.XXXXXX`, created with `mkstemp`-style `O_CREAT|O_EXCL|O_NOFOLLOW`), set mode `0644` and (in production) owner `root:wheel`, then `rename` over the hosts file. A random name means a folder or file planted at a fixed temp path cannot block the write.
5. If the temp file cannot be created, or the rename fails, write the text into the hosts file itself, opened with `O_WRONLY|O_TRUNC|O_NOFOLLOW`, and remove any temp file. Getting the block written matters more than writing it atomically. The pass reports the file unhealthy only when this in-place write also fails.
6. In production, flush the name cache: run `/usr/bin/dscacheutil -flushcache` and `/usr/bin/killall -HUP mDNSResponder`, waiting at most 5 seconds for each.
7. Log what happened when the change was not caused by a command or a finished countdown. The message is "blocks removed from hosts file" when the pass only took lines away, and "hosts file repaired" for every other rewrite (it added lines or changed a user line). That way tampering shows up in the log, and a daemon that started with lost state does not report its removal of blocks as a repair.

---

### 5. LaunchdGuard and Watchdog (`Sources/siteblockd/LaunchdGuard.swift`)

**Purpose:** Keeps both background jobs loaded. The daemon guards the watchdog and the watchdog guards the daemon.

**Key Methods:**
- `static func isLoaded(_ job: Job) -> Bool` — runs `/bin/launchctl print system/<label>` and returns `true` on exit code 0.
- `static func ensureLoaded(_ job: Job)` — when the job is not loaded: write its plist from `LaunchdPlists.xml(for:)` if the file is missing or different, set the plist to `root:wheel` mode `0644`, make sure the program exists (copy from the backup path if missing, mode `0755`), run `/bin/launchctl enable system/<label>` to clear any "disabled" mark left by `launchctl disable`, then run `/bin/launchctl bootstrap system <plist>`. It logs what it repaired.
- `enum Job { case daemon, watchdog }` with each job's label and plist path.

**Watchdog loop (`siteblockd --watchdog`):** every 5 seconds, read `state.json`. When `UninstallRule.watchdogShouldStandDown` says it records a finished uninstall (`uninstalling` is `true` and `pendingUninstall` is finished), do nothing. In every other case, including a missing install folder or a missing or unreadable state file, call `ensureLoaded(.daemon)`. `ensureLoaded` recreates `/Library/Application Support/SiteBlock` with mode `0700` and its `bin` folder with mode `0755` before restoring the program from the backup, so deleting the install folder is repaired instead of being mistaken for an uninstall. The watchdog never touches the hosts file or the socket.

A real uninstall does not rely on the watchdog standing down: the daemon unloads the watchdog first (see § Uninstaller), so the watchdog is gone before any file is deleted.

**Plist text** is generated in code (`Sources/siteblockd/LaunchdPlists.swift`) rather than read from disk, so a deleted plist can always be recreated. Both plists set `RunAtLoad` and `KeepAlive` to `true`, `ProcessType` to `Interactive`, and `StandardErrorPath` to the log file. See [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs.

---

### 6. Uninstaller (`Sources/siteblockd/Uninstaller.swift`)

**Purpose:** Removes SiteBlock from the Mac when the uninstall countdown finishes.

**Steps, in order:**
1. Save the state with `uninstalling = true`. If this save fails (for example, the disk is full), stop the uninstall and exit with a non-zero code. launchd restarts the daemon, which retries the uninstall from the saved finished countdown, so the uninstall never runs half-way with an old state file on disk.
2. Unload the watchdog with `launchctl bootout system/com.nokal.siteblock.watchdog` and wait for it to finish (at most 10 seconds), so the watchdog cannot restore any file deleted in the steps below.
3. Remove the managed section from the hosts file (enforce with an empty block list), clear SiteBlock's keys from the Chrome policy files (see § ChromePolicyEnforcer), restore the saved DNS servers (see § DNSEnforcer), and flush the name cache.
4. Stop the menu bar app for the user at the screen. The console user's ID is the owner of `/dev/console`. When that ID is not 0, run `launchctl bootout gui/<uid>/com.nokal.siteblock.app` and `pkill -x SiteBlock`, ignoring failures.
5. Delete the backup program, the state backup, `/usr/local/bin/siteblock`, the app LaunchAgent plist, both LaunchDaemon plists, `/etc/newsyslog.d/siteblock.conf`, and the socket file.
6. Start a detached `/bin/sh` that waits 1 second, then runs `launchctl bootout system/com.nokal.siteblock.daemon`, then deletes `/Library/Application Support/SiteBlock` and `/Applications/SiteBlock.app`. The daemon is stopped by that `bootout`, so the shell must be detached (started with `setsid` through `posix_spawn` with `POSIX_SPAWN_SETSID`) to outlive it.

In sandbox mode, steps 2, 4, 5 and 6 are replaced by deleting the sandbox's own plist and socket files and exiting with code 0.

---

### 7. siteblock CLI (`Sources/siteblock/main.swift`)

**Purpose:** A Terminal interface for every command, mainly for scripting, recovery and checking status without the app.

**Usage:**
```
siteblock status
siteblock setup                     # asks for a new password twice
siteblock add <site> [<site> ...]   # the first time, asks you to choose the password
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
- Exit codes: `0` success, `1` the daemon refused the command (the error sentence is printed to standard error) or a typed password and its confirmation do not match, `2` the daemon is not running, `64` usage error. An empty password and a duration that `parseDuration` rejects are usage errors (`64`) and are never sent to the daemon, so a stray Enter does not use up one of the five password tries.
- `add` with several sites sends one request per site and keeps going after a failure, then exits `1` if any failed.
- `add` first asks the daemon for `status`. When no password is set it prompts for a new password twice (as `setup` does), sends `setup`, and only then sends the `add` requests. When standard input is not a terminal it reads the new password from the first line (and an optional confirmation from the second), the same as `setup`.

---

### 8. SiteBlock.app Menu Bar App (`Sources/SiteBlockApp/`)

**Purpose:** The everyday interface: a shield icon in the menu bar that opens a panel to add, view and unblock sites.

**Files:**
- `SiteBlockApp.swift` — the `@main` `App` with one `MenuBarExtra` using `.menuBarExtraStyle(.window)` (a panel that drops down from the icon). The icon is the SF Symbol (one of Apple's built-in icons) `shield.lefthalf.filled`, or `shield.slash` when the daemon cannot be reached.
- `StatusModel.swift` — an `ObservableObject` that holds the latest `StatusSnapshot`, the connection state and the last error. It polls `status` once per second while the panel is open and every 30 seconds otherwise, on a background queue, and publishes on the main queue. An answer identical to the snapshot already shown is not published again, and its arrival time is not stored either, because every published change makes SwiftUI rebuild and re-measure the whole panel; so an open panel with nothing changing does no drawing work between polls. It exposes one async method per command. It owns the `TabWatcher`: on every new snapshot it applies, it passes `snapshot.blockedPaths` (mapped to `WatchedPathRule` values of `domain` and `path`) to `TabWatcher.setRules`, and it republishes the watcher's `deniedBrowserNames` on the main actor for the permission banner.
- `Views/MainPanel.swift` — the panel layout, 440 points wide. The blocked list is a box sized to show exactly four closed rows (measured from a row on screen, plus the gaps between them); more sites scroll inside it, so the panel never changes size as sites are added.
- `Views/SetupView.swift`, `Views/BlockedListView.swift`, `Views/SettingsView.swift`, `Views/BannersView.swift`.
- `TabWatcher.swift` — reloads a browser tab that moved to a blocked part of a site without loading a page (see § 15).
- `ChromiumTabs.swift` — the Apple Events bridge to Chrome, Edge and Brave that `TabWatcher` uses (see § 16).

**Panel states:**
1. **Not running:** "The SiteBlock service isn't running." and the Terminal command to reinstall.
2. **Normal:** shown whether or not a password exists yet. The password is chosen at the first block, not at install or first launch.
   - **First block:** when no password is set and the user presses "Block", the panel does not send `add` yet. It shows "Choose a SiteBlock password" with two password fields (new and confirm), the minimum length rule, a warning that the password cannot be shown again and is needed to unblock, and "Set password and block" and "Cancel" buttons. On submit it sends `setup` and then, only if that succeeds, `add` for the site that was typed. A mismatch or a weak password is shown inline and nothing is sent.
   - When no password is set and sites are already blocked (after a finished recovery), the blocked list shows without "Unblock…" buttons and a banner offers "Choose a new password" with the same two fields.
   - One gray caption line above the field: "Block a whole site (youtube.com) or just part of one (youtube.com/shorts)."
   - A text field "Add a site (e.g. reddit.com)" and a "Block" button. Enter also submits. Errors appear in red under the field.
   - The blocked list. Each row shows the domain, a disclosure arrow that lists the expanded host names, and either an "Unblock…" button or, when pending, a live countdown such as "Unblocks in 29:41" with a "Keep blocked" button that cancels.
   - Pressing "Unblock…" replaces the row's button with a password field and "Start countdown" and "Cancel" buttons.
   - A footer with "Settings". There is no Quit button: the app always stays in the menu bar.
   - Banners at the top for a pending delay change, uninstall, recovery or lockout, each with its countdown and a cancel button where cancelling is allowed.
   - An Automation-permission banner. The Automation permission is the macOS setting (System Settings → Privacy & Security → Automation) that lists which apps may control other apps. The banner shows while at least one path rule exists and `TabWatcher.deniedBrowserNames` is not empty. It reads "Let SiteBlock control <names> so blocked parts of sites close right away.", where the names are the refusing browsers' display names joined by `ListFormatter` ("Google Chrome", "Brave and Google Chrome", or "Brave, Google Chrome, and Microsoft Edge"). Its "Open Settings" button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`. It uses the same style as the other banners (`Views/BannersView.swift`).
3. **Settings:** current delay with a picker of 5 minutes, 15 minutes, 30 minutes, 1 hour, 2 hours, 6 hours, 12 hours, 24 hours and 7 days plus a password field; a change-password form; and an "Uninstall SiteBlock…" button that asks for the password and explains that the uninstall waits 48 hours, or the unblock delay if that is longer, with every site still blocked during the wait.

**Behavioral notes:** The app holds no state of its own beyond what is on screen; the daemon is always the source of truth. Closing the app does not stop any blocking, and the app does not stay closed: its LaunchAgent has `KeepAlive` set, so launchd starts it again whenever it exits, and the daemon keeps that LaunchAgent loaded and the app bundle in place (see § AppGuard). The app is launched at login by a LaunchAgent (see [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs), and it sets `LSUIElement` so it has no Dock icon.

---

### 9. ChromePolicyEnforcer (`Sources/siteblockd/ChromePolicyEnforcer.swift`)

> Generalized by § 13 BrowserPolicyEnforcer, which applies the same file handling to Edge, Brave and Firefox; Chrome keeps the keys described here, and its `URLBlocklist` carries path-rule entries as well as whole sites.

**Purpose:** Keeps Chrome's mandatory `URLBlocklist` policy equal to SiteBlock's block list, so Chrome refuses blocked sites even in windows whose traffic goes through a proxy and never touches `/etc/hosts`. See [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works.

**Files written (production):**
- `/Library/Managed Preferences/com.google.Chrome.plist` — the machine-wide copy, which macOS reports to Chrome as forced (mandatory).
- `/Library/Managed Preferences/<console user>/com.google.Chrome.plist` — the per-user copy. Chrome watches this exact path and reloads its policies within seconds when it changes. The console user is the owner of `/dev/console`; when that is root (nobody logged in), only the machine-wide copy is written.

Both folders are `root:wheel` mode `0755` and both files `root:wheel` mode `0644`. In sandbox mode the same two files live under `root/ManagedPreferences/` and `root/ManagedPreferences/<user>/`.

**Key Methods:**
- `func enforce(blockedSites: [BlockedSite], causedByCommand: Bool = false) -> Bool` — called on every enforcement pass right after the hosts file. It builds the wanted list with `ChromePolicy.urlBlocklist(for:)`, reads each file, and rewrites a file when its `URLBlocklist` differs, when its mode is not `0644` or (in production) its owner is not `root:wheel`, or when the path is not a regular file, because a `chmod 600` or a symlink would otherwise stop Chrome from reading a correct list. Returns `false` (and logs) when a write fails.

**Adult-filter keys:** both files always carry `SafeSitesFilterBehavior` = 1 (integer), `ForceGoogleSafeSearch` = true and `DnsOverHttpsMode` = "off", so they exist even when no site is blocked. Only the uninstaller removes these keys (other keys are kept). A file is rewritten when any SiteBlock-managed key differs.

**Content rules (`Sources/SiteBlockCore/ChromePolicy.swift`, pure and unit-tested):**
- `static func urlBlocklist(for sites: [BlockedSite]) -> [String]` — the shortest list that covers every host of every blocked site: hosts lowercased, duplicates removed, and any host left out when a parent domain of it (whole labels only) is also in the list, because a Chrome `URLBlocklist` entry such as `youtube.com` already blocks every subdomain. Sorted. Chrome reads at most 1,000 entries of this policy and ignores the rest, and the shortened list keeps even 500 blocked sites well below that. Sites with a pending unblock are included, because they stay blocked until the countdown ends.
- `static func managedValues(blocklist: [String], adultFilter: Bool) -> [String: Any]` — the keys SiteBlock owns and their wanted values: `URLBlocklist` (only when the list is not empty) and, when `adultFilter` is true, the three adult-filter keys.
- `static let managedKeys` — `URLBlocklist`, `SafeSitesFilterBehavior`, `ForceGoogleSafeSearch`, `DnsOverHttpsMode`.
- `static func merged(existing: [String: Any]?, managed: [String: Any]) -> [String: Any]?` — keeps every key of `existing` that is not one of `managedKeys` (so a real company policy is never lost), removes every managed key, then adds the `managed` values. When nothing is left it returns `nil`, meaning the file is deleted.

**Writing:** encode as an XML property list, write to a random temp file in the same folder (`O_CREAT|O_EXCL|O_NOFOLLOW`), `fchmod 0644`, `fchown 0:0` (production), `rename` over the target. A target that is a symlink is replaced, never followed. A file that is not a valid property list is treated as empty and replaced.

**Tamper repair and logging:** a pass that rewrites a file not changed by a command logs "Chrome policy repaired".

**Uninstall:** the uninstaller removes `URLBlocklist` from both files (deleting them when nothing else is left) in the same step that removes the hosts section.

---

### 10. AppGuard (`Sources/siteblockd/AppGuard.swift`)

**Purpose:** Keeps the menu bar app installed and running, so it cannot be deleted, moved to the Trash or unloaded to make SiteBlock disappear from view. The blocking itself never depends on the app.

**Behavior (every 5 seconds, on the guard timer that also checks the watchdog; production and sandbox):**
1. **Bundle check.** The app is intact when `<app>/Contents/MacOS/SiteBlock` and `<app>/Contents/Info.plist` exist as regular files and the executable's size equals the backup's. When it is not intact (missing, moved to the Trash, partly deleted, replaced), the guard removes whatever is at the app path and copies the backup with `/usr/bin/ditto <backup> <app>` (which keeps the code signature), then, in production, sets the whole bundle to `root:wheel`. It logs "menu bar app restored".
2. **Agent check (production only).** For the console user (owner of `/dev/console`, skipped when that is root), it runs `/bin/launchctl print gui/<uid>/com.nokal.siteblock.app`. When that fails (someone ran `launchctl bootout` on it), it rewrites the LaunchAgent plist if missing or different, runs `/bin/launchctl enable gui/<uid>/com.nokal.siteblock.app` (any user can `launchctl disable` their own agent, which would otherwise make every bootstrap fail), and runs `/bin/launchctl bootstrap gui/<uid> <plist>`. It also runs `/bin/launchctl kickstart gui/<uid>/com.nokal.siteblock.app` after a bundle restore, and whenever the agent is loaded but the job's first `state =` line in `launchctl print` is not `running` (launchd may still hold an older definition without `KeepAlive`), so the app starts at once. It logs "menu bar app agent reloaded".
3. A backup that is missing or itself incomplete (no executable or no `Info.plist`) is logged once a minute and nothing is restored from it, so a damaged backup cannot cause a restore every 5 seconds.

**Paths:** the backup is `/usr/local/libexec/siteblock/SiteBlock.app` (sandbox: `root/libexec/siteblock/SiteBlock.app`); the app is `Paths.appBundle`.

**Uninstall:** the guard timer is cancelled when an uninstall starts (as for the watchdog check), and the uninstaller deletes the backup bundle along with the other files, so nothing is restored after a real uninstall.

---

### 11. DNSEnforcer (`Sources/siteblockd/DNSEnforcer.swift`)

**Purpose:** Keeps every network service's DNS servers set to Cloudflare for Families for as long as SiteBlock is installed, and lets the uninstaller put the original servers back. See [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works (Adult content filter).

**Backend:** the reading and writing of network settings goes through a small protocol, `DNSSettingsBackend`, with two implementations:
- `SystemConfigurationDNSBackend` (production) uses the SystemConfiguration framework in-process: `SCPreferencesCreate`, `SCNetworkServiceCopyAll`, `SCNetworkServiceGetEnabled`, `SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)`, the protocol's configuration dictionary key `ServerAddresses`, then `SCPreferencesCommitChanges` and `SCPreferencesApplyChanges`. It never runs `networksetup`, so a check costs no new process. Services whose interface type is a VPN (`kSCNetworkInterfaceTypePPP`, `IPSec`, `VPN`) or that are disabled are skipped.
- `FileDNSBackend` (sandbox) reads and writes `root/network-services.json`, a dictionary from service ID to `{"name": String, "servers": [String]}`, so tests can create services and tamper with them.

**Pass (`enforce(adultFilterActive:savedDNS:persist:)`, called at startup, after every command except `status`, whenever macOS reports a network-settings change, and on the fallback timer; `persist` saves the originals to the state before anything is changed):**
1. While SiteBlock is installed (`adultFilterActive`): for each service whose servers are not exactly the family list, first record its current servers in `state.savedDNS[serviceID]` if no entry exists yet (a service SiteBlock already overrode keeps its first saved value), then set the family list. A service that appears later (a new adapter) is handled the same way.
2. When `adultFilterActive` is false (only during an uninstall) and `savedDNS` is not empty: for each saved service that still exists, set its servers back to the saved list (an empty list removes `ServerAddresses`, so the service uses the network's own DNS again), then clear `savedDNS`.
3. After any change, flush the name cache (production). A first-time override logs "DNS settings set to the family servers for N network services"; overriding a service SiteBlock had already overridden (someone changed it back) logs "DNS settings repaired".

**Reachability check:** a separate background queue (never the engine queue, so commands and ticks never wait on the network) sends one DNS query for `example.com` (type A, UDP port 53) to `1.1.1.3` and `1.0.0.3` at the same time and waits up to 2 seconds for either to answer, built and checked by `Sources/SiteBlockCore/DNSProbePacket.swift` (a random 16-bit ID; an answer counts only with the same ID and the QR bit set). It runs every 30 seconds and right after a network change, stores the latest result, and schedules a DNS pass when the result changes. A success counts at once, but the answer only turns to "unreachable" after 3 failed checks in a row, re-checked 5 seconds apart, because a single lost reply is common on real networks and must not switch the Mac's DNS back and forth. Real sign-in Wi-Fi is still detected within about 10 seconds. The probe code lives in `Sources/SiteBlockCore/FamilyDNSProbe.swift`; in sandbox mode the file `root/family-dns-probe-delay` (seconds) makes each check slow, for tests. Until the first result arrives, passes leave the current settings as they are. When neither answers, the family servers are unreachable on this network, which happens on Wi-Fi with a sign-in page (a captive portal that blocks outside DNS until you log in) and on networks that force their own DNS. Then the enforcer does not override anything, and if services are already overridden it puts their saved servers back (keeping `savedDNS`), logging "family DNS unreachable; using the network's own DNS until it answers" once per change. As soon as a check succeeds again, step 1 applies the family servers. Chrome's SafeSites layer stays on throughout. A network that blocks Cloudflare therefore gets only the Chrome layer; that is the accepted trade for never leaving the Mac without working DNS.

**Read-back (production):** after committing, the enforcer re-reads each changed service's `ServerAddresses`. A service that does not hold what was written gets its saved original back, is logged ("DNS change did not take effect for <name>; left the network's DNS in place") and is not retried for 10 minutes, so a fault in writing can never leave the Mac without working DNS or loop.

**Diagnostic:** `siteblockd --print-dns-plan [--sandbox <dir>]` reads (never writes) the network services and prints each one's ID, name, interface type, enabled flag, whether it is skipped and why, current servers, what SiteBlock would set, and the reachability result. It needs no root. In sandbox mode the services come from `root/network-services.json`, whose entries may also carry `enabled`, `interfaceType` and `ignoreWrites` for tests, and the file `root/family-dns-unreachable` makes the family servers count as unreachable; production has no such hooks.

**Change notifications (production):** a `SCDynamicStore` watching `Setup:/Network/Service/.*/DNS` and `State:/Network/Global/DNS` runs a pass on the engine queue within about a second of any change, so a hand edit in System Settings or joining a new network is undone at once. The ordinary 2-second tick does not touch DNS; a fallback pass runs every 30 seconds.

**Uninstall:** the uninstaller runs a pass with the filter inactive (restoring the saved servers) in the same step that clears the hosts section and the Chrome policy.

---

### 12. Adult filter in the app and CLI

**App (Settings):** an informational "Adult content filter: always on" section with one sentence: "Blocks all adult content across every browser and app. To remove it, uninstall SiteBlock." There is no toggle. (The filter's limits are documented in the README and § Threat Model, not in the app.)

**CLI:** `siteblock status` prints "Adult content filter: always on". There is no command to change it.

---

### 13. BrowserPolicyEnforcer (`Sources/siteblockd/BrowserPolicyEnforcer.swift`)

**Purpose:** Writes SiteBlock's protected policy for every supported browser, so each one refuses blocked sites and path rules itself and uses the Mac's own name lookups. It uses the same file rules as § 9: for each target, a machine-wide file and a per-console-user file under `/Library/Managed Preferences` (`root:wheel`, folders `0755`, files `0644`), atomic random-temp writes, other keys kept, SiteBlock's managed keys replaced, a file deleted when nothing else is left, a rewrite when a managed key differs in value or type or the mode or owner is wrong or the path is not a plain file, `O_NONBLOCK` opens, and "browser policy repaired (<target>)" logged for tampering.

**Settings cache refresh (production):** browsers do not read these files themselves; they ask `cfprefsd`, the macOS service that reads and caches app settings, and `cfprefsd` is not told when a file under `/Library/Managed Preferences` is rewritten directly, so without help it keeps serving the copy it read first (a later block or filter key would never reach the browsers). After any pass that changed a file, the enforcer stops the console user's `cfprefsd` with `/usr/bin/pkill -x -U <uid> cfprefsd`; launchd starts a fresh one on the next request, which reads the files again, and running browsers pick the change up on their next policy reload. A failure is ignored.

**Targets and their managed keys** (all always present while SiteBlock is installed; only the uninstaller removes them):
- **Chrome** — `com.google.Chrome`: `URLBlocklist` (the Chrome browser list), `SafeSitesFilterBehavior` = 1, `ForceGoogleSafeSearch` = true, `DnsOverHttpsMode` = "off".
- **Edge** — `com.microsoft.Edge`: `URLBlocklist`, `DnsOverHttpsMode` = "off", `ForceGoogleSafeSearch` = true, `ForceBingSafeSearch` = 2 (strict).
- **Brave** — `com.brave.Browser`: `URLBlocklist`, `DnsOverHttpsMode` = "off", `SafeSitesFilterBehavior` = 1, `ForceGoogleSafeSearch` = true.
- **Firefox** — `org.mozilla.firefox`: `EnterprisePoliciesEnabled` = true, `DNSOverHTTPS` = `{Enabled: false, Locked: true}`, `WebsiteFilter` = `{Block: [the Firefox browser list]}`. Firefox also reads `/Library/Preferences/org.mozilla.firefox.plist`, so for Firefox that third file is written too, with the same rules.

`URLBlocklist` and `WebsiteFilter` are left out when their list is empty. Each list is capped at 1,000 entries (both browsers ignore the rest); the engine's site cap keeps it below that in practice, and a list that would exceed it is cut to 1,000 with whole-site entries kept first, logged once. The writes target these files whether or not the browser is installed, so installing a browser later is covered at once.

**Sandbox:** the same files under `root/ManagedPreferences/` (and `root/Preferences/org.mozilla.firefox.plist`).

---

### 14. Path rules in the app and CLI

**App:** typing a site name alone and pressing Block blocks the whole site, as before. When the typed text contains a path (`PathRuleParser.split` returns a path), a two-choice control appears under the field: "Only this part" (selected) and "Whole site"; the Block button follows the choice (`addPath` or `add`). The blocked list shows path rules in their own group, "Blocked parts of sites", each row showing the rule (`youtube.com/shorts`) with the same "Unblock…" / countdown / "Keep blocked" controls as a site. Under the group heading, one line: "Works in Chrome, Firefox, Edge and Brave. Safari can only block whole sites."

**CLI:**
- `siteblock add <text>` — whole-site block when the text has no path; a path rule when it has one (`siteblock add youtube.com/shorts`). `--whole-site` forces a whole-site block from text that has a path.
- `siteblock unblock <text>` and `siteblock cancel <text>` — act on the path rule when the text has a path, otherwise on the site.
- `siteblock status` — prints "Blocked parts of sites (N):" with one line per rule, after the sites.

**Sites that change address without loading a page:** the browsers apply path rules when a page loads. The menu bar app's tab watcher also reloads a Chrome, Edge or Brave tab that moves to a blocked part of a site inside an already-open page, so the browser then shows its block page. See § 15 TabWatcher and § 16 ChromiumTabs.

---

### 15. TabWatcher (`Sources/SiteBlockApp/TabWatcher.swift`)

**Purpose:** Catches a tab that moves to a blocked part of a site without loading a page. Chrome, Edge, Brave and Firefox check their block lists (`URLBlocklist`, `WebsiteFilter`) only when a page loads. Some sites change the address inside a page that is already open, using the browser's `history.pushState` feature (a way for a page to change the address bar without a page load). YouTube does this when you are on youtube.com and tap Shorts: the address becomes `youtube.com/shorts/...`, but no page load happens, so a path rule such as `youtube.com/shorts` is not applied. Browser policy cannot change this, so the watcher reads tab addresses from outside the browser. While at least one path rule exists and at least one supported browser is running, it reads the address of every open tab in Chrome, Edge and Brave every 0.5 seconds. When a tab's address matches a path rule and the watcher has not already acted on that tab at that address, it reloads that tab once. A reload is a real page load, so the browser's own `URLBlocklist` then shows its block page.

**Why it lives in the menu bar app:** the watcher sends Apple Events (the macOS mechanism one app uses to ask another app for data or to perform an action; AppleScript is built on it) to the user's browsers. Those events must come from an app in the user's own login session, and macOS asks the user for permission for each sending app. The menu bar app runs as the logged-in user and is kept running by its LaunchAgent, so it hosts the watcher. The root daemon cannot send them.

**Ownership and scheduling:** `StatusModel` owns the `TabWatcher`. It runs on its own serial background queue with a repeating timer every 0.5 seconds (leeway 0.1 seconds). A tick that is still running when the next one is due makes that next tick be skipped; ticks are never queued behind each other.

**Inputs and outputs:**
- `func setRules(_ rules: [WatchedPathRule])` — `StatusModel` calls it every time it applies a new snapshot, passing `snapshot.blockedPaths` mapped to `domain` and `path`. The daemon's list includes rules that are waiting to unblock, which are still blocked, so they are watched too. A rule added in the app reaches the watcher at once, because the app refreshes the status after each command. A rule added from the `siteblock` command line reaches it on the next status poll, which is within 30 seconds while the panel is closed.
- `deniedBrowserNames: [String]` — the sorted display names of running supported browsers whose Automation permission is denied. The watcher publishes it to `StatusModel` on the main actor whenever it changes, and the panel shows the permission banner from it (see § 8, Panel states).

**Dependencies:** `ChromiumTabs` (§ 16) for all browser access, and `TabReloadDecider` and `TabRuleMatcher` from `SiteBlockCore` ([02-core-components.md](02-core-components.md) § TabReloadDecider, § TabRuleMatcher) for every decision. The watcher itself keeps one `TabReloadDecider` on its queue.

**Each tick, in order:**
1. When there are no rules, clear the decider, end the App Nap activity (step 3), send no Apple Events, and stop.
2. List the running supported browsers with `ChromiumTabs.runningBrowsers()`. When none is running, forget all process memory in the decider, report no denied browsers, and stop. The activity stays held, so the first check after a browser starts is not delayed.
3. Hold one `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Checking browser tabs for blocked parts of sites")` for as long as at least one rule exists, and end it when there are none. App Nap is the macOS feature that slows the timers of apps that have no visible window; without the activity it would delay these checks by many seconds.
4. For each browser process, look up its permission. The first time a bundle identifier is seen during an app run, call `ChromiumTabs.permission(pid:ask: true)`, which shows the macOS prompt if the person has never answered. When the answer is denied, check again with `ask: false` at most every 10 seconds, so turning the permission on later in System Settings takes effect without restarting the app. Only processes whose permission is `.allowed` are read.
5. Read the tabs of each allowed process with `ChromiumTabs.readTabs(pid:)`. On an error (a timeout, the browser quitting, the permission being revoked), skip that process for this tick and keep its memory, which the decider does automatically because the process is simply not passed to it.
6. Ask the decider which tabs to reload. For each one, read that tab's current address again with `ChromiumTabs.currentURL(pid:windowID:tabID:)`, and reload it with `ChromiumTabs.reload(pid:windowID:tabID:)` only when that address still matches a rule. The second read keeps the watcher from reloading a tab that has already moved on since the list was read. Errors from these calls are ignored.
7. Log each reload with `os.Logger(subsystem: "com.nokal.siteblock.app", category: "tabs")` at info level: "reloaded a <browser name> tab on a blocked part of a site: <rule display text>". The message names the rule, not the full address. Changes of permission are logged as "permission to control <name>: allowed" or "permission to control <name>: denied".
8. Forget the decider's memory for processes that are no longer running (`forgetProcesses(except:)`).

**Cost:** the watcher sends no Apple Events at all unless a path rule exists and a supported browser is running. Otherwise each tick costs, per browser process, one event plus three per window (about ten events a second for one window). Each event costs the browser well under a millisecond, so the CPU and battery cost is negligible.

**Limits:** the person can refuse the permission, or turn it off later under System Settings → Privacy & Security → Automation. The watcher then does nothing for that browser, path rules there apply only when a page loads, and the banner says so. The blocked part of a site can show for up to about half a second before the tab reloads. Firefox has no Apple Events access to its tabs, so a part of a site that opens without a page load in Firefox is caught only on the next reload or a direct open. Safari has no path rules. See [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits.

---

### 16. ChromiumTabs (`Sources/SiteBlockApp/ChromiumTabs.swift`)

**Purpose:** The Apple Events bridge to the Chromium-based browsers. It lists the running browsers, checks the Automation permission for each, reads every tab's identifiers and address, reads one tab's current address, and reloads one tab. It has no policy of its own; `TabWatcher` decides what to do with what it returns.

**Dependencies:** Foundation, AppKit and CoreServices only, and no other app file, so a test harness can compile this file on its own.

**Supported browsers** (bundle identifier, then display name):
- `com.google.Chrome` — "Google Chrome"
- `com.microsoft.edgemac` — "Microsoft Edge"
- `com.brave.Browser` — "Brave"

All three use Chromium's scripting dictionary (the list of objects and commands a Mac app exposes to Apple Events), so the same codes work for each. The codes come from `/Applications/Google Chrome.app/Contents/Resources/scripting.sdef`: window class `cwin`, tab class `CrTb`, property `id` = `ID  `, property `URL` = `URL `, and the `reload` command with event class `CrSu` and event ID `Rlod`.

**Addressing by process:** every running process of those bundle identifiers is addressed by its process ID, through a target descriptor made with `NSAppleEventDescriptor(processIdentifier:)`. This matters because a person can run more than one Chrome at once (for example a second Chrome started with its own `--user-data-dir`, which is a separate process), and an Apple Event addressed by app name reaches only one of them.

**Types:**
- `AutomationPermission` — `.allowed`, `.denied`, `.notAsked`, `.unavailable`.

**Key Methods:**
- `static func runningBrowsers() -> [(pid: pid_t, bundleID: String, name: String)]` — built from `NSWorkspace.shared.runningApplications`, skipping terminated applications.
- `static func permission(pid: pid_t, ask: Bool) -> AutomationPermission` — calls `AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)`. A result of `noErr` is `.allowed`, `errAEEventNotPermitted` (-1743) is `.denied`, `errAEEventWouldRequireUserConsent` (-1744) is `.notAsked`, and anything else (for example `procNotFound`, -600) is `.unavailable`. With `ask: true` the call shows the macOS prompt "SiteBlock wants access to control Google Chrome" the first time and blocks until the person answers, so `TabWatcher` calls it only on its background queue.
- `static func readTabs(pid: pid_t) throws -> [(windowID: String, tabID: String, url: String)]` — sends `get id of every window`. Then, for each window ID W, it sends `get id of every tab of window id W`, then `get URL of every tab of window id W`, then `get id of every tab of window id W` again. A window's tabs are used only when the two ID lists are equal and the address list has the same count, which shows that IDs and addresses line up. A tab opened, closed or moved in between makes that window be skipped for the tick. IDs may come back as integers or as text; they are stored in their text form.
- `static func currentURL(pid: pid_t, windowID: String, tabID: String) throws -> String` — sends `get URL of tab id T of window id W`.
- `static func reload(pid: pid_t, windowID: String, tabID: String) throws` — sends the `CrSu`/`Rlod` event with the direct object `tab id T of window id W`.

**Event construction:** object specifiers are `NSAppleEventDescriptor` records of type `obj ` with the keys `want`, `from`, `form` and `seld`. They use `formUniqueID` (`ID  `) for "window id W" and "tab id T", `formAbsolutePosition` with `kAEAll` for "every", and `formPropertyID` for properties. Events are sent with `sendEvent(options: [.waitForReply], timeout: 2)`, so each event waits at most 2 seconds. An ID used in a specifier is sent back with the same descriptor type it arrived in, so an ID that came back as an integer goes out as an integer.

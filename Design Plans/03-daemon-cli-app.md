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
- `StatusModel.swift` — an `ObservableObject` that holds the latest `StatusSnapshot`, the connection state and the last error. It polls `status` once per second while the panel is open and every 30 seconds otherwise, on a background queue, and publishes on the main queue. It exposes one async method per command.
- `Views/MainPanel.swift` — the panel layout, 440 points wide. The blocked list is a box sized to show exactly four closed rows (measured from a row on screen, plus the gaps between them); more sites scroll inside it, so the panel never changes size as sites are added.
- `Views/SetupView.swift`, `Views/BlockedListView.swift`, `Views/SettingsView.swift`.

**Panel states:**
1. **Not running:** "The SiteBlock service isn't running." and the Terminal command to reinstall.
2. **Normal:** shown whether or not a password exists yet. The password is chosen at the first block, not at install or first launch.
   - **First block:** when no password is set and the user presses "Block", the panel does not send `add` yet. It shows "Choose a SiteBlock password" with two password fields (new and confirm), the minimum length rule, a warning that the password cannot be shown again and is needed to unblock, and "Set password and block" and "Cancel" buttons. On submit it sends `setup` and then, only if that succeeds, `add` for the site that was typed. A mismatch or a weak password is shown inline and nothing is sent.
   - When no password is set and sites are already blocked (after a finished recovery), the blocked list shows without "Unblock…" buttons and a banner offers "Choose a new password" with the same two fields.
   - A text field "Add a site (e.g. reddit.com)" and a "Block" button. Enter also submits. Errors appear in red under the field.
   - The blocked list. Each row shows the domain, a disclosure arrow that lists the expanded host names, and either an "Unblock…" button or, when pending, a live countdown such as "Unblocks in 29:41" with a "Keep blocked" button that cancels.
   - Pressing "Unblock…" replaces the row's button with a password field and "Start countdown" and "Cancel" buttons.
   - A footer with "Settings". There is no Quit button: the app always stays in the menu bar.
   - Banners at the top for a pending delay change, uninstall, recovery or lockout, each with its countdown and a cancel button where cancelling is allowed.
3. **Settings:** current delay with a picker of 5 minutes, 15 minutes, 30 minutes, 1 hour, 2 hours, 6 hours, 12 hours, 24 hours and 7 days plus a password field; a change-password form; and an "Uninstall SiteBlock…" button that asks for the password and explains that the uninstall waits 48 hours, or the unblock delay if that is longer, with every site still blocked during the wait.

**Behavioral notes:** The app holds no state of its own beyond what is on screen; the daemon is always the source of truth. Closing the app does not stop any blocking, and the app does not stay closed: its LaunchAgent has `KeepAlive` set, so launchd starts it again whenever it exits, and the daemon keeps that LaunchAgent loaded and the app bundle in place (see § AppGuard). The app is launched at login by a LaunchAgent (see [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs), and it sets `LSUIElement` so it has no Dock icon.

---

### 9. ChromePolicyEnforcer (`Sources/siteblockd/ChromePolicyEnforcer.swift`)

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

**Pass (`enforce(adultFilterActive:state:)`, called on every enforcement pass and whenever macOS reports a network-settings change):**
1. While SiteBlock is installed (`adultFilterActive`): for each service whose servers are not exactly the family list, first record its current servers in `state.savedDNS[serviceID]` if no entry exists yet (a service SiteBlock already overrode keeps its first saved value), then set the family list. A service that appears later (a new adapter) is handled the same way.
2. When `adultFilterActive` is false (only during an uninstall) and `savedDNS` is not empty: for each saved service that still exists, set its servers back to the saved list (an empty list removes `ServerAddresses`, so the service uses the network's own DNS again), then clear `savedDNS`.
3. After any change, flush the name cache (production) and report that the state changed (so `savedDNS` is saved). Log "DNS settings repaired" when a pass that was not caused by a command or a finished countdown had to override a service.

**Change notifications (production):** a `SCDynamicStore` watching `Setup:/Network/Service/.*/DNS` and `State:/Network/Global/DNS` runs a pass on the engine queue within about a second of any change, so a hand edit in System Settings or joining a new network is undone at once. The ordinary 2-second tick does not touch DNS; a fallback pass runs every 30 seconds.

**Uninstall:** the uninstaller runs a pass with the filter inactive (restoring the saved servers) in the same step that clears the hosts section and the Chrome policy.

---

### 12. Adult filter in the app and CLI

**App (Settings):** an informational "Adult content filter: always on" section, saying that SiteBlock blocks adult websites in every browser and that only uninstalling SiteBlock removes it. There is no toggle.

**CLI:** `siteblock status` prints "Adult content filter: always on". There is no command to change it.

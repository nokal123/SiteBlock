# Overview and Data Model
> Part of the SiteBlock Design Plans
> See also: [02-core-components.md](02-core-components.md), [03-daemon-cli-app.md](03-daemon-cli-app.md), [04-infrastructure.md](04-infrastructure.md)

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Requirements](#requirements)
3. [How Blocking Works](#how-blocking-works)
4. [Architecture](#architecture)
5. [Threat Model and Honest Limits](#threat-model-and-honest-limits)
6. [Data Model](#data-model)
7. [Wire Protocol](#wire-protocol)
8. [Fixed Policy Values](#fixed-policy-values)

---

## Executive Summary

SiteBlock is a macOS website blocker that works below the browser, so it blocks a site in Safari, Chrome, Firefox and every other app at the same time. It has three programs, all written in Swift and built with Swift Package Manager (Apple's command-line build tool for Swift code):

- `siteblockd` is a background service that runs as root (the administrator account that is allowed to change system files). It owns the list of blocked sites, writes them into the system hosts file, and puts them back within two seconds if anyone removes them.
- `siteblock` is a Terminal command that talks to `siteblockd`.
- `SiteBlock.app` is a menu bar app (an icon in the top-right menu bar of the screen) that talks to `siteblockd` and shows the blocked sites, the unblock countdowns and the settings.

Blocking a site is always free and instant. Unblocking a site needs the SiteBlock password, and even with the right password the site stays blocked for a waiting period (30 minutes by default) before it opens. During that wait anyone can cancel the unblock without a password.

---

## Requirements

1. Block any website the user chooses, in every browser, with special attention to Safari and Chrome.
2. Work at the system level rather than as a browser extension.
3. Keep sites blocked indefinitely until the user unblocks them.
4. Gate unblocking behind a password that belongs to SiteBlock and is separate from the Mac login password.
5. Be very hard to get around on impulse. That means the block repairs itself after hand edits, the service restarts itself after it is stopped, and the clock cannot be moved forward to skip a wait.
6. Make unblocking take effect only after a waiting period, so that even a successful bypass of the password costs time.
7. Never lock the user out permanently. A forgotten password can be reset with the Mac admin password plus a 48-hour wait.

---

## How Blocking Works

Every app on a Mac turns a site name such as `reddit.com` into a numeric server address before it connects. macOS checks the file `/etc/hosts` first, before asking any internet name server. SiteBlock writes lines such as `0.0.0.0 reddit.com` and `:: reddit.com` into that file. `0.0.0.0` (for the older IPv4 address format) and `::` (for the newer IPv6 format) are addresses that point nowhere, so the browser's connection fails immediately and the page does not load.

Chrome has its own name lookup code, including "Secure DNS" (looking up names over an encrypted HTTPS connection to a name server). Chrome still reads `/etc/hosts` before it uses Secure DNS: its resolver adds a hosts-file lookup step to every lookup in every Secure DNS mode (`HostResolverManager::CreateTaskSequence` in Chromium's `net/dns/host_resolver_manager.cc`), so the block applies to Chrome too. Safari uses the macOS system lookup, which reads `/etc/hosts`.

Some Chrome windows never ask the Mac to look a name up at all. A Chrome started with `--proxy-server=socks5://…` (for example a window used to reach a work dashboard through an SSH tunnel) hands each site name to the proxy, and the remote computer looks it up. So SiteBlock also writes Chrome's own block list. Chrome reads mandatory policies from `/Library/Managed Preferences`, a folder only root can write, and its `URLBlocklist` policy makes Chrome itself refuse every listed site and all its subdomains, in every window and profile, whatever proxy or lookup method is in use. `URLBlocklist` is not one of the "sensitive" policies Chrome ignores on Macs no company manages (only extension-install policies are). While any site is blocked, Chrome shows "Managed by your organization" in its menu; that label refers to this list.

iCloud Private Relay (Apple's paid service that routes Safari traffic through Apple's servers) is the exception: while it is on, Safari's lookups go to Apple's name servers, and the hosts file may be skipped. Apple documents that a network turns Private Relay off by blocking the names `mask.icloud.com` and `mask-h2.icloud.com`. So whenever at least one site is blocked, SiteBlock also writes those two names into its hosts section. macOS then reports Private Relay as unavailable and Safari's lookups go through the hosts file. The cost is that Private Relay stays off while anything is blocked, and the README says so.

After every change to the hosts file, `siteblockd` clears the macOS name cache by running `dscacheutil -flushcache` and sending a reload signal to `mDNSResponder` (the macOS process that answers name lookups). Without this step a recently visited site could keep working for a few minutes from the cached address.

The hosts file cannot use wildcards such as `*.reddit.com`. To catch the common ways into a site, SiteBlock expands each site into a list of host names: the site itself, its `www.` form, a fixed list of common prefixes (`m.`, `mobile.`, `old.`, `new.`, `amp.`, `app.`, `web.`), and a hand-written list of related names for well-known sites (for example `redd.it` and `i.redd.it` for Reddit). See [02-core-components.md](02-core-components.md) § DomainExpander.

SiteBlock does not block by server address in the macOS firewall (`pf`, the packet filter built into macOS). Large sites are served from shared content delivery networks, so one server address can belong to thousands of unrelated sites. Blocking Reddit's address would also block many other sites that happen to share it.

---

## Architecture

```
 ┌─────────────────────┐     ┌────────────────────┐
 │ SiteBlock.app       │     │ siteblock (CLI)    │
 │ menu bar, user uid  │     │ user uid or sudo   │
 └─────────┬───────────┘     └─────────┬──────────┘
           │ one JSON request per connection
           ↓                           ↓
     /var/run/siteblock.sock  (Unix domain socket, mode 0666)
           │
           ↓
 ┌──────────────────────────────────────────────────┐
 │ siteblockd --daemon   (root, LaunchDaemon)       │
 │  • Engine: state, password check, countdowns     │
 │  • every 2 s: tick countdowns, enforce hosts     │
 │  • every 5 s: make sure the watchdog is loaded   │
 └───┬───────────────┬────────────────┬─────────────┘
     ↓               ↓                ↓
 /etc/hosts     state.json      launchctl (load watchdog)
 (managed       (root 0600)
  section)
                        ↑ restarts each other ↓
 ┌──────────────────────────────────────────────────┐
 │ siteblockd --watchdog (root, second LaunchDaemon)│
 │  • every 5 s: make sure the daemon is loaded,    │
 │    restore its plist and binary if deleted       │
 └──────────────────────────────────────────────────┘
```

Both background jobs are LaunchDaemons (programs that macOS's `launchd` starts at boot as root and restarts whenever they exit, because their configuration sets `KeepAlive`). If someone unloads one of them with `launchctl bootout`, the other one loads it again within five seconds.

---

## Threat Model and Honest Limits

SiteBlock defends against the owner of the Mac acting on impulse. It does not defend against a determined administrator with time. Every step that loosens a block costs either the SiteBlock password or a waiting period, and most cost both.

**What SiteBlock stops:**

- Editing `/etc/hosts` by hand. The daemon rewrites its section within two seconds, and it also removes lines elsewhere in the file that point a blocked name at a real address (because macOS uses the first matching line, such a line would otherwise win).
- Unloading the daemon or the watchdog. Each one reloads the other.
- Deleting or trashing the menu bar app, quitting it, or unloading its startup entry. The daemon puts the app back from a root-owned backup and relaunches it within 5 seconds, and launchd restarts it whenever it exits. (The app is only the window; blocking never depended on it.)
- Deleting the daemon's plist (its `launchd` configuration file) or its program file. The watchdog writes the plist again from a copy built into its own program and copies the program back from a backup location.
- Deleting or editing the state file. The running daemon writes it back from memory within one tick, and a daemon that starts with no state file reads a backup copy kept in a second folder.
- Moving the system clock forward. Countdowns are measured with a monotonic clock (a counter that only moves forward with real elapsed time and ignores the wall clock).
- Guessing the password with a script. Five wrong passwords lock password checks for 15 minutes.
- Shortening the waiting period on impulse. Making the wait longer applies at once. Making it shorter has to sit through the current wait first.

**What SiteBlock cannot stop:**

- A root user who unloads both background jobs at the same moment and then deletes their files. No program can fully defend against root on its own machine. The strongest setup is to use a standard (non-administrator) macOS account day to day and give the administrator password to someone else; then none of the root-level bypasses are available on impulse.
- A root user who stops the daemon (for example with `kill -9`) and edits or deletes `state.json` and its backup before launchd restarts it. The restarted daemon trusts what it finds on disk, so a forged countdown or an empty state takes effect. Freezing both jobs with `pkill -STOP` is the same kind of root-level bypass. So is switching both jobs off under System Settings → General → Login Items & Extensions → "Allow in the Background", which asks for the administrator password; SiteBlock clears a `launchctl disable` mark before reloading a job, but it cannot overrule that switch if macOS does not let it.
- A VPN (a service that tunnels all traffic through another computer) or a proxy that does name lookups on the remote side.
- Tabs that were already connected to a site before it was blocked. Browsers reuse open connections for a short time, so an already-open page may keep loading until the browser closes that connection. Reloading after a minute or two shows the block.

---

## Data Model

All persistent data lives in one JSON file, `state.json`, owned by root with mode `0600` (only root can read or write it). The Swift type is `PersistedState` in `SiteBlockCore`.

### PersistedState

- `version: Int` — schema version, currently `1`.
- `passwordHash: PasswordHash?` — the stored password fingerprint, or `nil` when no password has been set yet (first run, or after a finished recovery).
- `blocked: [BlockedSite]` — every site currently blocked, in the order added.
- `delaySeconds: Int` — the current unblock waiting period. Default `1800` (30 minutes).
- `pendingDelayChange: PendingDelayChange?` — a requested shorter waiting period that has not taken effect yet.
- `pendingUninstall: Countdown?` — a requested uninstall that has not taken effect yet.
- `recovery: Countdown?` — a running forgotten-password reset.
- `failedAttempts: Int` — wrong passwords since the last correct one or the last lockout.
- `lockout: Countdown?` — time left before password checks are allowed again.
- `uninstalling: Bool` — set to `true` at the start of an uninstall so the watchdog does not reload the daemon.

### BlockedSite

- `domain: String` — the normalized base name the user asked for, for example `reddit.com`.
- `hosts: [String]` — the full expanded list of host names written to the hosts file, sorted and without duplicates.
- `pendingUnblock: Countdown?` — set when an unblock has been approved and is waiting. When it reaches zero the site is removed from `blocked`.

### Countdown

- `remainingSeconds: Double` — time left. The daemon subtracts real elapsed time (from Swift's `ContinuousClock`, which keeps counting while the Mac sleeps and ignores wall-clock changes) on every tick. It never goes below `0`.
- `totalSeconds: Double` — the length the countdown started with, for progress display.

A countdown stores time remaining rather than a finish time, because a finish time would be compared against the wall clock, which the user can change.

### PasswordHash

- `algorithm: String` — always `"pbkdf2-sha256"`.
- `iterations: Int` — `210000`.
- `salt: String` — 16 random bytes, Base64-encoded (Base64 is a way of writing binary bytes as plain text).
- `hash: String` — the 32-byte PBKDF2 output, Base64-encoded. PBKDF2 (password-based key derivation function 2) runs the password through SHA-256 hashing 210,000 times with the salt, which makes each guess slow.

### PendingDelayChange

- `newDelaySeconds: Int` — the shorter waiting period that will apply.
- `countdown: Countdown` — time left before it applies, starting at the waiting period that was current when the change was requested.

---

## Wire Protocol

The CLI and the app talk to the daemon over the Unix domain socket (a file-system path that two local programs connect through, like a network connection that never leaves the machine). Each connection carries exactly one request and one response, each a single line of JSON ending in `\n`. A request line of up to 65,536 bytes, not counting the newline, is accepted; anything longer is rejected with `badRequest`. The daemon waits at most 2 seconds for the request line, because clients send their one short line immediately after connecting.

### Request

`Request` is a JSON object with a `command` field and optional arguments:

- `command: String` — one of the commands listed below.
- `domain: String?`
- `password: String?`
- `newPassword: String?`
- `seconds: Int?`

### Response

- `ok: Bool` — `true` when the command succeeded.
- `error: String?` — a sentence a person can read, present when `ok` is `false`.
- `errorCode: String?` — a stable machine-readable code, present when `ok` is `false`. Codes: `badRequest`, `invalidDomain`, `notSetUp`, `alreadySetUp`, `wrongPassword`, `lockedOut`, `weakPassword`, `notBlocked`, `alreadyBlocked`, `nothingPending`, `invalidDelay`, `notRoot`, `notAllowed`, `tooManySites`, `internal`.
- `status: StatusSnapshot?` — present on every successful response, so clients can redraw after any command.
- `message: String?` — a short confirmation sentence, for example "reddit.com will unblock in 30 minutes."

### StatusSnapshot

- `version: String` — the daemon's version string.
- `passwordSet: Bool`
- `blocked: [BlockedSiteStatus]` — each with `domain`, `hosts`, and `unblockSecondsRemaining: Int?`.
- `delaySeconds: Int`
- `pendingDelay: PendingDelayStatus?` — with `newDelaySeconds` and `secondsRemaining`.
- `uninstallSecondsRemaining: Int?`
- `recoverySecondsRemaining: Int?`
- `lockoutSecondsRemaining: Int?`
- `hostsFileHealthy: Bool` — `true` when the last enforcement pass found or left the hosts file in the right state.

### Commands

Commands that make the Mac stricter never need a password. Commands that loosen anything need the password and then a wait.

- `status` — returns the snapshot. No password.
- `setup` (`password`) — sets the first password. Fails with `alreadySetUp` if one exists. Only root or the user logged in at the screen (the owner of `/dev/console`) may send it; anyone else gets `notAllowed`. This stops another account on the Mac from claiming the password first, either before the owner sets it or right after a recovery clears it.
- `add` (`domain`) — blocks a site at once. If the site is already blocked with an unblock pending, this cancels the unblock. Needs a password to be set up first (`notSetUp`), so that every block can later be undone.
- `unblock` (`domain`, `password`) — starts the unblock countdown for the site.
- `cancelUnblock` (`domain`) — stops a pending unblock. No password.
- `setDelay` (`seconds`, `password`) — longer applies at once and drops any pending change. Shorter starts a `PendingDelayChange`.
- `cancelDelayChange` — drops a pending shorter delay. No password.
- `changePassword` (`password`, `newPassword`) — replaces the password at once.
- `uninstall` (`password`) — starts the uninstall countdown: 48 hours, or the unblock delay if that is longer, so uninstalling is never a faster way to unblock everything than unblocking. Every site stays blocked until it ends.
- `cancelUninstall` — stops a pending uninstall. No password.
- `recoveryStart` — only accepted when the connecting process runs as root (uid 0), checked with the socket's `LOCAL_PEERCRED` option, which tells the daemon the user ID of the program on the other end. Starts the 48-hour recovery countdown. When it finishes the password is cleared and `setup` works again. Blocked sites stay blocked.
- `recoveryCancel` — stops a running recovery. No password.

---

## Fixed Policy Values

- Default unblock delay: 1800 seconds (30 minutes).
- Allowed delay range: 60 seconds to 604800 seconds (7 days).
- Recovery wait: 172800 seconds (48 hours).
- Uninstall wait: 172800 seconds (48 hours), or the unblock delay when that is longer.
- Minimum password length: 6 characters.
- Wrong-password limit: 5, then a lockout of 900 seconds (15 minutes).
- Most blocked sites: 500. A further `add` of a new site fails with `tooManySites`. Without a cap, any account on the Mac could add thousands of sites without a password, and the owner would need one password check and one wait per site to clear them.
- Enforcement tick: every 2 seconds.
- Watchdog check: every 5 seconds.
- State is saved to disk after every command and at least every 15 seconds while any countdown is running.

Sandbox mode (used by tests, see [04-infrastructure.md](04-infrastructure.md) § Sandbox Mode) can lower the delay floor, the recovery wait, the lockout length and the tick interval.

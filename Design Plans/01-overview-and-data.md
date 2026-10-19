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

Blocking a site is always free and instant. Unblocking a site needs the SiteBlock password, and even with the right password the site stays blocked for a waiting period (30 minutes by default) before it opens. During that wait anyone can cancel the unblock without a password. A site can also be unblocked for a chosen stretch of time, called a temporary unblock. It stays blocked while a start wait runs, which is never shorter than the unblock delay, then it opens for the chosen window, and then it is blocked again on its own.

---

## Requirements

1. Block any website the user chooses, in every browser, with special attention to Safari and Chrome.
2. Work at the system level rather than as a browser extension.
3. Keep sites blocked indefinitely until the user unblocks them.
4. Gate unblocking behind a password that belongs to SiteBlock and is separate from the Mac login password.
5. Be very hard to get around on impulse. That means the block repairs itself after hand edits, the service restarts itself after it is stopped, and the clock cannot be moved forward to skip a wait.
6. Make unblocking take effect only after a waiting period, so that even a successful bypass of the password costs time.
7. Never lock the user out permanently. A forgotten password can be reset with the Mac admin password plus a 48-hour wait.
8. Let a person open a blocked site, or a blocked part of a site, for a chosen window of time. It needs the password, it never opens sooner than the unblock delay, and it blocks itself again when the window ends.

---

## How Blocking Works

Every app on a Mac turns a site name such as `reddit.com` into a numeric server address before it connects. macOS checks the file `/etc/hosts` first, before asking any internet name server. SiteBlock writes lines such as `0.0.0.0 reddit.com` and `:: reddit.com` into that file. `0.0.0.0` (for the older IPv4 address format) and `::` (for the newer IPv6 format) are addresses that point nowhere, so the browser's connection fails immediately and the page does not load.

Chrome has its own name lookup code, including "Secure DNS" (looking up names over an encrypted HTTPS connection to a name server). Chrome still reads `/etc/hosts` before it uses Secure DNS: its resolver adds a hosts-file lookup step to every lookup in every Secure DNS mode (`HostResolverManager::CreateTaskSequence` in Chromium's `net/dns/host_resolver_manager.cc`), so the block applies to Chrome too. Safari uses the macOS system lookup, which reads `/etc/hosts`.

Some Chrome windows never ask the Mac to look a name up at all. A Chrome started with `--proxy-server=socks5://…` (for example a window used to reach a work dashboard through an SSH tunnel) hands each site name to the proxy, and the remote computer looks it up. So SiteBlock also writes Chrome's own block list. Chrome reads mandatory policies from `/Library/Managed Preferences`, a folder only root can write, and its `URLBlocklist` policy makes Chrome itself refuse every listed site and all its subdomains, in every window and profile, whatever proxy or lookup method is in use. `URLBlocklist` is not one of the "sensitive" policies Chrome ignores on Macs no company manages (only extension-install policies are). While any site is blocked, Chrome shows "Managed by your organization" in its menu; that label refers to this list.

**Other browsers.** Firefox, with its own DNS-over-HTTPS switched on, skips `/etc/hosts` entirely, and Chromium-based browsers other than Chrome keep their settings under their own names. So SiteBlock writes the same kind of protected policy for each of them (see [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer): Microsoft Edge (`com.microsoft.Edge`) and Brave (`com.brave.Browser`) get the Chrome keys, and Firefox (`org.mozilla.firefox`) gets `EnterprisePoliciesEnabled`, `DNSOverHTTPS` turned off and locked, and a `WebsiteFilter` block list. As a backstop, the hosts file always blocks the hostnames Firefox uses for DNS-over-HTTPS by default (`mozilla.cloudflare-dns.com`, `firefox.dns.nextdns.io`, `private.canadianshield.cira.ca`, `doh.xfinity.com`), so a browser that tries them anyway falls back to the Mac's own lookups or cannot load pages at all.

**Blocking part of a site (path rules).** Typing a site name alone (`youtube.com`) always blocks the whole site, exactly as before. A path rule exists only when a person asks to block part of a site: they type a path after the name, or paste a link and choose "Only this part". A path rule such as `youtube.com/shorts` blocks every address on that site (and its subdomains) whose path starts with `/shorts`, and leaves the rest of the site open. The hosts file can only block whole names, so path rules are enforced only through the browsers' own block lists: Chrome, Edge, Brave and Firefox. **Limits:** Safari cannot block part of a site (it has no block list SiteBlock can set without device management).

Browsers check their block lists when a page loads, but a site can switch to a new address inside a page that is already open, without loading a new page. YouTube does this when you tap a Short from the home page, using the browser's `history.pushState` feature (a way for a page to change the address bar without a page load). In Chrome, Edge and Brave the menu bar app catches such a switch within about half a second, once the person allows it to control the browser. While a path rule exists and one of those browsers is running, the app reads the address of every open tab twice a second using Apple Events (the macOS mechanism one app uses to ask another app for data or to perform an action). It reloads any tab whose address falls under a path rule, and because a reload is a real page load, the browser's block list then shows its block page. macOS asks for the permission the first time, and it appears under System Settings → Privacy & Security → Automation. Firefox gives SiteBlock no way to read its tabs, so in Firefox a switch inside an open page is caught only on the next reload or when the address is opened directly. Safari has no path rules at all. See [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher.

**Temporary unblock.** A site or a path rule can be opened for a chosen window of time and then blocked again without any further action. The site or rule stays on the block list the whole time; only what the daemon writes out changes. While the start wait runs (the time before the window opens), the site is blocked as usual. While the window is open, the daemon leaves that site's host names out of the hosts file, except for a name that another blocked site still needs, and leaves that site out of the browsers' block lists. A path rule whose own temporary unblock is open is left out of those lists too, but a path rule on a site whose whole site is open stays in them, because that rule is what keeps that part of the site blocked. When the window ends, the next enforcement pass writes everything back. A temporary unblock never changes the adult content filter, because it applies only to sites and path rules on the person's own block list. The rules are in [02-core-components.md](02-core-components.md) § Engine.

**Adult content filter.** SiteBlock always blocks adult websites, including ones that are not on the block list. This is part of its core blocking, not a setting: there is no command, password or wait that turns it off, and only uninstalling SiteBlock removes it. It works in two layers. First, the Chrome policy file also gets `SafeSitesFilterBehavior` = 1 (Chrome checks each top-level page against Google's adult-content classification and refuses flagged ones), `ForceGoogleSafeSearch` = true (Google Search always uses SafeSearch), and `DnsOverHttpsMode` = "off" (Chrome uses the Mac's own name lookups, so the second layer reaches it). Second, every network service's DNS servers (the servers that turn site names into addresses) are set to Cloudflare for Families, which refuses to look up adult sites: `1.1.1.3`, `1.0.0.3`, `2606:4700:4700::1113`, `2606:4700:4700::1003`. VPN services are left alone, because a VPN supplies its own DNS servers; that is a known limit. Because of this layer the Private Relay names are always blocked, even with no sites on the block list, since Private Relay would otherwise send Safari's lookups to Apple instead of the family servers.

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

The menu bar app also talks to the running Chrome, Edge and Brave processes for its tab watcher. That traffic is Apple Events between the app and each browser, in the user's own login session, and it does not pass through the daemon or the socket.

---

## Threat Model and Honest Limits

SiteBlock defends against the owner of the Mac acting on impulse. It does not defend against a determined administrator with time. Every step that loosens a block costs either the SiteBlock password or a waiting period, and most cost both.

**What SiteBlock stops:**

- Editing `/etc/hosts` by hand. The daemon rewrites its section within two seconds, and it also removes lines elsewhere in the file that point a blocked name at a real address (because macOS uses the first matching line, such a line would otherwise win).
- Unloading the daemon or the watchdog. Each one reloads the other.
- Deleting or trashing the menu bar app, quitting it, or unloading its startup entry. The daemon puts the app back from a root-owned backup and relaunches it within 5 seconds, and launchd restarts it whenever it exits. (The app is only the window; blocking never depended on it.)
- Deleting the daemon's plist (its `launchd` configuration file) or its program file. The watchdog writes the plist again from a copy built into its own program and copies the program back from a backup location.
- Deleting or editing the state file. The running daemon writes it back from memory within one tick, and a daemon that starts with no state file reads a backup copy kept in a second folder.
- Changing the Mac's DNS servers while the adult filter is on. SiteBlock is notified of the change and sets the family servers again within about a second.
- Moving the system clock forward. Countdowns are measured with a monotonic clock (a counter that only moves forward with real elapsed time and ignores the wall clock).
- Guessing the password with a script. Five wrong passwords lock password checks for 15 minutes.
- Shortening the waiting period on impulse. Making the wait longer applies at once. Making it shorter has to sit through the current wait first.
- Opening a site early through a temporary unblock. Its start wait is never shorter than the unblock delay, it needs the password, and the site stays fully blocked until the start wait ends.

**What SiteBlock cannot stop:**

- A root user who unloads both background jobs at the same moment and then deletes their files. No program can fully defend against root on its own machine. The strongest setup is to use a standard (non-administrator) macOS account day to day and give the administrator password to someone else; then none of the root-level bypasses are available on impulse.
- A root user who stops the daemon (for example with `kill -9`) and edits or deletes `state.json` and its backup before launchd restarts it. The restarted daemon trusts what it finds on disk, so a forged countdown or an empty state takes effect. Freezing both jobs with `pkill -STOP` is the same kind of root-level bypass. So is switching both jobs off under System Settings → General → Login Items & Extensions → "Allow in the Background", which asks for the administrator password; SiteBlock clears a `launchctl disable` mark before reloading a job, but it cannot overrule that switch if macOS does not let it.
- A VPN (a service that tunnels all traffic through another computer) or a proxy that does name lookups on the remote side.
- Tabs that were already connected to a site before it was blocked. Browsers reuse open connections for a short time, so an already-open page may keep loading until the browser closes that connection. Reloading after a minute or two shows the block.
- A person who refuses the Automation permission. If the person answers "Don't Allow" when macOS asks whether SiteBlock may control a browser, or turns the permission off later under System Settings → Privacy & Security → Automation, the tab watcher does nothing for that browser. Path rules there are applied only when a page loads, which means on a reload or when the address is opened directly. The menu bar app shows a banner while a path rule exists and a running browser has refused.
- A blocked part of a site that shows for a moment. The tab watcher checks twice a second, so the part of the site can be visible for up to about half a second before the tab reloads.
- A part of a site that opens without a page load in Firefox. SiteBlock cannot read Firefox's tabs, so only a reload or a direct open applies the path rule there. Safari has no path rules.

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
- `blockedPaths: [BlockedPath]?` — every path rule, in the order added. **Optional in the file** (an older `state.json` without it decodes as no path rules).
- `savedDNS: [String: [String]]?` — **optional in the file:** a `state.json` written before this field existed has no such key, and it must decode as `nil` rather than being treated as corrupt (which would discard the block list). For each network service (keyed by its SystemConfiguration service ID) it holds the DNS server addresses the service had before SiteBlock replaced them; an empty array means the service had none set by hand (it used whatever the network provided). Written the first time SiteBlock overrides a service and used only by the uninstaller, to put the originals back.

### BlockedSite

- `domain: String` — the normalized base name the user asked for, for example `reddit.com`.
- `hosts: [String]` — the full expanded list of host names written to the hosts file, sorted and without duplicates.
- `pendingUnblock: Countdown?` — set when an unblock has been approved and is waiting. When it reaches zero the site is removed from `blocked`.
- `temporaryUnblock: TemporaryUnblock?` — set while a temporary unblock of the site is waiting or open. **Optional in the file:** a `state.json` without the key decodes as `nil`, and a missing key must never make the file count as corrupt, because that would discard the block list. When the temporary unblock finishes it is removed and the site stays in `blocked`.

### BlockedPath

- `domain: String` — the normalized base domain, for example `youtube.com`.
- `path: String` — the path prefix, starting with `/`, for example `/shorts`. Case is kept, because paths are case-sensitive.
- `pendingUnblock: Countdown?` — set while an approved unblock waits; when it reaches zero the rule is removed.
- `temporaryUnblock: TemporaryUnblock?` — the same as on `BlockedSite`, for this rule. Optional in the file, and the rule stays in `blockedPaths` when the temporary unblock finishes.

### Countdown

- `remainingSeconds: Double` — time left. The daemon subtracts real elapsed time (from Swift's `ContinuousClock`, which keeps counting while the Mac sleeps and ignores wall-clock changes) on every tick. It never goes below `0`.
- `totalSeconds: Double` — the length the countdown started with, for progress display.

A countdown stores time remaining rather than a finish time, because a finish time would be compared against the wall clock, which the user can change.

### TemporaryUnblock

A temporary unblock holds the time left before the site opens and how long the site stays open. It is stored as two countdowns that hold time remaining, because a finish time would be compared against the wall clock, which the user can change.

- `startsIn: Countdown` — time left before the site opens. It starts at the chosen start wait.
- `window: Countdown` — how long the site stays open. It starts counting down only after `startsIn` reaches `0`, and its `totalSeconds` is the chosen window length.
- `isOpen: Bool` (computed, not stored) — `true` when `startsIn.remainingSeconds <= 0` and `window.remainingSeconds > 0`.
- `isFinished: Bool` (computed, not stored) — `true` when both `startsIn.remainingSeconds <= 0` and `window.remainingSeconds <= 0`.

A temporary unblock is waiting while `startsIn` is above `0`, open while `isOpen` is `true`, and removed from its site or rule as soon as it is finished. A site or path rule has at most one unblock of either kind at a time: the commands never set `temporaryUnblock` on an entry that has a `pendingUnblock`, and never set `pendingUnblock` on an entry that has a `temporaryUnblock`.

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
- `seconds: Int?` — the new delay for `setDelay`, and the window length (how long the site stays open) for `temporaryUnblock` and `temporaryUnblockPath`.
- `startSeconds: Int?` — the start wait (the time before the site opens) for a temporary unblock. When it is missing, the start wait is the unblock delay.

### Response

- `ok: Bool` — `true` when the command succeeded.
- `error: String?` — a sentence a person can read, present when `ok` is `false`.
- `errorCode: String?` — a stable machine-readable code, present when `ok` is `false`. Codes: `badRequest`, `invalidDomain`, `notSetUp`, `alreadySetUp`, `wrongPassword`, `lockedOut`, `weakPassword`, `notBlocked`, `alreadyBlocked`, `nothingPending`, `invalidDelay`, `notRoot`, `notAllowed`, `tooManySites`, `invalidPath`, `invalidDuration`, `alreadyPending`, `internal`. `invalidDuration` means the window or the start wait of a temporary unblock is outside its allowed range. `alreadyPending` means the site or rule already has an unblock of either kind.
- `status: StatusSnapshot?` — present on every successful response, so clients can redraw after any command.
- `message: String?` — a short confirmation sentence, for example "reddit.com will unblock in 30 minutes."

### StatusSnapshot

- `version: String` — the daemon's version string.
- `passwordSet: Bool`
- `blocked: [BlockedSiteStatus]` — each with `domain`, `hosts`, `unblockSecondsRemaining: Int?` and `temporaryUnblock: TemporaryUnblockStatus?`.
- `delaySeconds: Int`
- `pendingDelay: PendingDelayStatus?` — with `newDelaySeconds` and `secondsRemaining`.
- `uninstallSecondsRemaining: Int?`
- `recoverySecondsRemaining: Int?`
- `lockoutSecondsRemaining: Int?`
- `hostsFileHealthy: Bool` — `true` when the last enforcement pass found or left the hosts file in the right state.
- `blockedPaths: [BlockedPathStatus]?` — each with `domain`, `path`, `rule` (the two joined, as shown to people, for example `youtube.com/shorts`), `unblockSecondsRemaining: Int?` and `temporaryUnblock: TemporaryUnblockStatus?`. Decoded as empty when missing.
- `adultFilterEnabled: Bool?` — always `true` from a daemon that has the adult filter (decoded as `false` when missing, for an older daemon).

### TemporaryUnblockStatus

`BlockedSiteStatus.temporaryUnblock` and `BlockedPathStatus.temporaryUnblock` are `nil` when the site or rule has no temporary unblock, and they decode as `nil` when the key is missing, for an older daemon. Otherwise they hold:

- `opensInSeconds: Int?` — seconds until the site opens, rounded up; `nil` once it is open.
- `secondsRemaining: Int` — while waiting, the full window length; while open, the seconds left in the window, rounded up.
- `windowSeconds: Int` — the chosen window length.
- `isOpen: Bool` — `true` while the site is open.

### Commands

Commands that make the Mac stricter never need a password. Commands that loosen anything need the password and then a wait.

- `status` — returns the snapshot. No password.
- `setup` (`password`) — sets the first password. Fails with `alreadySetUp` if one exists. Only root or the user logged in at the screen (the owner of `/dev/console`) may send it; anyone else gets `notAllowed`. This stops another account on the Mac from claiming the password first, either before the owner sets it or right after a recovery clears it.
- `add` (`domain`) — blocks a site at once. If the site is already blocked with an unblock pending, this cancels the unblock. If the site has a temporary unblock, waiting or open, `add` clears it in the same way and the site is blocked again at once. Needs a password to be set up first (`notSetUp`), so that every block can later be undone.
- `unblock` (`domain`, `password`) — starts the unblock countdown for the site. Fails with `alreadyPending` when the site has a temporary unblock, and that check comes before the password check.
- `addPath` (`domain` holds the whole rule text, for example `youtube.com/shorts` or `https://www.youtube.com/shorts/abc`) — adds a path rule at once. No password. Fails `invalidDomain` or `invalidPath` when the text cannot be parsed, `alreadyBlocked` when the same rule exists or the whole site is already blocked, `notSetUp` when no password exists, and `tooManySites` when sites plus path rules would exceed the cap. Re-adding a rule that is waiting to unblock cancels the unblock, and re-adding a rule that has a temporary unblock clears it, like `add`.
- `unblockPath` (`domain` = rule text, `password`) — starts the unblock countdown for that rule, with the same password and delay rules as `unblock`; `notBlocked` when no such rule exists, and `alreadyPending` when the rule has a temporary unblock.
- `temporaryUnblock` (`domain`, `password`, `seconds`, optional `startSeconds`) — schedules a temporary unblock of a blocked site. `seconds` is the window and `startSeconds` is the start wait. The site stays fully blocked during the start wait, is open for exactly the window, and is blocked again when the window ends. It fails with `badRequest` when `domain`, `password` or `seconds` is missing; `invalidDomain`; `notBlocked`; `alreadyPending` when the site already has an unblock of either kind; and `invalidDuration` when the window or the start wait is out of range. All of those checks come before the password check, so a request that fails one of them never counts as a wrong password. [02-core-components.md](02-core-components.md) § Engine gives the order of the checks.
- `temporaryUnblockPath` (`domain` = rule text, `password`, `seconds`, optional `startSeconds`) — the same as `temporaryUnblock`, for a path rule. It fails `invalidDomain` or `invalidPath` when the rule text cannot be parsed, and `notBlocked` when no such rule exists.
- `cancelUnblockPath` (`domain` = rule text) — stops a pending path-rule unblock. When there is no pending unblock, it clears the rule's temporary unblock: a waiting one is cancelled and an open one ends at once. No password.
- `cancelUnblock` (`domain`) — stops a pending unblock. When there is no pending unblock, it clears the site's temporary unblock in the same way. No password.
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
- Temporary unblock window (how long the site stays open): 300 seconds (5 minutes) to 14400 seconds (4 hours).
- Temporary unblock start wait (the time before the site opens): at least the current unblock delay and at most 604800 seconds (7 days). It is the unblock delay when none is given.
- Minimum password length: 6 characters.
- Wrong-password limit: 5, then a lockout of 900 seconds (15 minutes).
- Adult-filter DNS servers: `1.1.1.3`, `1.0.0.3`, `2606:4700:4700::1113`, `2606:4700:4700::1003` (Cloudflare for Families).
- Most blocked sites: 500, counting sites and path rules together. A further `add` of a new site fails with `tooManySites`. Without a cap, any account on the Mac could add thousands of sites without a password, and the owner would need one password check and one wait per site to clear them.
- Enforcement tick: every 2 seconds.
- Watchdog check: every 5 seconds.
- Tab watcher check: every 0.5 seconds, and only while a path rule exists and Chrome, Edge or Brave is running.
- Recheck of a refused Automation permission: at most every 10 seconds per browser.
- State is saved to disk after every command and at least every 15 seconds while any countdown is running. A temporary unblock counts as a running countdown from the moment it is scheduled until it ends, and the state is also saved at once when it opens and when it ends.

Sandbox mode (used by tests, see [04-infrastructure.md](04-infrastructure.md) § Sandbox Mode) can lower the delay floor, the recovery wait, the lockout length, the shortest temporary unblock window and the tick interval.

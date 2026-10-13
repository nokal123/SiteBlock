# Implementation Log

The user set an autonomous overnight goal on 2026-10-06 ("make the decisions yourself from now on") and was away while every chunk below was built. The comprehension gate could not run during that time, so each chunk is recorded with its gate **pending**. Before any new implementation work starts, each pending gate must be cleared in order: the user explains the chunk in their own words, and the explanation is cross-referenced against the code.

---

## 2026-10-06 — Chunk 1: SiteBlockCore library

**Implemented:**
- `Sources/SiteBlockCore/DomainNormalizer.swift`, `Punycode.swift`, `DomainExpander.swift` turn typed text into a canonical site name and expand it into every host name to block.
- `Sources/SiteBlockCore/HostsFileEditor.swift` is a pure function that rewrites hosts-file text to contain exactly the managed section and no bypass lines.
- `Sources/SiteBlockCore/PasswordHasher.swift` uses PBKDF2-SHA256 with 210,000 rounds and a random salt.
- `Sources/SiteBlockCore/Engine.swift` holds all policy: commands, password lockout, countdowns driven by elapsed time.
- `Sources/SiteBlockCore/StateStore.swift`, `Models.swift`, `Protocol.swift`, `DaemonClient.swift`, `Formatting.swift`, `Paths.swift`.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-06 — Chunk 2: siteblockd daemon, watchdog and siteblock CLI

**Implemented:**
- `Sources/siteblockd/` contains the root daemon (socket server, hosts enforcement every 2 s, state self-repair), the watchdog mode, the launchd plist generator and the uninstaller.
- `Sources/siteblock/` contains the Terminal command, which talks to the daemon over `/var/run/siteblock.sock`.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-06 — Chunk 3: SiteBlock.app menu bar app

**Implemented:**
- `Sources/SiteBlockApp/` is a SwiftUI menu bar panel with these screens: setup, block list, unblock with password, countdown, banners, settings.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-07 — Chunk 4: Build, install and verification scripts

**Implemented:**
- `scripts/build.sh`, `scripts/install.sh`, `scripts/verify-install.sh`, `Install SiteBlock.command`, `Resources/Info.plist`.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-07 — Chunk 5: Hardening after code review

**Implemented:**
- A site cap of 500, setup limited to root or the console user, per-user connection limits, a 2 s socket timeout, and a socket created through umask.
- Hosts parsing that reads lines the way the macOS resolver does (NUL, trailing dot), and END markers that pair with the nearest BEGIN.
- Clearing of immutable flags, random temp names and an in-place write fallback in `HostsEnforcer`.
- The watchdog no longer stands down for a missing folder, and the uninstall boots out the watchdog first.
- Flood-controlled logging with newsyslog rotation.
- `scripts/dev-force-remove.sh` was removed.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-07 — Chunk 6: Private Relay guard, system-name guard, launchctl enable

**Implemented:**
- `Sources/SiteBlockCore/Engine.swift`: `hostsToWrite` adds `mask.icloud.com` and `mask-h2.icloud.com` while any site is blocked. This is Apple's documented signal that turns iCloud Private Relay off, so Safari's lookups go through `/etc/hosts`.
- `Sources/SiteBlockCore/HostsFileEditor.swift`: never writes `localhost`, `broadcasthost`, or names ending in `.local` or `.localhost`.
- `Sources/siteblockd/LaunchdGuard.swift`: runs `launchctl enable` before re-bootstrapping a job.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-07 — Chunk 7: Countdown catch-up before commands; core extraction

**Implemented:**
- `Sources/siteblockd/DaemonRuntime.swift`: every command first advances all countdowns using the shared clock reading. Before this, a countdown started between two ticks could finish up to one tick (2 s) early.
- `Sources/SiteBlockCore/ConnectionLimiter.swift` and `UninstallRule.swift` were moved out of the daemon so unit tests can reach them.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-11 — Chunk 8: Chrome URLBlocklist policy; named-pipe safety

**Implemented:**
- `Sources/SiteBlockCore/ChromePolicy.swift` and `Sources/siteblockd/ChromePolicyEnforcer.swift` write the blocked sites into Chrome's mandatory `URLBlocklist` in `/Library/Managed Preferences/com.google.Chrome.plist` and `/Library/Managed Preferences/<console user>/com.google.Chrome.plist`, repaired every pass. This was the fix for a Chrome window started with `--proxy-server=socks5://127.0.0.1:1080`, which resolved names through an SSH tunnel and bypassed `/etc/hosts`.
- The list is shortened to covering parent domains, staying under Chrome's 1,000-entry limit.
- `HostsEnforcer` and `ChromePolicyEnforcer` open their files with `O_NONBLOCK`, so a named pipe planted at either path can no longer freeze the daemon.
- Verified on the live system: headless Chrome with a blank profile gets `ERR_BLOCKED_BY_ADMINISTRATOR` for youtube.com, both directly and through the SOCKS proxy.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-13 — Chunk 9: Tab watcher for in-page switches; idle panel redraw fix

**Implemented:**
- `Sources/SiteBlockCore/TabRuleMatcher.swift`: decides whether a tab address falls under a path rule, the same way the browsers' block lists do (http/https only, the rule's site or a subdomain, a case-sensitive path prefix; hosts holding `/ ? # @ :` or whitespace after decoding are refused).
- `Sources/SiteBlockCore/TabReloadDecider.swift`: remembers which tab was reloaded at which address, so each tab is reloaded once per arrival on a blocked part and never in a loop; a repeated tab id is handled by its first appearance.
- `Sources/SiteBlockApp/ChromiumTabs.swift`: Apple Events to each Chrome, Edge and Brave process by process id (read window ids, tab ids and addresses; re-read one tab; reload one tab; check the Automation permission).
- `Sources/SiteBlockApp/TabWatcher.swift`: every 0.5 s while a path rule exists, reads the tabs, reloads the ones that moved onto a blocked part without loading, holds an App Nap activity while rules exist, and reports browsers that refused permission.
- `StatusModel.swift`, `BannersView.swift`, `Resources/Info.plist`: rules fed to the watcher, a permission banner, and the Automation usage text.
- `StatusModel.applyStatus`: an answer identical to the shown snapshot is not re-published (idle open panel went from about 5% CPU to 0%).
- Tests: TabRuleMatcherTests, TabReloadDeciderTests; integration log-count waits that fixed the flaky PrivateRelay test; CI annotations for failed tests.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

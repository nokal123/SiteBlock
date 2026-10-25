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

## 2026-10-22 — Windows: guard hardening, and the Windows workflow green end to end

**Implemented:**
- Guards (`windows/src/SiteBlock.Service`): hosts takeover with the take-ownership privilege and owner-then-access-list order; an unreadable hosts file is never treated as empty; a byte-preserving read and write of the hosts file; a re-read before each write so a concurrent save is not lost; a whole-folder program restore; service type, account and dependency repair read from the registry; folder owners and per-file access lists of the state files; a capped, path-checked tray app restart.
- Service and pipe: a connection slot is freed before the reply is written; the 2-second request limit counts from accept; at most 4 hang-up waits per account; the DNS guard takes only adapters with TCP/IP settings of their own; sandbox reads with full file sharing.
- Updater: the elevated script sets PSModulePath to Windows PowerShell's own folders (it failed with "Get-FileHash not recognized").
- Tray app: Chrome 155's reload button offers no UI Automation Invoke, so it is pressed through MSAA (hit test at its centre, role and position checks, default action); a failed reload is retried 5 s later, at most 3 tries per address; the tab reader logs counts and control names only.
- Tests and CI: the e2e checks were corrected (lockout wording, lookup rule on Windows, tray app found by session and path, real page instead of about:blank) and report raw details on the public run page; flaky timing bounds were replaced with order checks or design-based margins; 98 new tests, audited (20 mutants, 17 killed, none a source bug) and tightened in one fix round.
- Result: GitHub's Windows run green four times in a row (109f00e, 0773b54, 368c397, b726562): all test projects, the package, and 27/27 end-to-end checks.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

## 2026-10-25 — Family DNS: CleanBrowsing Family, chosen in one built-in providers file

**Implemented:**
- `Sources/SiteBlockCore/FamilyDNSProviders.json` lists the known family DNS services (CleanBrowsing Family Filter, Cloudflare for Families, AdGuard DNS Family Protection) and names the active one, `cleanbrowsing-family`. The Mac embeds it in SiteBlockCore and the Windows build embeds the same file in SiteBlock.Core, so switching means changing `active` and releasing; nothing on the installed computer can change it.
- Both parsers check the same rules: ids not empty or repeated, `active` names a provider, two IPv4 and two IPv6 addresses each in standard form. Windows also rejects a file that is not a JSON object and an address with a zone index.
- The DNS enforcers treat any known provider's list as family servers, so after a switch a service on the previous provider is moved to the new one and keeps its real original; the reachability probe checks the active provider's IPv4 pair. On Windows an adapter is given only the address families it has.
- Tests: 44 new tests on both platforms, audited (17 mutants, 14 killed; the two real survivors were closed in one fix round and confirmed killed). Mac 1393 tests pass; Windows core 210 pass.

**User's summary:**
> Gate waived for this project (user decision, 2026-10-13).

**Gaps found:**
- Not assessed (gate waived).

**Resolution:**
- Waived: the user turned comprehension gates off for SiteBlock.

---

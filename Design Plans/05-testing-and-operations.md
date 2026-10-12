# Testing and Operations
> Part of the SiteBlock Design Plans
> See also: [02-core-components.md](02-core-components.md), [04-infrastructure.md](04-infrastructure.md)

## Table of Contents
1. [Testing Strategy](#testing-strategy)
2. [Unit Tests](#unit-tests)
3. [Integration Tests](#integration-tests)
4. [Installed-System Verification](#installed-system-verification)
5. [Security Considerations](#security-considerations)
6. [Operations](#operations)
7. [Success Criteria](#success-criteria)

---

## Testing Strategy

Tests are written with Swift Testing (`import Testing`, `@Test`, `#expect`) and run with `scripts/test.sh`. Expected values come from this design, never from reading the implementation. There are three layers:

1. **Unit tests** call `SiteBlockCore` directly. The `Engine` is driven with fake elapsed time, so a 30-minute countdown is tested in microseconds.
2. **Integration tests** start the real `siteblockd` program in sandbox mode as a child process, talk to it over its real socket with `DaemonClient` and the real `siteblock` CLI, and read the sandbox hosts file from disk.
3. **Installed-system verification** (`scripts/verify-install.sh`) runs after a real install and checks the real `/etc/hosts`, the real name lookup, and real connections. A separate live test drives a real Chrome to check the tab watcher.

There are no mocks of the socket, the file system or the hosts editor. The only stand-in is fake elapsed time in unit tests. The Apple Events code in `Sources/SiteBlockApp/ChromiumTabs.swift` needs a running browser and a macOS permission prompt, so it is covered only by the live tab-watcher test.

---

## Unit Tests

`Tests/SiteBlockCoreTests/`:

- **DomainNormalizerTests:** URLs with scheme, path, query, fragment, port, user info; uppercase; trailing dot; `www.` stripping; Unicode names to Punycode; IPv4 and IPv6 rejection; single-label names; labels of 63 and 64 characters; a 253-character and a 254-character name; leading and trailing hyphens; underscores and spaces; `localhost`, `printer.local`; empty and whitespace-only input.
- **PunycodeTests:** the RFC 3492 § 7.1 sample strings that are plain labels, plus `bücher` → `bcher-kva`, `münchen` → `mnchen-3ya`, and an all-ASCII label returned unchanged by `toASCII`.
- **DomainExpanderTests:** a plain domain gets exactly the base plus the eight prefixes; `reddit.com` includes `redd.it`, `www.redd.it` and `i.redd.it`; the output is sorted with no duplicates; `x.com` and `twitter.com` both cover each other.
- **HostsFileEditorTests:** the default macOS hosts file gains a section and keeps its own lines; rendering twice gives the same text; an empty block list removes the section; a hand-edited section is replaced; two sections collapse to one; an orphan BEGIN with no END removes only that line; a stray END is removed; a user line `1.2.3.4 reddit.com other.com` becomes `1.2.3.4 other.com`; a user line that only names blocked hosts is dropped; comments that mention a blocked host are kept; `\r\n` input; tabs between fields; a file with no trailing newline.
- **PasswordHasherTests:** right and wrong passwords; two hashes of the same password differ (random salt); a hash with a changed iteration count, bad Base64, or unknown algorithm fails verification; Unicode and space-padded passwords; the minimum-length rule.
- **EngineTests:** every command's success and failure codes from [02-core-components.md](02-core-components.md) § Engine; unblock finishes only after the full delay and not one tick earlier; a second `unblock` does not restart the countdown; `add` cancels a pending unblock; delay increase is immediate and decrease waits for the old delay; five wrong passwords lock out and a correct password during lockout is still refused; lockout ends after its time; recovery is refused for non-root, and after finishing clears the password but keeps blocks; uninstall calls `onUninstall` exactly once; negative, NaN and infinite elapsed values change nothing; JSON round-trip of the full state.
- **FormattingTests:** each duration and clock example from [02-core-components.md](02-core-components.md) § Formatting, and `parseDuration` on valid and invalid input.
- **TabRuleMatcherTests** (expected values from [02-core-components.md](02-core-components.md) § TabRuleMatcher, using a rule such as `youtube.com` with `/shorts`):
  - Schemes: `http` and `https` match, in any letter case; `chrome:`, `about:`, `file:`, `data:`, `javascript:`, `ftp:` and an address with no scheme do not match.
  - Hosts: the rule's own domain, a `www.` form, a one-level subdomain and a deeper subdomain match; look-alike suffixes such as `notyoutube.com` and `youtube.com.example.com` do not; a trailing dot and capital letters are accepted; a Unicode host matches a rule stored in its Punycode form; an IPv4 address, an IPv6 literal and an empty host do not match.
  - Port and user info: a port number is ignored; user info is ignored, and an address such as `https://youtube.com@other.com/shorts` is judged by `other.com`, so it does not match.
  - Paths: `/shorts`, `/shorts/`, `/shorts/abc` and `/shortsXYZ` match because the comparison is a plain prefix; `/short`, `/watch`, `/a/shorts` and `/` do not; `/Shorts` does not because the comparison is case-sensitive; an address with no path counts as `/` and does not match; a percent-encoded path is compared in its encoded form.
  - Query and fragment: `/shorts?x=1#t` matches; `/?next=/shorts` and `/#/shorts` do not.
  - Unparseable text: an empty string, a host with a space in it, and a malformed address give no match and do not crash. A raw space in the path is percent-encoded by the parser and compared in its encoded form.
  - `matchingRule`: the first matching rule in list order is returned when several match, `nil` comes back for an empty list and when none match, and a rule for a different domain later in the list is found.
- **TabReloadDeciderTests** (expected values from [02-core-components.md](02-core-components.md) § TabReloadDecider):
  - A tab on a blocked address is returned once, and an identical second call returns nothing while `remembered` still holds the address.
  - A tab that leaves the blocked part (memory dropped) and comes back is returned again.
  - A tab that moves from one blocked address to a different blocked address is returned again.
  - Tabs that do not match are never returned and are not remembered; several matching tabs are returned together in input order.
  - Memory is per process: the same tab ID in two processes is tracked separately, and a call for one process leaves the other's memory unchanged.
  - A tab ID missing from the list loses its memory, so the same tab reappearing on the same blocked address is returned again.
  - With an empty rule list nothing is returned and that process's memory is cleared, while other processes keep theirs.
  - `forgetProcesses(except:)` drops the memory of processes outside the set and keeps the rest; `forgetAll()` drops everything.

---

## Integration Tests

`Tests/IntegrationTests/` builds on a helper that:
1. creates a sandbox folder under `/tmp` with a short random name and writes a starting `hosts` file containing the standard macOS lines,
2. starts `.build/debug/siteblockd --daemon --sandbox <dir> --tick 0.2 --policy-fast`,
3. waits up to 5 seconds for the socket to exist,
4. stops the process and deletes the folder when the test ends.

Tests:
- Set up a password, add `reddit.com`, and see `0.0.0.0 reddit.com` and `0.0.0.0 i.redd.it` in the sandbox hosts file before the `add` response returns.
- Delete the managed section from the sandbox hosts file by hand and see it restored within 1 second.
- Add a bypass line `151.101.1.140 reddit.com` at the top of the hosts file and see it removed.
- Unblock with the wrong password fails; with the right password the site stays in the hosts file until the delay passes (2 seconds with a delay of 2), then disappears.
- Kill the daemon with `SIGKILL` during an unblock countdown, restart it, and see the countdown continue from where it was at the last save (after the last command, or at most 15 seconds earlier) rather than restart or finish early.
- Send a request over 64 KB and get `badRequest`; send invalid JSON and get `badRequest`; open a connection and send nothing, and see it receive `badRequest` after the 2-second read timeout while the daemon keeps answering other clients.
- Ten clients each add a different domain, with no more than three in flight at a time because of the 4-connections-per-user limit; all ten end up blocked. A fifth simultaneous connection from one user is closed without a reply, and the slot frees up once a connection ends.
- Adding a 21st site under `--policy-fast` gives `tooManySites`.
- Deleting or overwriting `state.json` while the daemon runs is repaired within about 1 second with the blocks kept. After `SIGKILL`, a missing `state.json` is restored from `state.backup.json`.
- A hand-set `uninstalling: true` without a finished uninstall countdown is ignored on restart; with a finished countdown the uninstall runs.
- `add youtube.com` puts the `0.0.0.0` and `::` lines for every expanded YouTube name into the hosts file before the response returns.
- While any site is blocked the section also holds `mask.icloud.com` and `mask-h2.icloud.com` exactly once each; they leave with the last unblocked site; a user line naming them is stripped while a site is blocked and left alone when nothing is blocked.
- Hostile domain strings sent as raw JSON (newlines, `#`, spaces, control characters) never add a line to the hosts file.
- A lockout survives a daemon restart.
- Passwords and domains never appear in the log; a flood of rejected requests produces summary lines, not one line per request.
- `--tick` or `--policy-fast` without `--sandbox` exits with code 64.
- `recoveryStart` from a non-root test process returns `notRoot`.
- Run the real `siteblock` CLI with `SITEBLOCK_SOCKET` set: `status`, `add`, `unblock` with the password piped on standard input, and the exit codes from [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI, including exit code 2 when no daemon is running.
- Uninstall in sandbox mode: after the uninstall wait (2 seconds under `--policy-fast`, where both the minimum and the delay are 2), the hosts section is gone and the daemon exits with code 0.

---

## Installed-System Verification

`scripts/verify-install.sh` runs as the normal user after `sudo scripts/install.sh`. It never asks for a SiteBlock password and never blocks anything on its own: the password is chosen at the first block. Checks 1 and 2 and the hosts-health check always run. The blocking checks (3 to 7) run only when `youtube.com` is already blocked; otherwise each prints SKIP with the sentence "Block youtube.com from the menu bar icon, then run scripts/verify-install.sh again." After the user blocks youtube.com, running the script again performs every check.

Checks:
1. Both launchd jobs are loaded (`launchctl print system/<label>`).
2. `siteblock status` succeeds.
3. `siteblock status` lists `youtube.com` as blocked.
4. `/etc/hosts` contains `0.0.0.0 youtube.com`, `0.0.0.0 www.youtube.com`, `0.0.0.0 m.youtube.com` and `0.0.0.0 youtu.be`.
5. `dscacheutil -q host -a name www.youtube.com` returns `0.0.0.0` (the macOS system lookup that Safari uses).
6. `curl --max-time 5 https://www.youtube.com` fails to connect.
7. Real browsers: the script opens `https://www.youtube.com` in Safari and in Chrome. It then reads each browser's current page through AppleScript where the browser allows it, and otherwise prints instructions so the person can confirm by eye that each shows a "can't connect" page.

### Live tab-watcher test

The tab watcher cannot be checked by `scripts/verify-install.sh`, because it needs a browser tab that changes address without loading a page. It has a manual harness that the main session runs against a built app:

1. A sandbox daemon runs with one path rule (for example `youtube.com/shorts`).
2. The built `SiteBlock.app` starts with `SITEBLOCK_SOCKET` pointing at that sandbox daemon, so the watcher receives the sandbox's path rules. macOS shows the Automation prompt the first time, and the test needs it answered with Allow.
3. A separate, visible Chrome instance is driven over the Chrome DevTools Protocol (the remote-control interface Chrome offers when started with a debugging port). It loads an ordinary page, then calls `history.pushState` to move the same tab onto the blocked path without a page load. A second tab on an unblocked address is open for comparison.

The test passes when the watcher reloads the first tab exactly once and leaves the other tabs alone. The sandbox daemon does not write the real managed preferences, so the check is on the reload, not on Chrome's block page.

---

## Security Considerations

- The socket is world-writable on purpose, so the logged-in user's app can reach the root daemon. Every command that loosens a block needs the password, and the password checks are rate-limited, so access to the socket alone gains nothing but the ability to add blocks.
- The daemon never runs anything built from client input. Domain strings are validated to `a–z 0–9 - .` before they reach the hosts file, so a request cannot inject extra lines or other host entries.
- `state.json` is mode `0600` root-only, so other users cannot read the password hash.
- The password is never logged, never written to disk in plain form, and not kept in memory after the check beyond the lifetime of the request.
- `recoveryStart` uses the kernel-reported peer user ID, which the client cannot fake.
- The tab watcher sends Apple Events only to browser processes the person has allowed under the Automation permission. It reads window IDs, tab IDs and tab addresses, and its only command is a tab reload. Its log lines name the rule that matched, not the tab's full address.

---

## Operations

- Logs: `/Library/Logs/SiteBlock/siteblockd.log` and `watchdog.log`. Look for "hosts file repaired" (tampering or another app editing the file) and "reloaded" (a job was restored).
- App log: the menu bar app writes to the macOS unified log with subsystem `com.nokal.siteblock.app` and category `tabs`. Look for "reloaded a ... tab on a blocked part of a site" (the tab watcher acted) and "permission to control ... denied" (the person refused the Automation permission).
- Status: `siteblock status`.
- Upgrade: pull the repository, run `scripts/build.sh`, then `sudo scripts/install.sh`.
- Forgotten password: `sudo siteblock recover`, then wait 48 hours and set a new password.
- Removal: `siteblock uninstall`, enter the password, and wait 48 hours (or the unblock delay, if that is longer).

---

## Success Criteria

- [ ] All unit and integration tests pass with `scripts/test.sh`.
- [ ] After install, youtube.com fails to load in Safari and Chrome.
- [ ] Editing `/etc/hosts` by hand is undone within 2 seconds.
- [ ] `sudo launchctl bootout system/com.nokal.siteblock.daemon` is undone within 5 seconds.
- [ ] Unblocking needs the password and waits the full delay; moving the clock forward does not shorten it.
- [ ] The menu bar app can set up a password, add a site, start and cancel an unblock, and change settings.
- [ ] With a path rule and the Automation permission allowed, a Chrome tab that switches to the blocked part of a site without loading a page is reloaded once within about half a second, and other tabs are left alone.
- [ ] With the Automation permission refused, the panel shows the permission banner and no tab is reloaded.
- [ ] Rebooting keeps every block and countdown.

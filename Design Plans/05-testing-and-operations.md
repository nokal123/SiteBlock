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
3. **Installed-system verification** (`scripts/verify-install.sh`) runs after a real install and checks the real `/etc/hosts`, the real name lookup, and real connections. Separate live tests drive a real Chrome to check the tab watcher, and run a whole update from a local test server.

There are no mocks of the socket, the file system or the hosts editor. The only stand-in is fake elapsed time in unit tests. The Apple Events code in `Sources/SiteBlockApp/ChromiumTabs.swift` needs a running browser and a macOS permission prompt, so it is covered only by the live tab-watcher test. The `Updater` in `Sources/SiteBlockApp/Updater.swift` downloads from GitHub and shows a macOS password prompt, so it is covered only by the live update test; the decisions it relies on are covered by `UpdateCheckTests`.

---

## Unit Tests

`Tests/SiteBlockCoreTests/`:

- **DomainNormalizerTests:** URLs with scheme, path, query, fragment, port, user info; uppercase; trailing dot; `www.` stripping; Unicode names to Punycode; IPv4 and IPv6 rejection; single-label names; labels of 63 and 64 characters; a 253-character and a 254-character name; leading and trailing hyphens; underscores and spaces; `localhost`, `printer.local`; empty and whitespace-only input.
- **FamilyDNSProvidersTests:** providers-file tests check the rules of `parse` and that the active provider is CleanBrowsing Family with its four addresses (expected values from [02-core-components.md](02-core-components.md) § FamilyDNSProviders).
- **PunycodeTests:** the RFC 3492 § 7.1 sample strings that are plain labels, plus `bücher` → `bcher-kva`, `münchen` → `mnchen-3ya`, and an all-ASCII label returned unchanged by `toASCII`.
- **DomainExpanderTests:** a plain domain gets exactly the base plus the eight prefixes; `reddit.com` includes `redd.it`, `www.redd.it` and `i.redd.it`; the output is sorted with no duplicates; `x.com` and `twitter.com` both cover each other.
- **HostsFileEditorTests:** the default macOS hosts file gains a section and keeps its own lines; rendering twice gives the same text; an empty block list removes the section; a hand-edited section is replaced; two sections collapse to one; an orphan BEGIN with no END removes only that line; a stray END is removed; a user line `1.2.3.4 reddit.com other.com` becomes `1.2.3.4 other.com`; a user line that only names blocked hosts is dropped; comments that mention a blocked host are kept; `\r\n` input; tabs between fields; a file with no trailing newline.
- **PasswordHasherTests:** right and wrong passwords; two hashes of the same password differ (random salt); a hash with a changed iteration count, bad Base64, or unknown algorithm fails verification; Unicode and space-padded passwords; the minimum-length rule.
- **EngineTests:** every command's success and failure codes from [02-core-components.md](02-core-components.md) § Engine; unblock finishes only after the full delay and not one tick earlier; a second `unblock` does not restart the countdown; `add` cancels a pending unblock; delay increase is immediate and decrease waits for the old delay; five wrong passwords lock out and a correct password during lockout is still refused; lockout ends after its time; recovery is refused for non-root, and after finishing clears the password but keeps blocks; uninstall calls `onUninstall` exactly once; negative, NaN and infinite elapsed values change nothing; JSON round-trip of the full state.
- **EngineTemporaryUnblockTests** (expected values from [02-core-components.md](02-core-components.md) § Engine, Temporary unblock commands, Temporary unblock tick rule and Status of a temporary unblock, and [01-overview-and-data.md](01-overview-and-data.md) § Wire Protocol):
  - Checks, one test per step and in the documented order: a missing `domain`, `password` or `seconds` gives `badRequest`; a bad site name gives `invalidDomain`, and for `temporaryUnblockPath` bad rule text gives `invalidDomain` or `invalidPath`; an unknown site or rule gives `notBlocked`; a site or rule with a pending unblock or a temporary unblock gives `alreadyPending` with the documented messages; a window just below `minTemporarySeconds` or just above `maxTemporarySeconds` gives `invalidDuration` (the sentence names the limit that was broken: the shortest window for one too short, the longest for one too long), and the two boundary values are accepted; a start wait below `delaySeconds` or above `maxTemporaryStartSeconds` gives `invalidDuration`, the two boundary values are accepted, and a missing `startSeconds` means `delaySeconds`.
  - Password handling: a request that fails any check before the password check, even with a wrong password, leaves `failedAttempts` at `0`, and gets that check's error even during a lockout; a valid request with a wrong password counts one failed attempt, and five lock out; a valid request during a lockout gets `lockedOut`; a valid request with no password set gets `notSetUp`.
  - Success: the site or rule gets a `temporaryUnblock` whose `startsIn` and `window` have the chosen lengths, it stays in `blocked` or `blockedPaths`, the message matches the documented wording, and the reply carries the status fields.
  - Interactions: `cancelUnblock` and `cancelUnblockPath` clear a pending unblock first; with only a temporary unblock they clear it with the waiting message or the open message; with neither they give `nothingPending`. `add` and `addPath` on an entry with a temporary unblock, waiting or open, clear it with no password, even when none is set. `unblock` and `unblockPath` on such an entry give `alreadyPending` before the password check, so a wrong password is not counted. An entry never ends up with both kinds of unblock.
  - Tick: `elapsed` is taken off `startsIn` first, and the part it did not use is taken off `window`; with `startsIn` already `0` all of `elapsed` goes to `window`; neither goes below `0`; `tick` returns `true` on the tick that opens the unblock and on the tick that ends it and `false` on the ticks in between; a finished temporary unblock is removed while the site or rule stays on the list; one long `elapsed` that covers the whole start wait and the whole window finishes it in one tick; all of this holds for path rules as well as sites.
  - Enforcement lists: while a temporary unblock waits, `blockedHosts` and `browserBlockEntries` still hold the site; while it is open they leave out its hosts and entries; after it ends they hold them again. A host shared with another blocked site that is not open stays. A path rule on a site whose whole site is open is in the browser lists, and a path rule whose own unblock is open is not. Other sites and rules are not affected, and `hostsToWrite` still holds the Private Relay and DNS-over-HTTPS names.
  - Status: `opensInSeconds`, `secondsRemaining`, `windowSeconds` and `isOpen` in each phase; remainders round up, so 0.2 seconds left reports 1; `opensInSeconds` is `nil` once open; sites and path rules both carry the fields, and an entry without a temporary unblock has `nil`.
  - Policy: `Policy.production` holds 300, 14400 and 604800 for the temporary unblock limits, and `Policy.fastForTests.minTemporarySeconds` is 1; `Policy.production.saveIntervalSeconds` is 15 and `Policy.fastForTests.saveIntervalSeconds` is 2.
- **TemporaryUnblockPersistenceTests:** a `state.json` text without the `temporaryUnblock` key on sites and path rules decodes through `StateStore.load` with `nil` and is not renamed as corrupt; a state holding a waiting and an open temporary unblock survives `save` then `load` with the same remaining times; a status reply without `temporaryUnblock` decodes with `nil` on both sites and path rules.
- **FormattingTests:** each duration and clock example from [02-core-components.md](02-core-components.md) § Formatting, `compact` at 0, 45, 59, 60, 61, 90 and 3600 seconds, at one hour and a half, and at two days and three hours (including the dropped minutes), and `parseDuration` on valid and invalid input.
- **TemporaryUnblockOptionsTests** (expected values from [02-core-components.md](02-core-components.md) § TemporaryUnblockOptions): `windowChoices` is the five documented values, all inside the daemon's window range; `startChoices` starts with the delay and lists only the 2, 3, 4, 6, 8, 12 and 24 hour choices that are longer than the delay (a delay of 1 hour offers itself and all seven, a delay of 5 hours offers itself and then 6, 8, 12 and 24, and a delay of 24 hours or more offers only itself); `label` writes whole hours from 1 to 24 in hours ("1 hour", "24 hours") and other lengths like `Formatting.duration`. `scheduleText` and `clockPhrase`, with a fixed calendar, time zone and `en_US` locale: same day ("at …"), the next day ("tomorrow at …"), later days (weekday and date), a time just after midnight counting as tomorrow, a window that ends on the next day, and the shorter sentence before a window is chosen.
- **WatchedPathRulesTests** (expected values from [02-core-components.md](02-core-components.md) § TabRuleMatcher, Rules for the tab watcher): a rule whose temporary unblock is open is left out; rules waiting to open, waiting to unblock for good, or on a site whose whole site is open stay in; a snapshot with no path rules gives an empty list; the order of the rules is kept.
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
- **UpdateCheckTests** (expected values from [02-core-components.md](02-core-components.md) § UpdateCheck, using real files and real JSON text):
  - Constants: `versionURL` and `packageURL` are exactly the two documented `https://github.com/nokal123/SiteBlock/releases/latest/download/…` addresses.
  - `parse` accepts a valid file and returns all five values unchanged, and a file with extra fields is accepted.
  - `parse` rejects each broken field on its own, with every other field valid: a `build` of 0 and a negative `build`; a `version` that does not match `build` (a different build number, a different major or minor part, extra text); an `asset` with another name, including `SiteBlock.zip` in different letter case; a `sha256` of 63 or 65 characters, in uppercase, or with a character that is not hexadecimal; a `commit` that is short, long, in uppercase or not hexadecimal; and each of the five fields missing, or of the wrong JSON type.
  - `parse` returns `nil` without crashing for text that is not JSON, for an empty `Data`, for a JSON array, and for `{}`.
  - `isNewer` is `true` for a higher published build, `false` for an equal and for a lower one, and `true` for every published build when the installed build is 0.
  - `matchesChecksum`, on files written to a temporary folder: an empty file matches `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`; a file holding the three bytes `abc` matches `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`; the same file with one byte changed does not match; the expected value in uppercase still matches; and an expected value that is not the file's checksum, including an empty one, does not match.

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
- Kill the daemon with `SIGKILL` during an unblock countdown, restart it, and see the countdown continue from where it was at the last save (after the last command, or at most `saveIntervalSeconds` earlier: 15 seconds in production, 2 under `--policy-fast`) rather than restart or finish early.
- Send a request over 64 KB and get `badRequest`; send invalid JSON and get `badRequest`; open a connection and send nothing, and see it receive `badRequest` after the 2-second read timeout while the daemon keeps answering other clients.
- Ten clients each add a different domain, with no more than three in flight at a time because of the 4-connections-per-user limit; all ten end up blocked. A fifth simultaneous connection from one user is closed without a reply, and the slot frees up once a connection ends.
- Adding a 21st site under `--policy-fast` gives `tooManySites`.
- Deleting or overwriting `state.json` while the daemon runs is repaired within about 1 second with the blocks kept. After `SIGKILL`, a missing `state.json` is restored from `state.backup.json`.
- A hand-set `uninstalling: true` without a finished uninstall countdown is ignored on restart; with a finished countdown the uninstall runs.
- `add youtube.com` puts the `0.0.0.0` and `::` lines for every expanded YouTube name into the hosts file before the response returns.
- While any site is blocked the section also holds `mask.icloud.com` and `mask-h2.icloud.com` exactly once each; they leave with the last unblocked site; a user line naming them is stripped while a site is blocked and left alone when nothing is blocked.
- Hostile domain strings sent as raw JSON (newlines, `#`, spaces, control characters) never add a line to the hosts file.
- A lockout survives a daemon restart.
- Passwords, domains and path rules never appear in the daemon log, including the temporary unblock lines. A flood of rejected requests produces summary lines, not one line per request.
- `--tick` or `--policy-fast` without `--sandbox` exits with code 64.
- `recoveryStart` from a non-root test process returns `notRoot`.
- Run the real `siteblock` CLI with `SITEBLOCK_SOCKET` set: `status`, `add`, `unblock` with the password piped on standard input, and the exit codes from [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI, including exit code 2 when no daemon is running.
- Temporary unblock under `--policy-fast` (delay 2 seconds, shortest window 1 second): after approval the site's lines stay in the sandbox hosts file and its entries stay in the sandbox browser policy files for the whole start wait, they are gone after the start wait, and they are back after the window ends. The log holds the approved, opened and ended lines. The same is checked for a path rule, whose entries are in the browser policy files only.
- Restarting the daemon in the middle of a start wait, and again in the middle of a window, keeps the remaining times: the countdown continues from the last save and neither restarts nor finishes early.
- Cancelling a waiting temporary unblock and ending an open one early (`cancelUnblock`, as "Keep blocked" and "Block now" do) put the site's lines and entries back before the response returns, with no password.
- The real `siteblock` CLI with `SITEBLOCK_SOCKET` set: `unblock <site> --for 2s --in 2s` with the password piped on standard input schedules a temporary unblock; `status` shows the waiting line and then the `OPEN` line; `cancel` ends it; a `--for` value that is not a duration exits with code 64 and sends nothing; an `--in` shorter than the unblock delay prints the daemon's sentence and exits with code 1.
- Family DNS (`DNSEnforcerTests`): the servers a service is expected to hold are the active provider's four servers read from `Sources/SiteBlockCore/FamilyDNSProviders.json`, never a copy typed into the test, so a provider switch needs no test edit. They cover setting the servers on a service, recording its original first, never replacing an existing record, and putting the originals back when the family servers do not answer or the filter ends.
- Uninstall in sandbox mode: after the uninstall wait (2 seconds under `--policy-fast`, where both the minimum and the delay are 2), the hosts section is gone and the daemon exits with code 0.

**Script tests** run the real scripts as child processes. The version-number script runs on a copy placed in a temporary folder laid out like the repository, so the repository's own generated file is never overwritten. Expected values come from [04-infrastructure.md](04-infrastructure.md) § Version Numbers and § Packaging for Another Mac.
- `scripts/write-build-number.sh` in a temporary git repository with a known number of commits writes `Sources/SiteBlockCore/BuildNumber.swift` holding `public let siteBlockBuildNumber = <that number>`. After one more commit and a second run, the file holds the number plus one. Running it twice on the same commit gives the same file.
- The same script in a folder that is not a git checkout writes `public let siteBlockBuildNumber = 0` and exits with code 0.
- `git check-ignore Sources/SiteBlockCore/BuildNumber.swift` in the repository reports the file as ignored.
- The `version.json` that `scripts/package.sh` writes (checked after a real run, which writes into the git-ignored `dist/`, or by running that step on its own against a small stand-in zip in a temporary folder) is a file with the five fields `version`, `build`, `commit`, `asset` and `sha256`. Its `sha256` equals the SHA-256 of the zip it describes, as computed by `shasum -a 256`. `UpdateCheck.parse` accepts the file. Its `version` is `1.0.` followed by its `build`, and its `commit` is the full hash that `git rev-parse HEAD` reports.

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

### Live update test

The update path needs a real GitHub release, a real download and a real macOS password prompt, so it has a manual harness that the main session runs once against a scratch copy of the repository. The scratch copy is deleted afterwards and its changes are never committed.

1. Build two packages from the scratch copy with `scripts/package.sh`: an older build N and a newer build N+1. The build number is the commit count, so the scratch copy gets one extra commit between the two builds.
2. Serve `SiteBlock.zip` and `version.json` of build N+1 from a local test server (for example `python3 -m http.server` in the folder that holds them). In the scratch copy only, `UpdateCheck.versionURL` and `UpdateCheck.packageURL` are changed to the local server's addresses before building build N, so the installed app asks the local server and not GitHub.
3. Install build N with `sudo scripts/install.sh`. Add a site, set a password and start an unblock countdown, so there is state to keep.
4. In Settings, press "Check for updates". The panel shows the banner "SiteBlock 1.0.<N+1> is available." with "Update" and "Not now". Press "Not now", restart the app, and see that the banner stays hidden for that build, then press "Check for updates" again.
5. Press "Update". The banner moves through "Downloading…", "Checking the download…" and "Waiting for your password…", and macOS shows its password prompt with the sentence "SiteBlock needs your Mac password to install version 1.0.<N+1>." Cancel the prompt once and see "The update was cancelled." with the buttons back and nothing changed. Press "Update" again and type the Mac password.
6. After the install, check: the installer log `/private/tmp/siteblock-update.log` ends without errors; the running app and `siteblock status` both show version 1.0.<N+1>; the banner is gone; the site, the password and the unblock countdown are as they were; and the daemon was restarted by the installer. This step also settles what happens to the root shell that the prompt started when the installer replaces the running app: when that shell ended together with the app, the install did not finish, and the root command has to start the installer detached (see [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater, The installer outlives the app).
7. Run the same update with a corrupted download: change one byte of the served `SiteBlock.zip` and keep the old `version.json`. The banner shows "The update didn't pass its checks, so nothing was installed.", no password prompt appears, and the temporary download folder is gone.

The test passes when steps 4 to 7 behave as described.

---

## Security Considerations

- The socket is world-writable on purpose, so the logged-in user's app can reach the root daemon. Every command that loosens a block needs the password, and the password checks are rate-limited, so access to the socket alone gains nothing but the ability to add blocks.
- The daemon never runs anything built from client input. Domain strings are validated to `a–z 0–9 - .` before they reach the hosts file, so a request cannot inject extra lines or other host entries.
- `state.json` is mode `0600` root-only, so other users cannot read the password hash.
- The password is never logged, never written to disk in plain form, and not kept in memory after the check beyond the lifetime of the request.
- `recoveryStart` uses the kernel-reported peer user ID, which the client cannot fake.
- A temporary unblock needs the password and a start wait of at least the unblock delay, so opening a site this way is never faster than a permanent unblock. Cancelling one or ending one early needs no password, because it only makes the Mac stricter.
- An update installs only after a click on "Update" and the Mac password, which macOS asks for in its own prompt. The app downloads only from the two addresses held in `UpdateCheck`, installs only a package whose SHA-256 matches `version.json` and whose programs pass `codesign --verify --strict`, and deletes the download when any check fails. The checksum proves that the download is complete, not who made it (see [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits).
- The tab watcher sends Apple Events only to browser processes the person has allowed under the Automation permission. It reads window IDs, tab IDs and tab addresses, and its only command is a tab reload. Its log lines name the rule that matched, not the tab's full address.

---

## Operations

- Logs: `/Library/Logs/SiteBlock/siteblockd.log` and `watchdog.log`. Look for "hosts file repaired" (tampering or another app editing the file) and "reloaded" (a job was restored). Temporary unblocks log "temporary unblock approved", "temporary unblock opened" and "temporary unblock ended" lines.
- App log: the menu bar app writes to the macOS unified log with subsystem `com.nokal.siteblock.app` and category `tabs`. Look for "reloaded a ... tab on a blocked part of a site" (the tab watcher acted) and "permission to control ... denied" (the person refused the Automation permission).
- Update log: the installer that the "Update" button runs writes its output to `/private/tmp/siteblock-update.log`. The update check itself logs nothing to the panel during automatic checks.
- Status: `siteblock status`, which also shows the installed version.
- Upgrade: press "Update" in the menu bar app when its banner appears, or pull the repository, run `scripts/build.sh`, then `sudo scripts/install.sh`. A Mac whose installed SiteBlock has no update check is upgraded by hand once.
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
- [ ] A temporary unblock needs the password, a window of 5 minutes to 4 hours and a start wait no shorter than the unblock delay. A request that breaks one of those rules is refused without counting a wrong password.
- [ ] A site with a temporary unblock stays blocked during the start wait, opens for exactly the window, and is blocked again within one tick after the window ends, in the hosts file and in every browser's block list.
- [ ] "Keep blocked", "Block now" and `siteblock cancel` end a temporary unblock at once with no password, and adding the site again does the same.
- [ ] The menu bar app can schedule a temporary unblock from the "For a while" choice, and shows the waiting row and the open row with a live countdown.
- [ ] `siteblock unblock <site> --for <duration> --in <duration>` and `siteblock status` work as described in [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI.
- [ ] With a path rule whose temporary unblock is open, the tab watcher reloads no tab on that part of the site, and it watches the rule again after the window ends.
- [ ] Rebooting keeps every block and countdown, including the remaining times of a temporary unblock.
- [ ] Every program shows the version `<series>.<n> (build <build>)`, where `<build>` is the number of commits, and `scripts/write-build-number.sh` writes 0 outside a git checkout.
- [ ] `scripts/package.sh` writes `SiteBlock.zip` and a `version.json` whose `sha256` matches the zip and which `UpdateCheck.parse` accepts.
- [ ] The menu bar app shows "SiteBlock <version> is available." with "Update" and "Not now" only when the published build is newer than the installed one, and "Not now" hides it for that build until a newer one appears.
- [ ] "Update" downloads, checks the checksum and the signatures, and installs only after the Mac password is typed. A package that fails a check is never installed and no password prompt appears.
- [ ] After an update the blocks, the SiteBlock password, the unblock delay and every countdown are unchanged, and the new version is shown in Settings and by `siteblock status`.
- [ ] Settings shows "Version 1.0.<build>" and a "Check for updates" button that reports "You're up to date." or "Couldn't check for updates. Try again later."

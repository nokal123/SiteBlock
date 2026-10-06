# Tasks: Hardening After Code Review
> **Corresponds to:** [01-overview-and-data.md](../01-overview-and-data.md), [02-core-components.md](../02-core-components.md), [03-daemon-cli-app.md](../03-daemon-cli-app.md), [04-infrastructure.md](../04-infrastructure.md)

**Scope:** Bring the source in line with the hardening rules that the design now states. Each step names the design section that is the spec.

**Prerequisites:** All earlier task files are complete. The unit tests pass with `scripts/test.sh --filter SiteBlockCoreTests`.

**Code conventions:** same as TASKS-02. Every type and method has a `///` comment above it, and the non-obvious decisions are commented where they are made. Update a comment in the same edit whenever the behavior it describes changes.

---

## Step 1: Normalizer size check before Punycode

**File:** `Sources/SiteBlockCore/DomainNormalizer.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § DomainNormalizer, step 6

**Acceptance Criteria:**
- [ ] A 21,000-character single label of distinct CJK characters throws `.labelTooLong` in under 10 ms in a debug build.
- [ ] A name of 254 or more scalars throws `.tooLong` before any encoding.

---

## Step 2: Hosts editor section pairing and resolver-style parsing

**File:** `Sources/SiteBlockCore/HostsFileEditor.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § HostsFileEditor, render steps 2 and 3, Input guard

**Sub-steps:**
- 2a. Rewrite step 2 so that each END closes the nearest open BEGIN above it. Every other BEGIN line, and every END with no open BEGIN, is dropped as a single line.
- 2b. Rewrite step 3 to work on the line's Unicode scalars. Cut the line at the first NUL (U+0000) or `#`. Split the rest only on U+0020 (space) and U+0009 (tab). Lowercase only the ASCII letters, and remove one trailing `.` before comparing a name with the blocked set. Lines that contain no blocked name stay byte-for-byte as they were. A rewritten line keeps its comment as ` #comment`.
- 2c. Rendering must give the same text when run twice, including on inputs with combining characters after a space (for example `x\twww.reddit.com \u{301}reddit.com`).

**Acceptance Criteria:**
- [ ] `# BEGIN SiteBlock entries I added myself` above the user's own lines, with a real section further down, loses only that comment line.
- [ ] `151.101.1.141 reddit.com.` and `151.101.1.142 www.reddit.com\u{0}x` lose the blocked name.

---

## Step 3: Engine site cap, setup restriction, policy field

**Files:** `Sources/SiteBlockCore/Engine.swift`, `Sources/SiteBlockCore/Protocol.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § Engine (Properties, Who may set up, Site cap); [01-overview-and-data.md](../01-overview-and-data.md) § Response, § Commands, § Fixed Policy Values

**Sub-steps:**
- 3a. Add `maxSites` to `Policy`, set to 500 in `production` and 20 in `fastForTests`.
- 3b. Add `ErrorCode.notAllowed` and `ErrorCode.tooManySites`.
- 3c. Add `public var consoleUID: () -> uid_t? = { nil }` to `Engine`, and apply the setup rule.
- 3d. Apply the cap to new sites in `add`.

---

## Step 4: Socket server limits, timeout, umask, normalize off-queue

**Files:** `Sources/siteblockd/SocketServer.swift`, `Sources/siteblockd/DaemonRuntime.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SocketServer

**Sub-steps:**
- 4a. Use a 2-second timeout for both reading and writing.
- 4b. Read the peer user ID right after `accept`. Allow at most 4 open connections per non-root user ID and 32 in total, with 4 of those slots kept for root. A connection over its limit is closed without a reply.
- 4c. Create the socket with `umask(0o111)` around `bind`, restore the old umask afterwards, and remove the `chmod`.
- 4d. Before the hop onto the engine queue, run `DomainNormalizer.normalize` on any `domain` argument. On failure, reply `invalidDomain` straight away. On success, pass the normalized name on to the engine (the engine normalizes again, which costs nothing for an ASCII name).

---

## Step 5: Logging, ProcessRunner race, sandbox-as-root

**Files:** `Sources/siteblockd/DaemonRuntime.swift`, `Sources/siteblockd/ProcessRunner.swift`, `Sources/siteblockd/main.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime (Logging, Process runner), § siteblockd Entry Point

**Sub-steps:**
- 5a. Log successful commands (except `status`) and every password check, right or wrong, one line each. For any other rejected command, count it per user ID and write one summary line per minute.
- 5b. Fix the data race in `ProcessRunner`: read the collected output only after the reader thread has finished.
- 5c. `--sandbox` while running as root exits with code 64.

---

## Step 6: HostsEnforcer flags, random temp, fallback, log wording

**File:** `Sources/siteblockd/HostsEnforcer.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § HostsEnforcer, steps 3 to 7

**Sub-steps:**
- 6a. In production only, before writing, clear `UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND` on the hosts file and on its parent folder. Use `lstat` to read the current `st_flags`, then `lchflags` to write them back with those bits removed.
- 6b. Create the temp file `.hosts.siteblock.XXXXXX` with `mkstemp`. If it fails, create it yourself with a random suffix and `O_CREAT|O_EXCL|O_NOFOLLOW`. Then `fchmod 0644`, and in production `fchown 0:0`. Write, `fsync`, and `rename`.
- 6c. If the rename fails, write the text into the hosts file itself, opened with `O_WRONLY|O_TRUNC|O_NOFOLLOW`, then remove the temp file.
- 6d. Log "hosts file repaired" when the pass added lines or removed a bypass line. Log "blocks removed from hosts file" when it only removed managed lines. Log nothing when the change came from a command or a finished countdown.

**Acceptance Criteria:**
- [ ] In sandbox mode, a folder planted at the old fixed temp path (`hosts.siteblock.tmp`) does not stop a repair.

---

## Step 7: Watchdog never stands down for a missing folder; uninstall order

**Files:** `Sources/siteblockd/LaunchdGuard.swift`, `Sources/siteblockd/Uninstaller.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § LaunchdGuard and Watchdog, § Uninstaller

**Sub-steps:**
- 7a. `uninstallInProgress` returns true only when the state file records a finished uninstall. A missing folder or an unreadable state file means the watchdog keeps guarding.
- 7b. `ensureLoaded` creates the state folder with mode 0700 and `bin` with mode 0755, both `root:wheel`, before it restores the program. Both are created explicitly, never through intermediate-directory creation.
- 7c. Uninstall order, in production:
  1. Save the state. If the save fails, log and `exit(1)` without touching anything.
  2. `bootout` the watchdog and wait for it (10-second timeout).
  3. Remove the hosts section.
  4. Stop the app.
  5. Delete the files, including `/etc/newsyslog.d/siteblock.conf`.
  6. The detached shell boots out only the daemon, then deletes the two folders.
- 7d. Add `newsyslogConf` to `Paths`: production `/etc/newsyslog.d/siteblock.conf`, sandbox `root/newsyslog.d/siteblock.conf`.

---

## Step 8: install.sh

**File:** `scripts/install.sh`
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Install Script, steps 5, 5a and 8

**Sub-steps:**
- 8a. Generate the plists with the installed root-owned `siteblockd` copy, not `build/siteblockd`.
- 8b. Write the newsyslog config.
- 8c. Run the final `siteblock status` as the invoking user with `sudo -u "#$SUDO_UID"`.
- 8d. Update `--dry-run` output to match.

**Acceptance Criteria:**
- [ ] `bash -n scripts/install.sh` passes, and `scripts/install.sh --dry-run` shows the new actions.
- [ ] `swift build` gives no warnings.
- [ ] `scripts/test.sh --filter SiteBlockCoreTests` passes. If a unit test fails because the design changed (for example the hosts section pairing), report which test and why instead of editing the test.

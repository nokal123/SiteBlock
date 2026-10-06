# Tasks: Build, Install and Verification Scripts
> **Corresponds to:** [04-infrastructure.md](../04-infrastructure.md), [05-testing-and-operations.md](../05-testing-and-operations.md) § Installed-System Verification

**Scope:** Shell scripts, the app Info.plist template, and the README.

**Prerequisites:** [TASKS-03-daemon-cli-app.md](TASKS-03-daemon-cli-app.md) complete.

**Script conventions:** `#!/bin/bash`, `set -euo pipefail`, every path quoted, a comment above each block saying what it does, script directory found with `cd "$(dirname "$0")/.."`.

---

## Step 1: Info.plist and build.sh

**Files:** `Resources/Info.plist`, `scripts/build.sh`
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Build Script

**Acceptance Criteria:**
- [ ] `scripts/build.sh` produces `build/SiteBlock.app`, `build/siteblockd`, `build/siteblock`.
- [ ] `codesign --verify build/SiteBlock.app` succeeds; `plutil -lint build/SiteBlock.app/Contents/Info.plist` is OK.

---

## Step 2: install.sh

**File:** `scripts/install.sh`
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Install Script, § Upgrade Behavior

**Sub-steps:**
- 2a. The eight steps in order. Use `launchctl bootout system/<label> 2>/dev/null || true` for the unload.
- 2b. When `$SUDO_UID` is empty (run as real root), skip the LaunchAgent bootstrap and print how to start the app.
- 2c. Add `--dry-run`, which prints every action without doing it and does not require root, so the script can be checked without a password.

**Acceptance Criteria:**
- [ ] `scripts/install.sh --dry-run` lists every copy, plist write and launchctl call.
- [ ] `bash -n scripts/install.sh` passes.

---

## Step 3: verify-install.sh

**File:** `scripts/verify-install.sh`
**Reference:** [05-testing-and-operations.md](../05-testing-and-operations.md) § Installed-System Verification

**Sub-steps:**
- 3a. `verify-install.sh` prints PASS/FAIL per check and a summary, exits non-zero on any FAIL. It uses `youtube.com` and leaves it blocked. It also checks that `siteblock status` reports the hosts file healthy, and prints the sudo command a person can run to test hand-edit repair (`sudo sed -i '' '/youtube.com/d' /etc/hosts; sleep 3; grep -c youtube.com /etc/hosts`).

---

## Step 4: README

**File:** `README.md`
**Purpose:** How to build, install, use (app and CLI), recover a forgotten password, uninstall, and what SiteBlock can and cannot stop. A short developer section covers tests and repairing an install. Plain-English, full sentences.

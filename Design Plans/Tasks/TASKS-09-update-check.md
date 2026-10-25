# Tasks: Update Check
> **Corresponds to:** [01-overview-and-data.md](../01-overview-and-data.md) § Architecture (Updates), § Threat Model and Honest Limits (Limits of updates), § Fixed Policy Values; [02-core-components.md](../02-core-components.md) § Models and Protocol Types (Version constants), § Engine (Policy), § UpdateCheck; [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime, § siteblock CLI, § SiteBlock.app Menu Bar App, § Updater; [04-infrastructure.md](../04-infrastructure.md) § Version Numbers, § Build Script, § Upgrade Behavior, § Packaging for Another Mac, § Automatic Package Builds; [05-testing-and-operations.md](../05-testing-and-operations.md) § Unit Tests, § Integration Tests, § Installed-System Verification

**Scope:** Add version numbers of the form `1.0.<build>`, the two files GitHub publishes (`SiteBlock.zip` and `version.json`), the pure update rules in `SiteBlockCore`, and the `Updater` in the menu bar app with its banner and Settings controls. The app checks for a newer version once a day and installs it only after a click on "Update" and the Mac password. This also covers the policy value `saveIntervalSeconds` that the daemon runtime reads, and the tests.

**Prerequisites:** [TASKS-04-build-install.md](TASKS-04-build-install.md) and [TASKS-08-temporary-unblock.md](TASKS-08-temporary-unblock.md) complete. `scripts/build.sh`, `scripts/package.sh`, `scripts/install.sh` and the GitHub workflow already work, and `scripts/test.sh` passes.

**Code conventions:** same as TASKS-02. Every type and method has a `///` comment above it saying what it does in plain English, and the non-obvious decisions are commented where they are made. Update a comment in the same edit whenever the behavior it describes changes.

---

## Step 1: Build number and version

**Files:** `Sources/SiteBlockCore/Models.swift`, `scripts/build.sh`, `Resources/Info.plist`
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Version Numbers, § Build Script; [02-core-components.md](../02-core-components.md) § Models and Protocol Types (Version constants)
**Purpose:** Give every build the version `1.0.<build>`, where `<build>` is a release number kept by hand in `Models.swift`.

**Sub-steps:**
- 1a. `Models.swift` declares `public let siteBlockBuildNumber = 95`, the release number, next to `siteBlockSeries` and `siteBlockSeriesFirstBuild`. To release, it is raised by one and pushed to `master`; it never goes down.
- 1b. The version people see is `siteBlockSeries` plus `max(0, siteBlockBuildNumber - siteBlockSeriesFirstBuild)`, and `siteBlockVersion` is that text.
- 1c. `scripts/build.sh` reads the version from `siteblockd --version`, refuses a version that does not look like `1.0.<number>`, and writes `CFBundleShortVersionString` as `1.0.<build>` and `CFBundleVersion` as `<build>` into the built app's `Info.plist`. `Resources/Info.plist` keeps the placeholder values.
- 1e. `siteblockd --version`, `siteblock version` and the first line of `siteblock status` print `siteblockd` or `siteblock` and the version, or `SiteBlock <version>`, as described in [03-daemon-cli-app.md](../03-daemon-cli-app.md).

**Dependencies:** none.

**Acceptance Criteria:**
- [ ] `siteBlockBuildNumber` in `Models.swift` is the release number, and `siteblockd --version` prints it.
- [ ] `build/siteblockd --version`, `siteblock version` and the built app's `CFBundleShortVersionString` show the same `1.0.<build>`, and `CFBundleVersion` is the build number alone.
- [ ] `swift build` gives no warnings.

---

## Step 2: Save interval in the policy

**Files:** `Sources/SiteBlockCore/Engine.swift`, `Sources/siteblockd/DaemonRuntime.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § Engine (Policy); [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Daemon Runtime
**Purpose:** Let the periodic state save be shortened for tests, so a test sees it within seconds.

**Sub-steps:**
- 2a. Add `saveIntervalSeconds: Int` to `Policy`, with a default of 15 in the initializer. `Policy.production` holds 15 and `Policy.fastForTests` holds 2.
- 2b. In `DaemonRuntime`, save when any countdown is running and `policy.saveIntervalSeconds` seconds have passed since the last save.

**Dependencies:** none.

**Acceptance Criteria:**
- [ ] `Policy.production.saveIntervalSeconds` is 15 and `Policy.fastForTests.saveIntervalSeconds` is 2.
- [ ] A daemon started with `--policy-fast` and killed with `SIGKILL` during a countdown restarts with at most about 2 seconds of progress lost.
- [ ] `swift build` gives no warnings.

---

## Step 3: UpdateCheck

**File:** `Sources/SiteBlockCore/UpdateCheck.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § UpdateCheck
**Purpose:** Hold the pure rules of the update check, so every decision can be tested without a network.

**Sub-steps:**
- 3a. `public struct UpdateInfo: Codable, Equatable, Sendable` with `version: String`, `build: Int`, `commit: String`, `asset: String` and `sha256: String`.
- 3b. `public enum UpdateCheck` with the constants `versionURL` and `packageURL`, set to the two fixed `https://github.com/nokal123/SiteBlock/releases/latest/download/…` addresses.
- 3c. `parse(_:)` returns an `UpdateInfo` only when `build` is above 0, `version` equals `1.0.` followed by `build`, `asset` equals `SiteBlock.zip`, `sha256` is exactly 64 lowercase hexadecimal characters and `commit` is exactly 40. Any other input, including text that is not JSON and empty data, returns `nil` and never crashes. Extra fields are ignored.
- 3d. `isNewer(_:than:)` is `info.build > installedBuild`.
- 3e. `matchesChecksum(fileAt:expected:)` computes the SHA-256 of the file with CryptoKit, reading it in chunks, and compares it with `expected` ignoring letter case. A file that cannot be read does not match.

**Dependencies:** Step 1.

**Acceptance Criteria:**
- [ ] A valid file parses, and each broken field on its own makes `parse` return `nil`.
- [ ] `matchesChecksum` agrees with `shasum -a 256` on a real file.
- [ ] `swift build` gives no warnings.

---

## Step 4: Packaging and the workflow

**Files:** `scripts/package.sh`, `.github/workflows/package.yml`, `README.md`
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Version Numbers, § Packaging for Another Mac, § Automatic Package Builds
**Purpose:** Publish the package under one fixed name together with the file that describes it.

**Sub-steps:**
- 4a. `scripts/package.sh` runs `scripts/build.sh` and writes `dist/SiteBlock.zip`. It removes any older zip in `dist/` first.
- 4b. It writes `dist/version.json` with the fields `version`, `build`, `commit`, `asset` and `sha256`. `commit` is the output of `git rev-parse HEAD`, or 40 zeros without git. `sha256` is the lowercase SHA-256 of `SiteBlock.zip`.
- 4c. The workflow checks out the newest commit, runs `scripts/package.sh`, then downloads the published `version.json` and runs `scripts/release-check.sh <new> <published>`. Only when it prints `release` does the workflow create the new latest release with both `SiteBlock.zip` and `version.json`.
- 4d. The README and the workflow's header comment give the fixed package link `https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip`.

**Dependencies:** Steps 1 and 3.

**Acceptance Criteria:**
- [ ] `dist/version.json` passes `UpdateCheck.parse`, and its `sha256` equals `shasum -a 256 dist/SiteBlock.zip`.
- [ ] A push that leaves `siteBlockBuildNumber` alone is built and tested but publishes nothing, and a push that raises it by one publishes a release.

---

## Step 5: Updater

**Files:** `Sources/SiteBlockApp/Updater.swift`, `Sources/SiteBlockApp/StatusModel.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Updater; [02-core-components.md](../02-core-components.md) § UpdateCheck
**Purpose:** Check for a newer version, and download, verify and install it when the person asks.

**Sub-steps:**
- 5a. `Updater` is an `ObservableObject` owned by `StatusModel`, with the published properties `available: UpdateInfo?` and `phase` (`idle`, `checking`, `downloading`, `verifying`, `waitingForPassword`, `installing`, `failed(String)`, `upToDate`).
- 5b. Run the first check 60 seconds after the app starts, then every 24 hours, and on demand from Settings. A check is one GET of `UpdateCheck.versionURL` on an ephemeral session that follows redirects and waits at most 15 seconds. The answer goes through `UpdateCheck.parse` and `UpdateCheck.isNewer(_:than:)` against `siteBlockBuildNumber`.
- 5c. A failed automatic check changes nothing and shows nothing. A manual check shows "Couldn't check for updates. Try again later." when it fails and "You're up to date." when nothing newer exists.
- 5d. "Update" downloads `UpdateCheck.packageURL` into `SiteBlockUpdate-<random>` inside the temporary directory, waiting at most 5 minutes. It checks the checksum against `available.sha256`, unzips with `/usr/bin/ditto -x -k`, confirms the five expected paths under `SiteBlock/`, and runs `codesign --verify --strict` on `siteblockd`, `siteblock` and `SiteBlock.app`. Any failure sets `failed("The update didn't pass its checks, so nothing was installed.")` and deletes the folder.
- 5e. Copy the checked package into a fresh staging folder such as `/private/tmp/siteblock-update-<random>` and run its `scripts/install.sh` through `NSAppleScript` with `do shell script ... with prompt "SiteBlock needs your Mac password to install version <version>." with administrator privileges`, writing the output to `/private/tmp/siteblock-update.log`. A cancelled prompt returns the phase to `idle` with "The update was cancelled.".
- 5f. Make the install finish even if the root shell ends together with the old app. Verify this on a real machine (see Step 8); start the installer inside the root command in a background shell that ignores the hang-up signal (`/bin/bash -c "trap '' HUP; …" … &`), not with `nohup`, which refuses to start without a terminal.
- 5g. Run every step off the main thread. Delete the download folder when the install ends or fails.

**Dependencies:** Steps 1 and 3.

**Acceptance Criteria:**
- [ ] No step of an install runs before the click on "Update", and the installer does not start before the Mac password is typed.
- [ ] A package with a wrong checksum, a missing file or a failed signature check is never installed, and no password prompt appears.
- [ ] The panel stays responsive during the download.
- [ ] `swift build -c release --product SiteBlockApp` succeeds with no warnings.

---

## Step 6: Banner and Settings

**Files:** `Sources/SiteBlockApp/Views/BannersView.swift`, `Sources/SiteBlockApp/Views/SettingsView.swift`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (Panel states), § Updater
**Purpose:** Show the person that an update exists, let them start or postpone it, and show the installed version.

**Sub-steps:**
- 6a. In `BannersView`, show "SiteBlock <version> is available." with a filled "Update" button and a "Not now" button while `available` is set and that build has not been dismissed. Use the same style as the other banners.
- 6b. "Not now" saves the build number in `UserDefaults` under `dismissedUpdateBuild`. A newer build shows the banner again.
- 6c. While an install runs, show the phase in place of the buttons: "Downloading…", "Checking the download…", "Waiting for your password…" or "Installing…". Show a failure sentence in the banner, and after a cancelled prompt show the buttons again with "The update was cancelled.".
- 6d. In `SettingsView`, add one line "Version <siteBlockVersion>" and a "Check for updates" button with the result text of Step 5c under it.

**Dependencies:** Step 5.

**Acceptance Criteria:**
- [ ] The banner is hidden when the published build equals or is below the installed one.
- [ ] "Not now" hides the banner after an app restart, and a higher published build shows it again.
- [ ] `swift build -c release --product SiteBlockApp` succeeds with no warnings.

---

## Step 7: Tests

**Files:** `Tests/SiteBlockCoreTests/`, `Tests/IntegrationTests/`
**Reference:** [05-testing-and-operations.md](../05-testing-and-operations.md) § Unit Tests (UpdateCheckTests, EngineTemporaryUnblockTests Policy bullet), § Integration Tests (Script tests)

**Sub-steps:**
- 7a. Run the `qa-engineer` agent to write `UpdateCheckTests` and the `saveIntervalSeconds` policy checks. Its expected values come from the design sections named above, not from the implementation. Include the adversarial cases: each broken field on its own, upper case and non-hexadecimal checksums, a build of 0 and below, an empty file and a file with one byte changed.
- 7b. Run the `qa-engineer` agent to write the script tests: `release-check.sh` with a higher, equal, lower and malformed `build`, and the `version.json` that `package.sh` writes.
- 7c. Run the `test-rigor-auditor` agent in a fresh invocation on the new test files and the same design sections, passing no reasoning from the author. Send its findings back to a new `qa-engineer` invocation until the auditor is satisfied.

**Dependencies:** Steps 1 to 4.

**Acceptance Criteria:**
- [ ] `scripts/test.sh` passes in full.
- [ ] The auditor reports no confirmation tests and no uncovered case from the lists in [05-testing-and-operations.md](../05-testing-and-operations.md).

---

## Step 8: Live update test and verify

**Reference:** [05-testing-and-operations.md](../05-testing-and-operations.md) § Installed-System Verification (Live update test)

**Sub-steps:**
- 8a. Run the live update test from a scratch copy of the repository, with the two addresses in `UpdateCheck` pointed at a local test server. Never commit that change.
- 8b. Record in [03-daemon-cli-app.md](../03-daemon-cli-app.md) § Updater (The installer outlives the app) what happened to the root shell when the installer replaced the running app, and make Step 5f match it.

**Acceptance Criteria:**
- [ ] `swift build` and `swift build -c release --product SiteBlockApp` give no warnings.
- [ ] `scripts/test.sh` passes in full.
- [ ] `scripts/package.sh` produces `dist/SiteBlock.zip` and a `dist/version.json` that `UpdateCheck.parse` accepts.
- [ ] The live update test passes: the banner appears, a cancelled prompt changes nothing, a good update installs after the password, a corrupted download is refused without a prompt, and the blocks, password, delay and countdowns are unchanged afterwards.

# TASKS-10: SiteBlock for Windows
> **Corresponds to:** [06-windows.md](../06-windows.md)

**Goal:** A working SiteBlock for Windows that behaves the same way as the Mac version: the same blocking, unblocking, temporary unblocks, adult filter, self-repair, tray panel, command-line tool, installer and updater. The goal is met when every acceptance criterion below is checked, and the Windows workflow passes on GitHub's Windows machine, including the real install and the end-to-end checks.

**Scope:** everything under `windows/`, the workflow `.github/workflows/windows.yml`, the design plan `06-windows.md`, and a Windows section in the README.

**Prerequisites:** .NET 10 SDK on the build Mac (installed: 10.0.100). Pushing work in progress to the `windows` branch is allowed (see `CLAUDE.local.md`).

---

## Step 1: Solution skeleton

**File:** `windows/SiteBlock.sln`, `windows/Directory.Build.props`, `windows/version.props`, one `.csproj` per project
**Reference:** [06-windows.md](../06-windows.md) § Solution Layout
**Purpose:** Give every later step a project to put its code in, and make the whole solution build on the Mac.

**Sub-steps:**
- 1a. Create the six source projects and four test projects with the target frameworks in § Solution Layout.
- 1b. `Directory.Build.props`: `net10.0`, `LangVersion latest`, `Nullable enable`, `TreatWarningsAsErrors true`, `EnableWindowsTargeting true`, the version properties from `version.props`.
- 1c. `windows/version.props` holds `SiteBlockBuildNumber`, the release number kept by hand, next to `WindowsSeries` and `WindowsSeriesFirstBuild`.

**Acceptance Criteria:**
- [x] `dotnet build windows/SiteBlock.sln` succeeds on the Mac.

---

## Step 2: SiteBlock.Core

**File:** `windows/src/SiteBlock.Core/*.cs`
**Reference:** [02-core-components.md](../02-core-components.md) (every section), [06-windows.md](../06-windows.md) § SiteBlock.Core
**Purpose:** Port every rule of `SiteBlockCore` to C# with the same behavior.

**Sub-steps:**
- 2a. Text and domain rules: `DomainNormalizer`, `Punycode`, `DomainExpander`, `PathRuleParser`, `TabRuleMatcher`, `TabReloadDecider`, `HostsFileEditor`, `Formatting`, `TemporaryUnblockOptions`.
- 2b. `PasswordHasher` with PBKDF2-SHA256, compatible with the Swift hashes.
- 2c. `Models`, `Protocol` (JSON identical to Swift's), `Peer`, `Policy`, `Engine`, `StateStore`, `ConnectionLimiter`, `UninstallRule`.
- 2d. `BrowserBlockLists`, `BrowserTarget`, `BrowserPolicy.Capped`, `ChromePolicy.UrlBlocklist`, `WindowsBrowserPolicy`.
- 2e. `UpdateCheck` with the Windows addresses and asset name, `DNSProbePacket`, `FamilyDNSProbe`, `DaemonClient` over the named pipe.

**Dependencies:** Step 1.

**Acceptance Criteria:**
- [x] The Core builds with no warnings.
- [x] A `state.json` written by the Swift daemon loads, and the C# daemon's file loads in the Swift daemon.
- [x] A password hash made by Swift verifies in C#.

---

## Step 3: Service layer, siteblockd.exe and siteblock.exe

**File:** `windows/src/SiteBlock.Service/*.cs`, `windows/src/siteblockd/Program.cs`, `windows/src/siteblock/*.cs`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) §§ 1–7, 9–11, 13, 14; [06-windows.md](../06-windows.md) § Service Layer, § siteblock.exe CLI
**Purpose:** The daemon, the watchdog and the CLI, with Windows backends and sandbox backends.

**Sub-steps:**
- 3a. `Paths`, `Logger` (with rotation), `ProcessRunner`, `DaemonRuntime`, `PipeServer`.
- 3b. `HostsEnforcer` with the attribute, access-list and `DataBasePath` repairs.
- 3c. `IPolicyStore`, `RegistryPolicyStore`, `FilePolicyStore`, `BrowserPolicyEnforcer`.
- 3d. `IDnsSettingsBackend`, `WindowsDnsBackend`, `FileDnsBackend`, `DnsEnforcer` with the reachability check and change notices.
- 3e. `ServiceGuard`, the watchdog loop, `AppGuard` (with `CreateProcessAsUser`), `AclGuard`, `Uninstaller`.
- 3f. `siteblockd` flags and the service host; `siteblock` commands, password prompt and exit codes.

**Dependencies:** Step 2.

**Acceptance Criteria:**
- [x] A sandbox daemon on the Mac answers the CLI over the pipe and writes the sandbox hosts file, `registry.json` and `network-services.json`.
- [ ] On Windows the real install blocks youtube.com in the hosts file and in the four browsers' registry keys.

---

## Step 4: Tray app

**File:** `windows/src/SiteBlock.AppLogic/*.cs`, `windows/src/SiteBlockApp/**`
**Reference:** [03-daemon-cli-app.md](../03-daemon-cli-app.md) § 8, § 12, § 14–17; [06-windows.md](../06-windows.md) § Tray App
**Purpose:** The tray icon and panel with every Mac screen, the tab watcher and the updater.

**Sub-steps:**
- 4a. AppLogic models: `StatusModel`, panel state, row model, temporary unblock form, settings, banners.
- 4b. `TabWatcher` loop and `UiaBrowserTabs`.
- 4c. `Updater` flow, `HttpUpdateDownloader`, `UacElevatedRunner`.
- 4d. WPF: tray icon, single instance, flyout window, Mica, light and dark mode, every view.

**Dependencies:** Step 2.

**Acceptance Criteria:**
- [ ] On Windows the app starts, shows the tray icon, connects to the service, and can set a password, block a site, start and cancel an unblock, schedule a temporary unblock, and change settings.

---

## Step 5: Build, package, install, workflow

**File:** `windows/scripts/*.ps1`, `windows/Install SiteBlock.cmd`, `windows/INSTALL.txt`, `.github/workflows/windows.yml`
**Reference:** [06-windows.md](../06-windows.md) § Install, Package and Release
**Purpose:** Turn the code into a package a person can install, and make GitHub's Windows machine test it.

**Sub-steps:**
- 5a. `build.ps1`, `package.ps1`, `install.ps1`, `verify-install.ps1`, `Install SiteBlock.cmd`, `INSTALL.txt`.
- 5b. `e2e.ps1` with every check in [06-windows.md](../06-windows.md) § Testing, item 5.
- 5c. The workflow, with the release steps limited to `master`.

**Dependencies:** Steps 3 and 4.

**Acceptance Criteria:**
- [ ] The workflow passes on the `windows` branch, including `e2e.ps1`.

---

## Step 6: Tests, review, docs, release

**Reference:** [06-windows.md](../06-windows.md) § Testing; `CLAUDE.local.md` testing budget
**Purpose:** Prove the behavior and publish it.

**Sub-steps:**
- 6a. qa-engineer writes the tests in § Testing items 1–4; one test-rigor-auditor pass; one fix round.
- 6b. code-review-expert review and `/simplify`, then fixes.
- 6c. design-docs-updater brings `00-INDEX.md` and `06-windows.md` in line with what was built; README gets a Windows section.
- 6d. Merge to `master`; a push to `master` whose `SiteBlockBuildNumber` is higher than the published one publishes `windows-v<version>` and `windows-latest`.

**Acceptance Criteria:**
- [ ] Every test passes on the Mac and on GitHub's Windows machine.
- [ ] The download link `https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip` gives the package, and the Mac's `releases/latest` links still give the Mac package.

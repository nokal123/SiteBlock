# SiteBlock Design Plans — Index

## Quick Reference: File Overview

### [01-overview-and-data.md](01-overview-and-data.md)
**Open for:** requirements, how blocking works, architecture, threat model, data model, wire protocol, policy values, temporary unblock fields and commands
- What SiteBlock is and why it uses the hosts file instead of a browser extension or firewall
- Architecture diagram of the daemon, watchdog, CLI, app and socket
- What SiteBlock does and does not defend against
- Every persisted field, every protocol field, every command and its password rule

### [02-core-components.md](02-core-components.md)
**Open for:** SiteBlockCore library, domain parsing, Punycode, subdomain expansion, path rules, tab address matching, tab reload decisions, hosts file editing, password hashing, Engine command rules, temporary unblock checks and tick rule, the menu choices of the temporary unblock form, state file, socket client, duration formatting, version constants, the update check rules (version file, newer build, checksum)
- Pure logic with no root access, all unit-testable

### [03-daemon-cli-app.md](03-daemon-cli-app.md)
**Open for:** siteblockd flags, runtime loop, socket server, hosts enforcement, watchdog and self-repair, uninstall, CLI commands and exit codes, temporary unblock in the CLI and the panel, menu bar app screens, tab watcher, Apple Events bridge to Chrome, Edge and Brave, Automation permission, the Updater (daily check, banner, download, checks, install with the Mac password)

### [04-infrastructure.md](04-infrastructure.md)
**Open for:** repository layout, Package.swift, Swift Testing setup, installed paths, sandbox mode, launchd plists, build, Info.plist keys, install, upgrade, version numbers, `SiteBlock.zip` and `version.json`, automatic package builds

### [05-testing-and-operations.md](05-testing-and-operations.md)
**Open for:** unit and integration test lists, installed-system verification, live tab-watcher test, live update test, update check and script tests, security notes, logs, success criteria

### [06-windows.md](06-windows.md)
**Open for:** everything about SiteBlock for Windows: what stays the same as the Mac, how each Mac piece maps to Windows, the C# solution layout, the Windows service layer (flags, named pipe, hosts file, registry browser policy, adapter DNS, service and tray app guards, uninstall), the `siteblock.exe` CLI, the tray app (panel, tab watcher through UI Automation, updater), installed paths and access lists, install, package and release, the Windows threat model, Windows tests
- The Windows design only states what differs from the Mac design; every other rule is the Mac's, in files 01 to 05

---

## Source File → Design Plan Mapping

1. `Package.swift` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Package.swift
2. `Sources/SiteBlockCore/DomainNormalizer.swift` — **Primary:** [02-core-components.md](02-core-components.md) § DomainNormalizer
3. `Sources/SiteBlockCore/Punycode.swift` — **Primary:** [02-core-components.md](02-core-components.md) § Punycode
4. `Sources/SiteBlockCore/DomainExpander.swift` — **Primary:** [02-core-components.md](02-core-components.md) § DomainExpander
5. `Sources/SiteBlockCore/HostsFileEditor.swift` — **Primary:** [02-core-components.md](02-core-components.md) § HostsFileEditor
6. `Sources/SiteBlockCore/PasswordHasher.swift` — **Primary:** [02-core-components.md](02-core-components.md) § PasswordHasher
7. `Sources/SiteBlockCore/Models.swift` — **Primary:** [02-core-components.md](02-core-components.md) § Models and Protocol Types — **Also:** [01-overview-and-data.md](01-overview-and-data.md) § Data Model
8. `Sources/SiteBlockCore/Protocol.swift` — **Primary:** [01-overview-and-data.md](01-overview-and-data.md) § Wire Protocol
9. `Sources/SiteBlockCore/Engine.swift` — **Primary:** [02-core-components.md](02-core-components.md) § Engine
10. `Sources/SiteBlockCore/StateStore.swift` — **Primary:** [02-core-components.md](02-core-components.md) § StateStore
11. `Sources/SiteBlockCore/DaemonClient.swift` — **Primary:** [02-core-components.md](02-core-components.md) § DaemonClient
12. `Sources/SiteBlockCore/Formatting.swift` — **Primary:** [02-core-components.md](02-core-components.md) § Formatting
12a. `Sources/SiteBlockCore/TemporaryUnblockOptions.swift` — **Primary:** [02-core-components.md](02-core-components.md) § TemporaryUnblockOptions — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (the temporary unblock form)
13a. `Sources/SiteBlockCore/ConnectionLimiter.swift` — **Primary:** [02-core-components.md](02-core-components.md) § ConnectionLimiter — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SocketServer
13b. `Sources/SiteBlockCore/UninstallRule.swift` — **Primary:** [02-core-components.md](02-core-components.md) § UninstallRule — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § LaunchdGuard and Watchdog
13. `Sources/SiteBlockCore/Paths.swift` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Installed Paths
14. `Sources/siteblockd/main.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblockd Entry Point
15. `Sources/siteblockd/DaemonRuntime.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime
16. `Sources/siteblockd/SocketServer.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SocketServer
17. `Sources/siteblockd/HostsEnforcer.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer
18. `Sources/siteblockd/LaunchdGuard.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § LaunchdGuard and Watchdog
19. `Sources/siteblockd/LaunchdPlists.swift` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs
19b. `Sources/SiteBlockCore/ChromePolicy.swift`, `Sources/SiteBlockCore/BrowserPolicy.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer (and § 9 for the Chrome keys)
19c. `Sources/siteblockd/AppGuard.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § AppGuard
19e. `Sources/SiteBlockCore/DNSProbePacket.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § DNSEnforcer (Reachability check)
19f. `Sources/SiteBlockCore/FamilyDNSProbe.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § DNSEnforcer (Reachability check)
19d. `Sources/siteblockd/DNSEnforcer.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § DNSEnforcer
19g. `Sources/siteblockd/BrowserPolicyEnforcer.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer
19h. `Sources/SiteBlockCore/PathRuleParser.swift` — **Primary:** [02-core-components.md](02-core-components.md) § PathRuleParser
19i. `Sources/SiteBlockCore/TabRuleMatcher.swift` — **Primary:** [02-core-components.md](02-core-components.md) § TabRuleMatcher — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
19j. `Sources/SiteBlockCore/TabReloadDecider.swift` — **Primary:** [02-core-components.md](02-core-components.md) § TabReloadDecider — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
20. `Sources/siteblockd/Uninstaller.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Uninstaller
21. `Sources/siteblock/main.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI
21a. `Sources/siteblock/Commands.swift`, `Sources/siteblock/PasswordPrompt.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI
21b. `Sources/SiteBlockCore/UpdateCheck.swift` — **Primary:** [02-core-components.md](02-core-components.md) § UpdateCheck — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater, [04-infrastructure.md](04-infrastructure.md) § Packaging for Another Mac (the `version.json` it reads)
21c. `Sources/SiteBlockCore/BuildNumber.swift` (generated, ignored by git) — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Version Numbers — **Also:** [02-core-components.md](02-core-components.md) § Models and Protocol Types (Version constants)
22. `Sources/SiteBlockApp/*` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App
22d. `Sources/SiteBlockApp/Updater.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (the update banner and the Settings version line), [02-core-components.md](02-core-components.md) § UpdateCheck
22a. `Sources/SiteBlockApp/TabWatcher.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (StatusModel and the permission banner)
22b. `Sources/SiteBlockApp/ChromiumTabs.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromiumTabs — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
22c. `Sources/SiteBlockApp/Views/TemporaryUnblockForm.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (the temporary unblock form) — **Also:** [02-core-components.md](02-core-components.md) § TemporaryUnblockOptions
23. `Resources/Info.plist` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Build Script (including the `NSAppleEventsUsageDescription` key)
24. `scripts/build.sh`, `scripts/test.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Build Script — **Also:** [04-infrastructure.md](04-infrastructure.md) § Version Numbers
25. `scripts/install.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Install Script
25a. `scripts/package.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Packaging for Another Mac (including `SiteBlock.zip` and `version.json`)
25b. `.github/workflows/package.yml` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Automatic Package Builds
25c. `scripts/write-build-number.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Version Numbers — **Also:** [05-testing-and-operations.md](05-testing-and-operations.md) § Integration Tests (Script tests)
26. `scripts/verify-install.sh` — **Primary:** [05-testing-and-operations.md](05-testing-and-operations.md) § Installed-System Verification
27. `Install SiteBlock.command` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Install Script
28. `Tests/SiteBlockCoreTests/*` — **Primary:** [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests
29. `Tests/IntegrationTests/*` — **Primary:** [05-testing-and-operations.md](05-testing-and-operations.md) § Integration Tests

### Windows

30. `windows/src/SiteBlock.Core/*.cs` (the C# port of SiteBlockCore: `DomainNormalizer`, `Punycode`, `DomainExpander`, `PathRuleParser`, `TabRuleMatcher`, `TabReloadDecider`, `HostsFileEditor`, `PasswordHasher`, `Models`, `Protocol`, `Engine`, `StateStore`, `DaemonClient`, `Formatting`, `ConnectionLimiter`, `UninstallRule`, `TemporaryUnblockOptions`, `UpdateCheck`, `DNSProbePacket`, `FamilyDNSProbe`, `BrowserPolicy`, `ChromePolicy`, `WindowsBrowserPolicy`, `Peer`, `PipeNames`, `BuildInfo`, `JsonCoding`, `SwiftText`) — **Primary:** [06-windows.md](06-windows.md) § SiteBlock.Core (the C# port of SiteBlockCore) — **Also:** [02-core-components.md](02-core-components.md) (the rules each type implements)
31. `windows/src/SiteBlock.Service/DaemonRuntime.cs` — **Primary:** [06-windows.md](06-windows.md) § DaemonRuntime — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime
32. `windows/src/SiteBlock.Service/PipeServer.cs` — **Primary:** [06-windows.md](06-windows.md) § PipeServer — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SocketServer
33. `windows/src/SiteBlock.Service/ConsoleSession.cs` — **Primary:** [06-windows.md](06-windows.md) § Flags (the console user's SID)
34. `windows/src/SiteBlock.Service/HostsEnforcer.cs` — **Primary:** [06-windows.md](06-windows.md) § HostsEnforcer
35. `windows/src/SiteBlock.Service/PolicyStores.cs`, `windows/src/SiteBlock.Service/BrowserPolicyEnforcer.cs` — **Primary:** [06-windows.md](06-windows.md) § BrowserPolicyEnforcer — **Also:** [06-windows.md](06-windows.md) § SiteBlock.Core (Windows browser policy rules)
36. `windows/src/SiteBlock.Service/DnsBackends.cs`, `windows/src/SiteBlock.Service/DnsEnforcer.cs` — **Primary:** [06-windows.md](06-windows.md) § DNSEnforcer
37. `windows/src/SiteBlock.Service/ServiceGuard.cs` — **Primary:** [06-windows.md](06-windows.md) § ServiceGuard and the watchdog
38. `windows/src/SiteBlock.Service/ServiceControl.cs` (includes `ServiceConfigReader`) — **Primary:** [06-windows.md](06-windows.md) § ServiceGuard and the watchdog
39. `windows/src/SiteBlock.Service/Watchdog.cs` — **Primary:** [06-windows.md](06-windows.md) § ServiceGuard and the watchdog (Watchdog loop)
40. `windows/src/SiteBlock.Service/AppGuard.cs`, `windows/src/SiteBlock.Service/AppGuardNative.cs` — **Primary:** [06-windows.md](06-windows.md) § AppGuard
41. `windows/src/SiteBlock.Service/AclGuard.cs` — **Primary:** [06-windows.md](06-windows.md) § Installed Paths and Permissions
42. `windows/src/SiteBlock.Service/ProgramFolder.cs` — **Primary:** [06-windows.md](06-windows.md) § ServiceGuard and the watchdog (Program files) — **Also:** [06-windows.md](06-windows.md) § AppGuard
43. `windows/src/SiteBlock.Service/OwnershipNative.cs` — **Primary:** [06-windows.md](06-windows.md) § HostsEnforcer (The takeover) — **Also:** [06-windows.md](06-windows.md) § Installed Paths and Permissions
44. `windows/src/SiteBlock.Service/Uninstaller.cs` — **Primary:** [06-windows.md](06-windows.md) § Uninstaller
45. `windows/src/SiteBlock.Service/Paths.cs` — **Primary:** [06-windows.md](06-windows.md) § Installed Paths and Permissions (Sandbox)
46. `windows/src/SiteBlock.Service/Log.cs` — **Primary:** [06-windows.md](06-windows.md) § How Each Mac Piece Maps to Windows (log rotation) — **Also:** [06-windows.md](06-windows.md) § HostsEnforcer (Logging)
47. `windows/src/SiteBlock.Service/ProcessRunner.cs` — **Primary:** [06-windows.md](06-windows.md) § ServiceGuard and the watchdog (the `sc.exe` calls)
48. `windows/src/SiteBlock.Service/Contracts.cs` (service names and the enforcer and guard interfaces) — **Primary:** [06-windows.md](06-windows.md) § Flags (the two service names) — **Also:** [06-windows.md](06-windows.md) § DaemonRuntime
49. `windows/src/siteblockd/Program.cs` — **Primary:** [06-windows.md](06-windows.md) § Flags
50. `windows/src/siteblock/Program.cs` — **Primary:** [06-windows.md](06-windows.md) § siteblock.exe CLI
51. `windows/src/SiteBlock.AppLogic/*.cs` (`StatusModel`, `PanelModel`, `HomeModel`, `RowModel`, `SettingsModel`, `FormModels`, `Banners`, `Feedback`, `ToneColors`, `Defaults`, `ObservableModel`, `Interfaces`, `TabWatcher`, `Updater`, `UpdatePackage`) — **Primary:** [06-windows.md](06-windows.md) § Tray App (Structure) — **Also:** [06-windows.md](06-windows.md) § TabWatcher, § Updater
52. `windows/src/SiteBlockApp/**` (the WPF tray app: `Program.cs`, `TrayIcon.cs`, `PanelWindow.cs`, `Theme.cs`, `Ui.cs`, `OverlayScrollViewer.cs`, `NativeMethods.cs`, `WindowsServices.cs`, `app.manifest`, `Views/*`) — **Primary:** [06-windows.md](06-windows.md) § Tray App (The panel)
53. `windows/src/SiteBlockApp/UiaBrowserTabs.cs` — **Primary:** [06-windows.md](06-windows.md) § TabWatcher
54. `windows/scripts/build.ps1`, `windows/scripts/package.ps1`, `windows/scripts/write-build-number.ps1`, `windows/scripts/write-build-number.sh`, `windows/version.props`, `windows/BuildNumber.props` (generated, ignored by git) — **Primary:** [06-windows.md](06-windows.md) § Install, Package and Release
55. `windows/scripts/install.ps1`, `windows/Install SiteBlock.cmd`, `windows/INSTALL.txt` — **Primary:** [06-windows.md](06-windows.md) § Install, Package and Release
56. `windows/scripts/verify-install.ps1` — **Primary:** [06-windows.md](06-windows.md) § Install, Package and Release (the installer runs it) — **Also:** [06-windows.md](06-windows.md) § Testing
57. `windows/scripts/e2e.ps1` — **Primary:** [06-windows.md](06-windows.md) § Testing (items 5 to 7)
58. `.github/workflows/windows.yml` — **Primary:** [06-windows.md](06-windows.md) § Install, Package and Release (GitHub workflow)
58a. `windows/scripts/stats.sh` — **Primary:** [06-windows.md](06-windows.md) § Install, Package and Release (Download counts)
59. `windows/tests/*` (`SiteBlock.Core.Tests`, `SiteBlock.Integration.Tests`, `SiteBlock.AppLogic.Tests`, `SiteBlock.Windows.Tests`, `SiteBlock.UpdateProbe`) — **Primary:** [06-windows.md](06-windows.md) § Testing — **Also:** [06-windows.md](06-windows.md) § Solution Layout

---

## Topic Index

### Architecture & Flow
- Why the hosts file → [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works
- Process diagram → [01-overview-and-data.md](01-overview-and-data.md) § Architecture
- Threat model → [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits

### Data Model
- Persisted state fields → [01-overview-and-data.md](01-overview-and-data.md) § Data Model
- Countdown behavior → [02-core-components.md](02-core-components.md) § Models and Protocol Types

### Commands & Policy
- Command list and password rules → [01-overview-and-data.md](01-overview-and-data.md) § Commands
- Engine rules → [02-core-components.md](02-core-components.md) § Engine
- Fixed numbers (delay, lockout, recovery, temporary unblock window and start wait) → [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values

### Temporary Unblock
- What is stored for a temporary unblock → [01-overview-and-data.md](01-overview-and-data.md) § Data Model (TemporaryUnblock)
- Request fields, error codes and the status shape → [01-overview-and-data.md](01-overview-and-data.md) § Wire Protocol (Request, Response, TemporaryUnblockStatus)
- The two commands, and what `add`, `unblock` and the cancel commands do with a temporary unblock → [01-overview-and-data.md](01-overview-and-data.md) § Wire Protocol (Commands)
- Window and start wait limits → [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values
- What the hosts file and browser lists leave out while one is open → [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works (Temporary unblock), [02-core-components.md](02-core-components.md) § Engine
- Menu choices of the "For a while" form → [02-core-components.md](02-core-components.md) § TemporaryUnblockOptions
- Order of the command checks → [02-core-components.md](02-core-components.md) § Engine (Temporary unblock commands)
- How a tick opens and ends one → [02-core-components.md](02-core-components.md) § Engine (Temporary unblock tick rule)
- Older state files without the field → [02-core-components.md](02-core-components.md) § Models and Protocol Types, § StateStore
- Saving, re-enforcing at once and the log lines → [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime
- `unblock --for`, `--in`, `cancel` and the `status` lines → [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI
- The "For a while" and "For good" choice, the form and the waiting and open rows → [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (Panel states)
- Why the tab watcher skips a rule whose temporary unblock is open → [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
- Tests → [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests, § Integration Tests
- Implementation steps → [Tasks/TASKS-08-temporary-unblock.md](Tasks/TASKS-08-temporary-unblock.md)

### Versions and Updates
- The version people see (`1.2.0`, series plus a count that starts again at `.0`), the build number, how the build number is made → [04-infrastructure.md](04-infrastructure.md) § Version Numbers
- The generated `BuildNumber.swift` and `siteBlockVersion` → [04-infrastructure.md](04-infrastructure.md) § Version Numbers, [02-core-components.md](02-core-components.md) § Models and Protocol Types (Version constants)
- What GitHub publishes (`SiteBlock.zip`, `version.json`, the fixed download links) → [04-infrastructure.md](04-infrastructure.md) § Packaging for Another Mac, § Automatic Package Builds
- Why the workflow checks out the full history → [04-infrastructure.md](04-infrastructure.md) § Version Numbers, § Automatic Package Builds
- What `version.json` must contain, the newer-build rule and the checksum check → [02-core-components.md](02-core-components.md) § UpdateCheck
- The daily check, the banner, "Update" and "Not now", the phases and the install steps → [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater
- The Settings version line and "Check for updates" button → [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (Panel states)
- Why the password prompt comes from the app and why the installer must outlive it → [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater
- What an update keeps (blocks, password, delay, countdowns) → [01-overview-and-data.md](01-overview-and-data.md) § Architecture (Updates), [04-infrastructure.md](04-infrastructure.md) § Upgrade Behavior
- Limits (checksum proves integrity not authorship, no notarization, one manual update for older installs) → [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits (Limits of updates)
- Update interval and timeouts, state save interval → [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values
- Tests → [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests (UpdateCheckTests), § Integration Tests (Script tests), § Installed-System Verification (Live update test)
- Implementation steps → [Tasks/TASKS-09-update-check.md](Tasks/TASKS-09-update-check.md)

### Path Rules and Tab Watching
- Tab watcher (reloads a tab that moved to a blocked part of a site without loading a page) → [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
- In-page address changes (`pushState`) and what catches them → [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works (Blocking part of a site), [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
- Which tab addresses fall under a path rule → [02-core-components.md](02-core-components.md) § TabRuleMatcher
- Which tabs to reload, and why a tab is reloaded only once per address → [02-core-components.md](02-core-components.md) § TabReloadDecider
- Apple Events bridge to Chrome, Edge and Brave → [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromiumTabs
- Apple Events / Automation permission (the macOS prompt, refusal, the panel banner) → [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromiumTabs, § TabWatcher, § SiteBlock.app Menu Bar App (Panel states)
- `NSAppleEventsUsageDescription` and macOS asking again after an update → [04-infrastructure.md](04-infrastructure.md) § Build Script, § Upgrade Behavior
- Limits of tab watching (permission refused, half-second delay, Firefox, Safari) → [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits
- Live tab-watcher test → [05-testing-and-operations.md](05-testing-and-operations.md) § Installed-System Verification

### Tamper Resistance
- Hosts file self-repair → [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer
- Bypass-line removal → [02-core-components.md](02-core-components.md) § HostsFileEditor
- Daemon and watchdog guarding each other → [03-daemon-cli-app.md](03-daemon-cli-app.md) § LaunchdGuard and Watchdog
- Clock-change resistance → [01-overview-and-data.md](01-overview-and-data.md) § Countdown

### Install & Build
- Paths → [04-infrastructure.md](04-infrastructure.md) § Installed Paths
- Install and upgrade → [04-infrastructure.md](04-infrastructure.md) § Install Script
- Running tests without Xcode → [04-infrastructure.md](04-infrastructure.md) § Package.swift
- Version numbers, `SiteBlock.zip` and `version.json` → [04-infrastructure.md](04-infrastructure.md) § Version Numbers, § Packaging for Another Mac
- Failed test names on the public GitHub run page → [04-infrastructure.md](04-infrastructure.md) § Automatic Package Builds

### Windows
- What is the same as the Mac and what differs → [06-windows.md](06-windows.md) § What Is the Same on Both Systems, § How Each Mac Piece Maps to Windows
- Solution projects, which build on the Mac → [06-windows.md](06-windows.md) § Solution Layout
- `siteblockd.exe` flags, sandbox refusal rules, service start detection, console user → [06-windows.md](06-windows.md) § Flags
- Named pipe, its access list, how the caller is identified → [06-windows.md](06-windows.md) § PipeServer
- Hosts file repair, `DataBasePath`, takeover → [06-windows.md](06-windows.md) § HostsEnforcer
- Registry policy for Chrome, Edge, Brave and Firefox → [06-windows.md](06-windows.md) § SiteBlock.Core (Windows browser policy rules), § BrowserPolicyEnforcer
- Family DNS on adapters → [06-windows.md](06-windows.md) § DNSEnforcer
- Services, watchdog and tray app guards → [06-windows.md](06-windows.md) § ServiceGuard and the watchdog, § AppGuard
- Folder access lists → [06-windows.md](06-windows.md) § Installed Paths and Permissions
- Uninstall steps → [06-windows.md](06-windows.md) § Uninstaller
- Tray app, panel, tab watcher and updater → [06-windows.md](06-windows.md) § Tray App
- Installer, package, version numbers and the GitHub workflow → [06-windows.md](06-windows.md) § Install, Package and Release
- Windows limits → [06-windows.md](06-windows.md) § Threat Model on Windows
- Windows tests, the live tab-watcher test and the live update test → [06-windows.md](06-windows.md) § Testing
- Implementation steps → [Tasks/TASKS-10-windows.md](Tasks/TASKS-10-windows.md)

---

## Cross-Cutting Concerns

### Blocking a site end to end
The user types a site into the app or CLI. The client sends an `add` request over the socket. The daemon's engine normalizes and expands the name and adds it to the state, the runtime saves the state and runs an enforcement pass, which rewrites `/etc/hosts` and flushes the name cache, and only then is the response sent.
- **Client:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI, § SiteBlock.app Menu Bar App
- **Parsing and expansion:** [02-core-components.md](02-core-components.md) § DomainNormalizer, § DomainExpander
- **Policy:** [02-core-components.md](02-core-components.md) § Engine
- **Hosts file:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer

### Unblocking a site end to end
The client sends `unblock` with the password. The engine checks the password with lockout rules and starts a countdown equal to the delay. Every tick subtracts real elapsed time. When the countdown reaches zero the site is removed, the state is saved, and the next enforcement pass removes its lines from the hosts file. Opening a site for a chosen window and then blocking it again is a separate flow, described under "A temporary unblock from request to re-block".
- **Password:** [02-core-components.md](02-core-components.md) § PasswordHasher, § Engine
- **Timing:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime

### Staying installed
The daemon and watchdog each check every 5 seconds that the other is loaded and reload it if not. Uninstall goes through the password and the delay, then marks the state as uninstalling so the watchdog stands down.
- [03-daemon-cli-app.md](03-daemon-cli-app.md) § LaunchdGuard and Watchdog, § Uninstaller
- [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs

### A tab switches to a blocked part of a site without loading
Browsers check their block lists only when a page loads, and some sites change the address inside a page that is already open. The daemon's `status` reply lists every path rule, including rules that are waiting to unblock. The menu bar app's StatusModel hands that list to the TabWatcher every time it applies a snapshot, leaving out a rule whose own temporary unblock is open, because the browsers' block lists do not hold an open rule. While a rule exists and Chrome, Edge or Brave is running, the TabWatcher asks ChromiumTabs every half second for the address of every open tab, using Apple Events (the macOS mechanism one app uses to ask another app for data or to perform an action). TabRuleMatcher and TabReloadDecider pick the tabs whose address falls under a rule and have not already been reloaded at that address. ChromiumTabs reloads each of them. A reload is a real page load, so the browser checks the `URLBlocklist` the daemon wrote and shows its block page. If the person refuses the Automation permission (the macOS setting that lets one app control another), ChromiumTabs reports the refusal, the TabWatcher publishes the browser's name, and the panel shows a banner.
- **Rule list from the daemon:** [01-overview-and-data.md](01-overview-and-data.md) § Wire Protocol (StatusSnapshot), [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (StatusModel)
- **Address matching:** [02-core-components.md](02-core-components.md) § TabRuleMatcher
- **Deciding what to reload:** [02-core-components.md](02-core-components.md) § TabReloadDecider
- **Polling, permission handling and reloading:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
- **Apple Events to the browser:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromiumTabs
- **The block page the reload produces:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer
- **Permission text and prompt:** [04-infrastructure.md](04-infrastructure.md) § Build Script
- **Limits:** [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits

### A temporary unblock from request to re-block
The person picks a window (how long the site stays open), a start wait (the time before it opens), and types the password, either in the menu bar app's "For a while" form or with `siteblock unblock <site> --for <duration>`. The client sends `temporaryUnblock` (or `temporaryUnblockPath` for a path rule). The engine runs its checks in a fixed order: missing fields, the site name or rule text, whether the site or rule is blocked, whether it already has an unblock, the window range and the start wait range. A request that fails any of these is refused before the password is checked, so it never costs a password attempt. When the password is right, the engine sets the temporary unblock, and the runtime saves the state and runs an enforcement pass. The hosts file does not change yet, because the site stays blocked during the start wait. Every tick subtracts real elapsed time from the start wait. When it reaches zero, the tick reports a change, the runtime saves the state at once, and the enforcement pass in that same tick rewrites the hosts file and the browsers' policy files without the site (a host that another blocked site still needs stays) and flushes the name cache. The daemon logs that the temporary unblock opened, and the menu bar app's StatusModel stops passing an open path rule to the TabWatcher. The rest of each tick's time counts down the window. When the window reaches zero, the tick removes the temporary unblock and saves the state, the same pass writes the site's lines and entries back, and the daemon logs that the site is blocked again. At any point the person can end it without a password with "Keep blocked", "Block now", `siteblock cancel`, or by adding the site again, and the site is blocked again before that response returns.
- **Clients:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI, § SiteBlock.app Menu Bar App
- **Fields, commands and status shape:** [01-overview-and-data.md](01-overview-and-data.md) § Data Model, § Wire Protocol
- **Command checks and tick rule:** [02-core-components.md](02-core-components.md) § Engine
- **Saving, re-enforcing and log lines:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime
- **Hosts file:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer
- **Browser policy files:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer
- **Tab watcher rule filter:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
- **Limits and tests:** [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits, [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests, § Integration Tests

### An update from publish to install
A push to `master` that changes app code starts the GitHub workflow. It checks out the full history, so the commit count (the build number) is correct, runs the tests, and runs `scripts/package.sh`, which builds the programs with `scripts/write-build-number.sh` and writes `SiteBlock.zip` and `version.json` (the version, build number, commit, file name and the zip's SHA-256 checksum). The workflow replaces the "latest" release with both files, so the two download links never change. On each Mac, the menu bar app's `Updater` fetches `version.json` 60 seconds after the app starts, then every 24 hours, and when the person presses "Check for updates". `UpdateCheck.parse` accepts the file only when every field is well formed, and `UpdateCheck.isNewer` compares its build with the installed `siteBlockBuildNumber`. When the published build is newer and the person has not pressed "Not now" for it, the panel shows the banner. "Update" downloads the zip to a temporary folder, checks its checksum, unzips it, confirms that the expected files are present and that the three programs pass `codesign --verify --strict`, and copies the package to a staging folder. It then runs `scripts/install.sh` through an AppleScript `do shell script ... with administrator privileges` command, so macOS asks for the Mac password. The installer replaces the programs and restarts the jobs without touching `state.json`, the LaunchAgent starts the new app, and the new build number makes the banner disappear. A failed check shows a sentence in the banner and installs nothing.
- **Version and build number:** [04-infrastructure.md](04-infrastructure.md) § Version Numbers, [02-core-components.md](02-core-components.md) § Models and Protocol Types (Version constants)
- **Publishing the files:** [04-infrastructure.md](04-infrastructure.md) § Packaging for Another Mac, § Automatic Package Builds
- **Judging the files:** [02-core-components.md](02-core-components.md) § UpdateCheck
- **Checking, banner, download, checks and install:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater, § SiteBlock.app Menu Bar App
- **The installer that runs:** [04-infrastructure.md](04-infrastructure.md) § Install Script, § Upgrade Behavior
- **Limits and tests:** [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits, [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests, § Integration Tests, § Installed-System Verification

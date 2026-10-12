# SiteBlock Design Plans — Index

## Quick Reference: File Overview

### [01-overview-and-data.md](01-overview-and-data.md)
**Open for:** requirements, how blocking works, architecture, threat model, data model, wire protocol, policy values
- What SiteBlock is and why it uses the hosts file instead of a browser extension or firewall
- Architecture diagram of the daemon, watchdog, CLI, app and socket
- What SiteBlock does and does not defend against
- Every persisted field, every protocol field, every command and its password rule

### [02-core-components.md](02-core-components.md)
**Open for:** SiteBlockCore library, domain parsing, Punycode, subdomain expansion, path rules, tab address matching, tab reload decisions, hosts file editing, password hashing, Engine command rules, state file, socket client, duration formatting
- Pure logic with no root access, all unit-testable

### [03-daemon-cli-app.md](03-daemon-cli-app.md)
**Open for:** siteblockd flags, runtime loop, socket server, hosts enforcement, watchdog and self-repair, uninstall, CLI commands and exit codes, menu bar app screens, tab watcher, Apple Events bridge to Chrome, Edge and Brave, Automation permission

### [04-infrastructure.md](04-infrastructure.md)
**Open for:** repository layout, Package.swift, Swift Testing setup, installed paths, sandbox mode, launchd plists, build, Info.plist keys, install, upgrade, automatic package builds

### [05-testing-and-operations.md](05-testing-and-operations.md)
**Open for:** unit and integration test lists, installed-system verification, live tab-watcher test, security notes, logs, success criteria

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
22. `Sources/SiteBlockApp/*` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App
22a. `Sources/SiteBlockApp/TabWatcher.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (StatusModel and the permission banner)
22b. `Sources/SiteBlockApp/ChromiumTabs.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromiumTabs — **Also:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
23. `Resources/Info.plist` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Build Script (including the `NSAppleEventsUsageDescription` key)
24. `scripts/build.sh`, `scripts/test.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Build Script
25. `scripts/install.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Install Script
25a. `scripts/package.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Packaging for Another Mac
25b. `.github/workflows/package.yml` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Automatic Package Builds
26. `scripts/verify-install.sh` — **Primary:** [05-testing-and-operations.md](05-testing-and-operations.md) § Installed-System Verification
27. `Install SiteBlock.command` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Install Script
28. `Tests/SiteBlockCoreTests/*` — **Primary:** [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests
29. `Tests/IntegrationTests/*` — **Primary:** [05-testing-and-operations.md](05-testing-and-operations.md) § Integration Tests

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
- Fixed numbers (delay, lockout, recovery) → [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values

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
- Failed test names on the public GitHub run page → [04-infrastructure.md](04-infrastructure.md) § Automatic Package Builds

---

## Cross-Cutting Concerns

### Blocking a site end to end
The user types a site into the app or CLI. The client sends an `add` request over the socket. The daemon's engine normalizes and expands the name and adds it to the state, the runtime saves the state and runs an enforcement pass, which rewrites `/etc/hosts` and flushes the name cache, and only then is the response sent.
- **Client:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI, § SiteBlock.app Menu Bar App
- **Parsing and expansion:** [02-core-components.md](02-core-components.md) § DomainNormalizer, § DomainExpander
- **Policy:** [02-core-components.md](02-core-components.md) § Engine
- **Hosts file:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer

### Unblocking a site end to end
The client sends `unblock` with the password. The engine checks the password with lockout rules and starts a countdown equal to the delay. Every tick subtracts real elapsed time. When the countdown reaches zero the site is removed, the state is saved, and the next enforcement pass removes its lines from the hosts file.
- **Password:** [02-core-components.md](02-core-components.md) § PasswordHasher, § Engine
- **Timing:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime

### Staying installed
The daemon and watchdog each check every 5 seconds that the other is loaded and reload it if not. Uninstall goes through the password and the delay, then marks the state as uninstalling so the watchdog stands down.
- [03-daemon-cli-app.md](03-daemon-cli-app.md) § LaunchdGuard and Watchdog, § Uninstaller
- [04-infrastructure.md](04-infrastructure.md) § Launchd Jobs

### A tab switches to a blocked part of a site without loading
Browsers check their block lists only when a page loads, and some sites change the address inside a page that is already open. The daemon's `status` reply lists every path rule, including rules that are waiting to unblock. The menu bar app's StatusModel hands that list to the TabWatcher every time it applies a snapshot. While a rule exists and Chrome, Edge or Brave is running, the TabWatcher asks ChromiumTabs every half second for the address of every open tab, using Apple Events (the macOS mechanism one app uses to ask another app for data or to perform an action). TabRuleMatcher and TabReloadDecider pick the tabs whose address falls under a rule and have not already been reloaded at that address. ChromiumTabs reloads each of them. A reload is a real page load, so the browser checks the `URLBlocklist` the daemon wrote and shows its block page. If the person refuses the Automation permission (the macOS setting that lets one app control another), ChromiumTabs reports the refusal, the TabWatcher publishes the browser's name, and the panel shows a banner.
- **Rule list from the daemon:** [01-overview-and-data.md](01-overview-and-data.md) § Wire Protocol (StatusSnapshot), [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App (StatusModel)
- **Address matching:** [02-core-components.md](02-core-components.md) § TabRuleMatcher
- **Deciding what to reload:** [02-core-components.md](02-core-components.md) § TabReloadDecider
- **Polling, permission handling and reloading:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher
- **Apple Events to the browser:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromiumTabs
- **The block page the reload produces:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer
- **Permission text and prompt:** [04-infrastructure.md](04-infrastructure.md) § Build Script
- **Limits:** [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits

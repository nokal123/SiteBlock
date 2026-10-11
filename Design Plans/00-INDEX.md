# SiteBlock Design Plans — Index

## Quick Reference: File Overview

### [01-overview-and-data.md](01-overview-and-data.md)
**Open for:** requirements, how blocking works, architecture, threat model, data model, wire protocol, policy values
- What SiteBlock is and why it uses the hosts file instead of a browser extension or firewall
- Architecture diagram of the daemon, watchdog, CLI, app and socket
- What SiteBlock does and does not defend against
- Every persisted field, every protocol field, every command and its password rule

### [02-core-components.md](02-core-components.md)
**Open for:** SiteBlockCore library, domain parsing, Punycode, subdomain expansion, hosts file editing, password hashing, Engine command rules, state file, socket client, duration formatting
- Pure logic with no root access, all unit-testable

### [03-daemon-cli-app.md](03-daemon-cli-app.md)
**Open for:** siteblockd flags, runtime loop, socket server, hosts enforcement, watchdog and self-repair, uninstall, CLI commands and exit codes, menu bar app screens

### [04-infrastructure.md](04-infrastructure.md)
**Open for:** repository layout, Package.swift, Swift Testing setup, installed paths, sandbox mode, launchd plists, build, install, upgrade

### [05-testing-and-operations.md](05-testing-and-operations.md)
**Open for:** unit and integration test lists, installed-system verification, security notes, logs, success criteria

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
19a. `Sources/siteblockd/ChromePolicyEnforcer.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromePolicyEnforcer
19b. `Sources/SiteBlockCore/ChromePolicy.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § ChromePolicyEnforcer
19c. `Sources/siteblockd/AppGuard.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § AppGuard
20. `Sources/siteblockd/Uninstaller.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § Uninstaller
21. `Sources/siteblock/main.swift` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI
22. `Sources/SiteBlockApp/*` — **Primary:** [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App
23. `Resources/Info.plist` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Build Script
24. `scripts/build.sh`, `scripts/test.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Build Script
25. `scripts/install.sh` — **Primary:** [04-infrastructure.md](04-infrastructure.md) § Install Script
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

### Tamper Resistance
- Hosts file self-repair → [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer
- Bypass-line removal → [02-core-components.md](02-core-components.md) § HostsFileEditor
- Daemon and watchdog guarding each other → [03-daemon-cli-app.md](03-daemon-cli-app.md) § LaunchdGuard and Watchdog
- Clock-change resistance → [01-overview-and-data.md](01-overview-and-data.md) § Countdown

### Install & Build
- Paths → [04-infrastructure.md](04-infrastructure.md) § Installed Paths
- Install and upgrade → [04-infrastructure.md](04-infrastructure.md) § Install Script
- Running tests without Xcode → [04-infrastructure.md](04-infrastructure.md) § Package.swift

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

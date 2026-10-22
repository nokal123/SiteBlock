# SiteBlock for Windows
> Part of the SiteBlock Design Plans
> See also: [01-overview-and-data.md](01-overview-and-data.md), [02-core-components.md](02-core-components.md), [03-daemon-cli-app.md](03-daemon-cli-app.md), [04-infrastructure.md](04-infrastructure.md), [05-testing-and-operations.md](05-testing-and-operations.md)

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [What Is the Same on Both Systems](#what-is-the-same-on-both-systems)
3. [How Each Mac Piece Maps to Windows](#how-each-mac-piece-maps-to-windows)
4. [Solution Layout](#solution-layout)
5. [SiteBlock.Core (the C# port of SiteBlockCore)](#siteblockcore-the-c-port-of-siteblockcore)
6. [Service Layer (siteblockd.exe)](#service-layer-siteblockdexe)
7. [siteblock.exe CLI](#siteblockexe-cli)
8. [Tray App (SiteBlockApp.exe)](#tray-app-siteblockappexe)
9. [Installed Paths and Permissions](#installed-paths-and-permissions)
10. [Install, Package and Release](#install-package-and-release)
11. [Threat Model on Windows](#threat-model-on-windows)
12. [Testing](#testing)

---

## Executive Summary

SiteBlock for Windows is the same product as the Mac version, rebuilt for Windows 10 (version 2004, build 19041, or newer) and Windows 11, on x64 and Arm64 PCs. It blocks the sites a person chooses in every browser and app at once, it makes unblocking need the SiteBlock password and a waiting period, it can open a site for a chosen window of time, it always blocks adult websites, it repairs itself when someone tampers with it, and it updates itself from GitHub when the person agrees.

It is written in C# on .NET 10, the version of Microsoft's app platform installed on the build Mac. It has three programs, matching the Mac's three:

- `siteblockd.exe` runs as two Windows services (background programs that Windows starts at boot and runs under the built-in SYSTEM account, which may change system files). The `SiteBlock` service owns the block list and enforces it. The `SiteBlockWatchdog` service keeps the first one installed and running, and the first one does the same for it.
- `siteblock.exe` is the command-line tool, with the same commands as the Mac's `siteblock`.
- `SiteBlockApp.exe` is the tray app: a shield icon in the notification area (the icons beside the clock on the taskbar). Clicking it opens a panel with the same screens as the Mac's menu bar panel.

Everything the Mac version decides about blocking, unblocking, passwords, waits and temporary unblocks lives in `SiteBlock.Core`, a line-for-line C# port of `SiteBlockCore`. The Windows-only code is the part that talks to Windows: the hosts file, the registry (Windows' central settings database), the network adapters, the services, the named pipe the programs talk over, and the tray window.

---

## What Is the Same on Both Systems

The Windows version keeps every rule in [01-overview-and-data.md](01-overview-and-data.md) and [02-core-components.md](02-core-components.md) unless this file says otherwise:

1. **The policy values.** The 30-minute default delay, the 60-second to 7-day delay range, the 48-hour recovery and uninstall waits, the 5-minute to 4-hour temporary window, the start wait of at least the delay and at most 7 days, the 6-character password minimum, the 5-try lockout of 15 minutes, the 500-entry cap, the 2-second enforcement tick and the 5-second guard check.
2. **The data model.** `state.json` uses the same field names and the same JSON shapes, so the C# types read and write the same file the Swift types do. `savedDNS` is keyed by the network adapter's GUID (the adapter's permanent ID, such as `{4D36E972-E325-11CE-BFC1-08002BE10318}`) instead of a macOS service ID.
3. **The wire protocol.** One JSON line per request and one per response, with the same commands, fields, error codes and messages, carried over a named pipe instead of a Unix socket.
4. **The hosts file rules.** The same managed section with the same BEGIN and END markers, the same `0.0.0.0` and `::` lines, the same removal of user lines that point a blocked name somewhere real, and the same expansion of each site into its common host names.
5. **The browser block lists.** The same entries for Chrome, Edge, Brave and Firefox, including path rules, and the same adult-filter settings, written to the registry instead of property list files.
6. **The adult filter.** Cloudflare for Families on every network adapter except VPN adapters, with the same reachability check and the same fallback on sign-in Wi-Fi.
7. **The logging rule.** No password, domain or path rule is ever written to a log.
8. **The version scheme.** A build number equal to the commit count, and a version people see in the form `<series>.<n>`. The Windows series is `1.0` and starts counting at its own first build (see § Install, Package and Release).

---

## How Each Mac Piece Maps to Windows

Each item names the Mac piece, then what does the same job on Windows.

- **`/etc/hosts`** becomes `%SystemRoot%\System32\drivers\etc\hosts`. Windows also lets an administrator point the resolver at a different hosts folder through the registry value `DataBasePath` under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`. The service resets that value to `%SystemRoot%\System32\drivers\etc` on every pass, so moving the file is undone like editing it.
- **`chflags` immutable flags** become the read-only file attribute and the file's access list. Before each write the service clears the read-only, hidden and system attributes and, if the SYSTEM account was denied write access, takes ownership and resets the file's access list to the Windows default (SYSTEM and Administrators full control, Users read).
- **`dscacheutil -flushcache` and `killall -HUP mDNSResponder`** become a call to `DnsFlushResolverCache` in `dnsapi.dll`, which empties the Windows DNS Client's cache.
- **LaunchDaemons with `KeepAlive`** become two Windows services set to start automatically, each with recovery actions that restart it 5 seconds after it fails, three times, with the failure count reset after one day. Each service also checks the other every 5 seconds, so a service that was stopped on purpose, set to Disabled or deleted is brought back.
- **The Unix socket at `/var/run/siteblock.sock`** becomes the named pipe `\\.\pipe\siteblock` (a named pipe is a channel between programs on one computer that other programs reach by name). Its access list lets every signed-in user connect and exchange messages but never create a listening instance, and refuses the NETWORK group, so the pipe cannot be reached from another computer.
- **`LOCAL_PEERCRED` (the caller's user ID)** becomes the identity of the program on the other end of the pipe, read from that program's process token (see § PipeServer). "Root" means a caller that is SYSTEM, or a member of the Administrators group running with a full (elevated) token, which on Windows means a program started with "Run as administrator".
- **The owner of `/dev/console`** becomes the user signed in to the active console session (the session shown on the PC's own screen), read with `WTSGetActiveConsoleSessionId` and `WTSQuerySessionInformation`.
- **`/Library/Managed Preferences` property lists** become registry keys under `HKLM\SOFTWARE\Policies` (see § BrowserPolicyEnforcer).
- **SystemConfiguration DNS settings** become each adapter's static DNS servers, read from the registry and written with `SetInterfaceDnsSettings` from `iphlpapi.dll` (see § DNSEnforcer).
- **`SCDynamicStore` change notices** become `NetworkChange.NetworkAddressChanged` plus a registry change notice (`RegNotifyChangeKeyValue`) on the adapters' TCP/IP settings keys.
- **`ContinuousClock`** becomes `Environment.TickCount64`, the count of milliseconds since Windows started. It keeps counting while the PC sleeps and the person cannot change it.
- **The LaunchAgent that keeps the menu bar app running** becomes the `SiteBlock` value under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` (which starts the tray app at every sign-in) plus the service's AppGuard, which starts the tray app in the console user's session within 5 seconds whenever it is not running.
- **iCloud Private Relay** does not exist on Windows. The engine still writes `mask.icloud.com` and `mask-h2.icloud.com` with the other always-blocked names, because the engine is shared, and blocking them on Windows does no harm.
- **Apple Events tab reading** becomes UI Automation (the Windows accessibility interface that screen readers use to read and press controls in other apps). See § TabWatcher.
- **The macOS password prompt for updates** becomes the UAC prompt (User Account Control, the Windows dialog that asks before a program gets administrator rights). On an administrator account it asks "Yes" or "No"; on a standard account it asks for an administrator's password.
- **`newsyslog`** becomes size-based rotation inside the service's own logger: a log file over 1 MB is renamed to `.1` (older copies to `.2` and `.3`, the oldest deleted) before the next line is written.

---

## Solution Layout

```
windows/
├── SiteBlock.sln
├── Directory.Build.props         shared settings: .NET 10, C# latest, nullable on, warnings as errors
├── version.props                 WindowsSeries, WindowsSeriesFirstBuild
├── BuildNumber.props             the generated build number (ignored by git)
├── src/
│   ├── SiteBlock.Core/           net10.0 class library: the port of SiteBlockCore, no Windows calls
│   ├── SiteBlock.Service/        net10.0 class library: daemon runtime, pipe server, enforcers, guards,
│   │                             uninstaller; Windows backends and sandbox backends side by side
│   ├── siteblockd/               net10.0 console exe: flags, service host, watchdog loop
│   ├── siteblock/                net10.0 console exe: the CLI
│   ├── SiteBlock.AppLogic/       net10.0 class library: everything the tray app decides, testable without a window
│   └── SiteBlockApp/             net10.0-windows WPF exe: the tray icon and panel
├── tests/
│   ├── SiteBlock.Core.Tests/         xUnit, runs on macOS and Windows
│   ├── SiteBlock.Integration.Tests/  runs the real siteblockd.exe in sandbox mode over a real pipe
│   ├── SiteBlock.AppLogic.Tests/     xUnit, runs on macOS and Windows
│   ├── SiteBlock.Windows.Tests/      Windows-only: registry, ACL, DNS read, UI Automation backends
│   └── SiteBlock.UpdateProbe/        test-only console program that runs the tray app's real updater
│                                     against addresses given on its command line (used by e2e.ps1)
├── scripts/
│   ├── write-build-number.sh / .ps1
│   ├── build.ps1                 publishes the three programs into one self-contained folder
│   ├── package.ps1               writes dist/SiteBlock-Windows.zip and dist/version-windows.json
│   ├── install.ps1               the installer (run as administrator)
│   ├── verify-install.ps1        checks a real install
│   └── e2e.ps1                   the end-to-end test GitHub's Windows machine runs after a real install
├── Install SiteBlock.cmd         double-click installer: asks Windows for administrator rights, runs install.ps1
└── INSTALL.txt                   plain-text install steps that go inside the package
```

`SiteBlock.Core`, `SiteBlock.Service`, `siteblockd`, `siteblock` and `SiteBlock.AppLogic` target plain `net10.0`, so they build and their tests run on the Mac. Calls into Windows live behind small interfaces with a Windows implementation (marked `[SupportedOSPlatform("windows")]`) and a sandbox implementation that reads and writes files under the sandbox folder. Only `SiteBlockApp` targets `net10.0-windows`; it builds on the Mac with `EnableWindowsTargeting` but runs only on Windows.

**Program names:** Windows file names ignore letter case, so `siteblock.exe` and a `SiteBlock.exe` could not share a folder. The tray app is therefore `SiteBlockApp.exe`; its window title, tray tooltip and Task Manager description read "SiteBlock".

---

## SiteBlock.Core (the C# port of SiteBlockCore)

**Purpose:** Every rule from [02-core-components.md](02-core-components.md), in C#, with the same behavior on every input. It has no dependency outside the .NET base library.

**Naming:** namespace `SiteBlock.Core`. Each Swift type keeps its name (`DomainNormalizer`, `Punycode`, `DomainExpander`, `PathRuleParser`, `TabRuleMatcher`, `TabReloadDecider`, `HostsFileEditor`, `PasswordHasher`, `PersistedState`, `BlockedSite`, `BlockedPath`, `Countdown`, `TemporaryUnblock`, `PasswordHash`, `PendingDelayChange`, `Request`, `Response`, `StatusSnapshot`, `Command`, `ErrorCode`, `Engine`, `Policy`, `StateStore`, `DaemonClient`, `Formatting`, `ConnectionLimiter`, `UninstallRule`, `TemporaryUnblockOptions`, `UpdateCheck`, `UpdateInfo`, `DNSProbePacket`, `FamilyDNSProbe`, `BrowserBlockLists`, `BrowserTarget`). Methods and properties use .NET's PascalCase (`DomainNormalizer.Normalize`, `Engine.Handle`, `Engine.Tick`). Errors that Swift throws are C# exceptions of the same names (`DomainException` with a `DomainError` value, `PathRuleException`, `PasswordException`).

**JSON:** `System.Text.Json` with property names exactly as the Swift design writes them (`camelCase`, for example `remainingSeconds`, `passwordHash`, `blockedPaths`), enums as their string values, missing optional keys read as null, unknown keys ignored, and keys written in sorted order. A `state.json` written by either version reads in the other. The rule that an unreadable `temporaryUnblock` record is dropped while the rest of the file loads is kept.

**State file reads and writes:** `StateStore` reads files while letting other programs read, write, rename or delete them. A state file that another program holds open without sharing (a Windows sharing violation, error 32, or a lock violation, error 33, as an antivirus scan causes) is read again for about 3 seconds. When it is still locked after that, loading fails and the service does not start; its recovery action starts it again 5 seconds later. Starting fresh instead would let the next save overwrite the real blocks and password with an empty state. Only content that cannot be decoded, or a read that fails for any other reason, moves the file aside as `state.json.corrupt-<unix time>`, as on the Mac. The rename that replaces the state file with a newly written one is tried again for a moment while another program holds the old file open.

**Who is calling:** Swift passes `peerUID: uid_t` with 0 meaning root. C# passes a `Peer` record: `Peer(string UserId, bool IsAdmin)`, where `UserId` is the caller's Windows security ID (SID) as text, such as `S-1-5-21-…-1001`, and `IsAdmin` is true for SYSTEM and for an elevated administrator. Every rule that says "uid 0" or "root" uses `IsAdmin`. `Engine.ConsoleUser` is a `Func<string?>` that returns the SID of the console user, or null to allow any caller (sandbox and tests), replacing `consoleUID`. `ConnectionLimiter` counts by `UserId` and keeps its reserved slots for admin callers. `Peer.Unknown` (`UserId` `"unknown"`, `IsAdmin` false) is used when the identity cannot be read, so a failure never grants admin-only commands.

**Messages:** every reply sentence stays the same, except two that name a Mac command: the `recoveryStart` refusal reads "Password recovery can only be started by an administrator. Open Terminal or PowerShell with "Run as administrator" and run siteblock recover." and any "sudo" in a sentence is replaced by that same instruction. These are the only text differences, and the C# engine holds the Windows wording directly.

**Hashing and randomness:** `PasswordHasher` uses `Rfc2898DeriveBytes.Pbkdf2` with SHA-256, 210,000 iterations, a 16-byte salt from `RandomNumberGenerator`, and a 32-byte result compared with `CryptographicOperations.FixedTimeEquals`, so a hash made on one system verifies on the other.

**Clock:** the engine takes elapsed seconds and never reads a clock, as in Swift. The service measures elapsed time with `Environment.TickCount64` (see § Service Layer).

**Windows browser policy rules:** `WindowsBrowserPolicy` (in `SiteBlock.Core`, pure and unit-tested) turns a `BrowserTarget`, the browser lists and the adult-filter flag into the registry contents SiteBlock wants. Each target has one policy key and owns named values in it plus whole list subkeys:
- **Chrome** — key `SOFTWARE\Policies\Google\Chrome`: `SafeSitesFilterBehavior` (DWORD 1), `ForceGoogleSafeSearch` (DWORD 1), `DnsOverHttpsMode` (string `off`), and the subkey `URLBlocklist` whose values are named `1`, `2`, `3` … and hold one entry each (string).
- **Edge** — key `SOFTWARE\Policies\Microsoft\Edge`: `DnsOverHttpsMode` (string `off`), `ForceGoogleSafeSearch` (DWORD 1), `ForceBingSafeSearch` (DWORD 2), subkey `URLBlocklist`.
- **Brave** — key `SOFTWARE\Policies\BraveSoftware\Brave`: `DnsOverHttpsMode` (string `off`), `SafeSitesFilterBehavior` (DWORD 1), `ForceGoogleSafeSearch` (DWORD 1), subkey `URLBlocklist`.
- **Firefox** — key `SOFTWARE\Policies\Mozilla\Firefox`: subkey `DNSOverHTTPS` with `Enabled` (DWORD 0) and `Locked` (DWORD 1), and subkey `WebsiteFilter\Block` with values `1`, `2`, `3` … (string).

The list subkeys are left out when their list is empty, each list is capped at 1,000 entries with whole-site entries kept first (the same `BrowserPolicy.capped` rule), and the adult-filter values are left out only during an uninstall. Values SiteBlock does not own in those keys, and subkeys it does not own (such as Firefox's `WebsiteFilter\Exceptions`), are never changed. A value of the right name but the wrong type (a string `1` where a DWORD is wanted) counts as wrong and is rewritten, because a browser ignores a policy of the wrong type.

---

## Service Layer (siteblockd.exe)

### Flags

`siteblockd.exe` takes the same flags as the Mac's `siteblockd` (`--daemon`, `--watchdog`, `--sandbox <dir>`, `--tick <seconds>`, `--policy-fast`, `--version`, `--print-dns-plan`), with these differences:
- `--daemon` and `--watchdog` run under the Windows service control manager when Windows starts them as a service, and as a plain console process when started from a terminal (sandbox runs and tests). The two service names are `SiteBlock` (display name "SiteBlock") and `SiteBlockWatchdog` (display name "SiteBlock Watchdog").
- `--print-plist` does not exist. The service definitions are written by `ServiceGuard` from code, so a deleted service can always be recreated.
- On Windows, `--sandbox` is accepted when the process is elevated (started with "Run as administrator"). It is refused with exit code 64 when the sandbox folder is the same as, inside, or contains any of these three real folders: the hosts folder (`%SystemRoot%\System32\drivers\etc`), `C:\Program Files\SiteBlock` and `C:\ProgramData\SiteBlock`. Paths are compared without regard to letter case, a leading `\\?\` prefix (the form Windows uses for long paths) is ignored, and a drive root such as `C:\` contains everything on that drive. The reason is that a sandbox run must never write the real hosts file, and test machines such as GitHub's Windows runner run every test elevated, so refusing every elevated process would make the sandbox unusable there while refusing only the real folders keeps the real system safe.
- On macOS and Linux, `--sandbox` is refused with exit code 64 when the process runs as root, as on the Mac.
- `--daemon` and `--watchdog` decide whether Windows started them as a service by looking at the parent process: when the parent is `services.exe` (the Windows program that starts services) and the process is in session 0 (the session reserved for services), it runs as a service. In every other case it runs in the console. Ctrl+C and SIGTERM in a console run save the state and exit with code 0.
- The console user's SID (`ConsoleSession.cs`) comes from `WTSQueryUserToken` on the active console session, falling back to the session's account name when the token cannot be read. When nobody is signed in to the console, or the lookup fails, the answer is the SYSTEM SID, so only administrators may set the first password.
- `--version` prints `siteblockd <version> (build <n>)`.

### DaemonRuntime (`src/SiteBlock.Service/DaemonRuntime.cs`)

**Purpose:** The same job as [03-daemon-cli-app.md](03-daemon-cli-app.md) § DaemonRuntime: it owns the engine, runs the tick, saves state, repairs the state file and runs the enforcers.

**Key differences:**
- All engine access runs on one dedicated thread that takes work from a queue, so a command and a tick never run at once.
- Elapsed time comes from `Environment.TickCount64`, clamped to 0 through 604,800 seconds.
- A stop request from the service control manager, or Ctrl+C or SIGTERM in a console run, saves state and exits with code 0. The watchdog and the service recovery actions start it again.
- Startup first checks the pipe. When a live service already answers a `status` request, the process exits with code 1 before it saves or enforces anything, so a second copy can never overwrite the running copy's state. This check comes before the Mac's startup step 5.
- The tick timer and the guard timer start before the pipe is opened. When the pipe cannot be created (for example because another program created a pipe with the same name during a restart), the service does not exit. It keeps ticking and guarding, logs "cannot start the pipe server: <reason>; trying again every 5 seconds" once, and tries to create the pipe again every 5 seconds until it works.
- When the save of a newly recorded original DNS setting fails, the in-memory record goes back to what is on disk, so the next pass records it again.
- DNS passes are coalesced like ticks: at most one is queued while another runs, and further requests join the queued one.
- An uninstall waits at most 30 seconds for a guard pass that is already in progress to finish before it removes anything.
- In production, when the uninstall cleanup has not stopped the service within 2 minutes, the service exits so that Windows restarts it and the uninstall is tried again.
- Every other step (the rest of the startup order, the finished-uninstall check, the hand-set `uninstalling` check, the save rules, the catch-up before each command, the enforcement after each command, the answers during an uninstall, the log rules and the rejected-request summary) follows the Mac design exactly.

### PipeServer (`src/SiteBlock.Service/PipeServer.cs`)

**Purpose:** Accepts connections on `\\.\pipe\siteblock` and turns each into one request and one response, following [03-daemon-cli-app.md](03-daemon-cli-app.md) § SocketServer.

**Behavior:**
1. At startup, try to connect to the pipe. When a live daemon answers a `status` request, exit with code 1. Otherwise start serving.
2. Create pipe instances with `NamedPipeServerStreamAcl.Create`, byte mode, asynchronous, with an access list that gives Authenticated Users (`S-1-5-11`) only these rights: read data, write data, read attributes, read extended attributes and read permissions. The list never grants the right to create a new pipe instance, so no other program can add a listening instance to the pipe and pose as the service. SYSTEM and Administrators get full control, and everything is denied to NETWORK (`S-1-5-2`). Keep up to 32 instances waiting, so 32 connections can be open at once.
3. For each connected client, read the caller's identity from the client's process, not by impersonation (taking on the client's identity for a moment). The server calls `GetNamedPipeClientProcessId`, opens that process with `OpenProcess` and `PROCESS_QUERY_LIMITED_INFORMATION`, opens its token with `OpenProcessToken`, and reads the token's SID and whether it is SYSTEM or an elevated member of Administrators. A process whose creation time is later than the moment the connection was accepted is not trusted, because its process ID was reused after the real client exited; it gives `Peer.Unknown`, and so does any failure to read the identity. Windows refuses impersonation until the server has read data from the client, and reading identity before any data keeps the per-user connection limit in front of the read, so a client that never sends anything cannot hold a connection outside the limit.
4. Apply `ConnectionLimiter` by SID, read one line of at most 65,536 bytes with a 2-second limit, answer, and close, with the same `badRequest` answers as the Mac. After writing the reply the server waits up to 2 seconds for the client to hang up (a cancellable read), so the reply is never discarded by closing the pipe early, and a client that never reads cannot hold the connection past that limit.
5. Run the cheap domain and rule checks on the connection's own thread before queuing the request for the engine, as the Mac does. A handler that has not answered within 30 seconds produces an `internal` error reply.

The accept loop logs every failure and retries; it never ends on its own, so one bad connection cannot stop the service from listening.

In sandbox mode the pipe name is the full path `<sandbox>/siteblock.pipe`. On Windows that becomes `\\.\pipe\` plus a name made from the sandbox path. On macOS and Linux the pipe is a Unix socket at `<sandbox>/siteblock.pipe`, and a Unix socket path must be at most 103 bytes long, so the daemon refuses to start with a sentence that says the sandbox path is too long when the full path is longer. Identity in sandbox mode is always `Peer("sandbox-user", false)`, so `recoveryStart` from a test returns `notRoot`, as on the Mac.

`DaemonClient` connects with `NamedPipeClientStream`, uses the `SITEBLOCK_PIPE` environment variable when it is set (tests and sandbox runs), and keeps the Mac's error cases: `NotRunning` when the pipe does not exist or the connection is refused, `Timeout`, and `BadResponse`. On Windows it opens the pipe asking for exactly the rights the access list grants Authenticated Users, and it allows only Identification-level impersonation (the lowest level, which lets the server learn who the client is but never act as the client), so a program posing as the service can never act with the client's rights.

When the pipe is the installed service's pipe (`siteblock`, not a sandbox pipe), `DaemonClient` checks who serves it before it sends anything. It calls `GetNamedPipeServerProcessId` to learn which process is serving the pipe, opens that process with `OpenProcess` and `PROCESS_QUERY_LIMITED_INFORMATION`, opens its token with `OpenProcessToken`, and sends the request only when the token belongs to SYSTEM. When the server runs as any other account, `DaemonClient` sends nothing and reports `NotRunning`. The reason is that while the service restarts, another program could create a pipe with the same name and wait for the person to type a password into it.

### HostsEnforcer (`src/SiteBlock.Service/HostsEnforcer.cs`)

**Purpose:** The same job as [03-daemon-cli-app.md](03-daemon-cli-app.md) § HostsEnforcer, using `HostsFileEditor.Render`.

**Steps of one pass:**
1. **Check `DataBasePath`.** Each pass first compares the registry value `DataBasePath` with what Windows would read from it. A value stored as an expandable string (`REG_EXPAND_SZ`, a registry string whose `%Name%` parts Windows replaces with their values) is expanded first. A value stored as a plain string is taken literally, so a plain string that holds `%SystemRoot%\...` counts as wrong, because Windows would look for a folder with that literal name. When the value is wrong, the enforcer writes `%SystemRoot%\System32\drivers\etc` as `REG_EXPAND_SZ`, logs "hosts file location repaired" and flushes the DNS cache.
2. **Read the file.** The file is opened with read, write and delete sharing, so a program that has it open (an editor saving it) does not block the read. Its bytes are decoded without losing any of them: every valid UTF-8 sequence becomes its character, and each byte that is not part of valid UTF-8 (such as an accented letter in a comment saved in an older single-byte encoding) becomes its own placeholder character, U+DC00 plus the byte. Writing reverses this, so SiteBlock's own lines are always UTF-8 (the BEGIN marker's em dash included), the person's stray bytes go back exactly as they were, and a second pass reads the same text and changes nothing. Only a missing file counts as empty. When the access list refuses the read, the enforcer runs the takeover (below) and reads once more. A file that still cannot be read, or one that another program holds open, is left unchanged for that pass: the pass returns false and logs "hosts file could not be read, so it was left unchanged this pass" at most once a minute. Rewriting text that was never read would delete the person's own lines, so no write is attempted.
3. **Move a folder aside.** When a folder sits at the hosts path, it is renamed to `hosts.siteblock-moved-<random>` before the file is written, and the enforcer logs "a folder in place of the hosts file was moved aside".
4. **Write.** The enforcer computes the wanted text. When it differs from the file, the enforcer clears the read-only, hidden and system attributes, runs the takeover if needed, writes the text to a randomly named temp file in the same folder, moves it over the hosts file with `File.Move(…, overwrite: true)`, and falls back to writing in place when that fails. It then calls `DnsFlushResolverCache` and logs "blocks removed from hosts file" or "hosts file repaired" for changes that no command caused.

The written file keeps `\n` line endings, which the Windows resolver and Notepad both read.

**The takeover:** The enforcer first clears the read-only, hidden and system attributes. When that is refused, or when SYSTEM cannot open the file for writing, it switches on the `SeTakeOwnershipPrivilege` and `SeRestorePrivilege` privileges (rights a process holds but keeps switched off until it asks for them) for the process, once; they then stay on. It makes Administrators the owner of the file, because an owner may always rewrite the access list. In a second call it writes the default access list: SYSTEM and Administrators with full control, and Users, ALL APPLICATION PACKAGES and ALL RESTRICTED APPLICATION PACKAGES with read. It then clears the attributes again and logs "hosts file access list repaired". The take-ownership privilege is the one the takeover needs; the restore privilege is switched on as well when the account holds it, and its absence is not a failure. `OwnershipNative.cs` holds these calls, which the folder guard in § Installed Paths and Permissions also uses.

**Logging:** each failure message is logged at most once a minute, with the time kept separately for each message, so one lasting problem does not hide a different one. A failure names the error by its type and code (such as `IOException 0x80070020`) and never quotes .NET's error text, because that text holds file paths, including the random temp file's path, which would make the same failure a new message on every pass.

**Windows Defender:** Microsoft Defender can report a changed hosts file as `SettingsModifier:Win32/PossibleHostsFileHijack`, most of all when it blocks Microsoft's own names. SiteBlock never blocks Microsoft names on its own, but a person can type one. When Defender restores the file, the next pass writes the section back and logs "hosts file repaired". The installer does not add a Defender exclusion, because turning off scanning of a system file is not SiteBlock's decision to make.

### BrowserPolicyEnforcer (`src/SiteBlock.Service/BrowserPolicyEnforcer.cs`)

**Purpose:** Keeps the registry policy of every supported browser equal to what `WindowsBrowserPolicy` wants, on every enforcement pass, through an `IPolicyStore` interface.

- `RegistryPolicyStore` (Windows) reads and writes `HKLM` in the 64-bit registry view. Tests point it at a key under `HKCU` by giving it a root prefix, so they never touch the real policy keys.
- `FilePolicyStore` (sandbox) keeps the same keys and values in `<sandbox>/registry.json`, so tests can read and tamper with them. The file is one JSON object from key path to an object of values, and each value is written as `{"type":"string"|"dword","value":…}`. A value of another type or shape reads as the wrong type, which the pass then rewrites. A file that is not valid JSON reads as empty and is replaced on the next write.

A pass reads each target's key, compares every owned value by name, type and content and every owned list subkey value by value, and rewrites only what differs. A list subkey is made to hold exactly the wanted values by writing values `1` to `N` over the existing key and then removing any leftover values and subkeys. The key itself is never deleted on the way, so a browser that reloads its policy in the middle of a change never sees an empty list, and a stray value such as `1001` that was added by hand does not survive. Each browser is handled on its own, so a failure in one never stops the others. A pass that changes anything a command did not ask for logs "browser policy repaired (<browser>)".

The uninstall pass removes every owned value and list subkey and also deletes the keys SiteBlock emptied: Firefox's `DNSOverHTTPS` and `WebsiteFilter` subkeys, and each browser's policy key, each one only when nothing else is left in it. Chrome, Edge and Brave notice registry policy changes on their own within a few seconds; Firefox reads them when it starts.

### DNSEnforcer (`src/SiteBlock.Service/DnsEnforcer.cs`)

**Purpose:** The same job as [03-daemon-cli-app.md](03-daemon-cli-app.md) § DNSEnforcer, through an `IDnsSettingsBackend` interface with two implementations.

- `WindowsDnsBackend` lists adapters with `NetworkInterface.GetAllNetworkInterfaces()` and keeps the Ethernet and Wi-Fi ones that are not loopback. It skips tunnel and PPP adapters and any adapter whose description names a VPN (it contains `VPN`, `TAP-Windows`, `WireGuard`, `Wintun`, `OpenVPN`, `Tailscale`, `ZeroTier`, `AnyConnect`, `Fortinet`, `GlobalProtect` or `Cloudflare WARP`, compared without regard to case). It reads each adapter's static servers from the `NameServer` values under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\<GUID>` and the matching `Tcpip6` key, where an empty value means the adapter takes its servers from the network. It writes with `SetInterfaceDnsSettings`, once for IPv4 (`1.1.1.3,1.0.0.3`) and once with `DNS_SETTING_IPV6` (`2606:4700:4700::1113,2606:4700:4700::1003`). Writing an empty server list puts the adapter back on the network's servers. After a write it reads the values back.
- `FileDnsBackend` (sandbox) uses `<sandbox>/network-services.json` in the same shape as the Mac's sandbox file, keyed by adapter GUID. An entry may carry `"ipv6": false` to describe an adapter without IPv6 settings.

**Adapters without IPv6:** an adapter that has no key under the `Tcpip6` interfaces key has no IPv6 settings. It gets, and is expected to hold, only the two IPv4 family servers, and no IPv6 write is ever made to it.

**One adapter at a time:** each adapter is written on its own. An adapter whose write fails, or whose read-back differs from what was written, gets its original servers back and is left alone for 10 minutes, so one adapter that refuses the change never stops the others from being protected. A pass in which nothing needs to change writes nothing. The registry change watch skips a key that does not exist.

**Putting the saved servers back:** the same one-adapter-at-a-time rule applies when the saved servers are written back, both while the family servers are unreachable and during an uninstall. Each adapter is written on its own, so one adapter that refuses never stops the others from being restored. During an uninstall the saved record is kept while any adapter still lacks its original servers, so a retry can finish the restore.

**Windows before version 2004:** `SetInterfaceDnsSettings` does not exist on those versions, so a write there fails as an ordinary failed write and is handled like any other failure above.

**Log wording:** the log sentences keep the Mac's wording, such as "for N network services", where N counts adapters.

The reachability check (`FamilyDNSProbe`), the three-failure rule, the 30-second fallback timer, the "family DNS unreachable" fallback that puts the saved servers back on sign-in Wi-Fi, the saving of originals in `savedDNS` before the first change, and the restore during an uninstall all follow the Mac design. A change notice from `NetworkChange.NetworkAddressChanged` or from the registry change watch runs a pass within about a second.

### ServiceGuard and the watchdog (`src/SiteBlock.Service/ServiceGuard.cs`)

**Purpose:** Keeps both services installed, set to start automatically and running, so stopping, disabling or deleting one is undone within 5 seconds. It does the Mac's LaunchdGuard job.

**Files:** `ServiceGuard.cs` holds the decisions. `ServiceControl.cs` holds the `IServiceControl` interface and the real implementation, `ScServiceControl`. It reads a service's settings from its registry key `HKLM\SYSTEM\CurrentControlSet\Services\<name>`, where the service control manager keeps them, because those value names (`Start`, `Type`, `ImagePath`, `ObjectName`, `DependOnService`, `DependOnGroup`, `DeleteFlag`) are the same in every Windows language. It changes settings with `sc.exe` (always from `%SystemRoot%\System32`, with a 10-second limit per command) and starts and stops services with `ServiceController`. `ServiceConfigReader`, in the same file, turns the registry values into the settings the guard compares, and has no Windows calls, so its tests run on every platform.

**Key Methods:**
- `EnsureRunning(ServiceJob job)` — runs these steps in order:
  1. **Restore the program files** (see below).
  2. **Read the service's settings** from the registry. A missing key means the service is missing. A service marked for deletion (`DeleteFlag` set, which happens when it is deleted while running) also counts as missing, because Windows removes it as soon as it stops; recreating it fails, and is retried, until Windows has done so. When the key cannot be opened or read, the guard cannot know what the settings are, so it changes none of them, logs "could not read the <name> service's settings" at most once a minute, and still starts the service if it is stopped.
  3. **Recreate a missing service** with `sc create`: own process, start automatically, run as LocalSystem, the program path `"C:\Program Files\SiteBlock\siteblockd.exe" --daemon` or `--watchdog`, then set its recovery actions. When the create fails, the guard logs the failure and does not try to start the service that pass.
  4. **Repair the start settings.** When the start type is not automatic, or the program path is wrong, the guard sets them back and sets the recovery actions again (restart after 5 seconds, three times, reset after 86,400 seconds). It logs "service start type repaired" only when every step worked.
  5. **Repair the run settings.** The guard also checks the service type (own process, code 0x10), the account (LocalSystem, also accepted as `NT AUTHORITY\SYSTEM`) and the dependencies on other services or service groups (none). When any one is wrong, it puts all three back with `sc config <name> type= own obj= LocalSystem depend= /` and logs "service account and dependencies repaired" when that worked. A setting that could not be read is left alone. A made-up dependency can keep a service from ever starting, and an account other than SYSTEM cannot edit the hosts file, which is why these are checked.
  6. **Start the service** when it is stopped, logging "service restarted". A service that is still starting or stopping is left to finish.
- The constructor takes an optional `isCancelled` check, which must return true once an uninstall has begun. `EnsureRunning` asks it before each step that writes, so a pass that began just before an uninstall never recreates or restores what the uninstaller is removing.
- `StopAndDelete(ServiceJob job, TimeSpan timeout)` — used by the uninstaller. It stops the service, waits up to the timeout, deletes it, and then reads the settings again. It reports the service gone only when that fresh read succeeds and shows the service missing; a failed read proves nothing, so it does not count as gone.

**Logging of failures:** a repair is logged only when every step of it worked. A failed repair, a failed create, a failed start and an unreadable service are each logged at most once a minute, with the time kept per message, and a message names the service so one service's lasting problem never hides the other's. The minute is measured with `Environment.TickCount64`, so setting the clock back cannot silence the log.

**Program files:** the programs are published as many files: a small launcher `.exe` plus its `.dll` files and the .NET runtime files. A deleted or renamed `.dll` would stop both services at their next start even when `siteblockd.exe` looks fine, so the guard compares every file in `C:\ProgramData\SiteBlock\backup\app\` with `C:\Program Files\SiteBlock\` by size and copies back each file that is missing or different. When `siteblockd.exe` itself was copied back it logs "siteblockd.exe restored from backup", and when any other file was copied back it logs "program files restored from backup". A backup with no `siteblockd.exe` counts as unusable and nothing is restored from it; that is logged only when the program itself is also gone. A copy that fails, for example because a running program holds the file open, is logged once a minute and tried again on the next pass. Each file is copied to a temporary name beside it and then moved over the target in one step, so a program that starts mid-restore never loads a half-written file, and the up to three guards that restore the same folder (the daemon's two and the watchdog's one) each finish whole files. `ProgramFolder.cs` holds this comparison and copy for both `ServiceGuard` and `AppGuard`.

**Watchdog loop (`siteblockd.exe --watchdog`, `src/SiteBlock.Service/Watchdog.cs`):** every 5 seconds read `state.json`; when `UninstallRule.WatchdogShouldStandDown` says a finished uninstall is recorded, do nothing; otherwise `EnsureRunning(Daemon)`. The watchdog opens `state.json` with read, write and delete sharing, so its read never makes the daemon's save fail (the daemon replaces the file by moving a new one over it, which Windows refuses while another handle lacks delete sharing). A file it cannot read counts as no finished uninstall, so the watchdog keeps guarding. A check that throws is logged as "watchdog check failed (<error type>)" at most once a minute, and the loop goes on, because a stopped watchdog would leave the daemon unguarded. The daemon runs `EnsureRunning(Watchdog)` on its own 5-second guard timer.

**Stopping:** both services accept the stop request, because the installer and the uninstaller must stop them. A person with administrator rights who stops one sees it start again within 5 seconds, because the other restarts it. This matches the Mac, where `launchctl bootout` of one job is undone by the other.

### AppGuard (`src/SiteBlock.Service/AppGuard.cs`)

**Purpose:** Keeps the tray app installed and running for the person at the screen, as [03-daemon-cli-app.md](03-daemon-cli-app.md) § AppGuard does on the Mac. Every 5 seconds:
1. **File check.** Every file in `C:\ProgramData\SiteBlock\backup\app\` is compared with the file of the same name in `C:\Program Files\SiteBlock\` by size, the same whole-folder comparison `ServiceGuard` makes, because the app is a launcher `.exe` plus `.dll` and .NET runtime files and a missing `.dll` breaks it as surely as a missing `.exe`. Each missing or different file is copied back and "tray app restored" is logged. A missing or incomplete backup stops only this restore (logged at most once a minute). The check in step 2 still runs, and an installed app is still kept running; only when there is no app at all is there nothing to start.
2. **Start-at-sign-in check.** The `SiteBlock` value under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` must hold the quoted path of `SiteBlockApp.exe`; it is rewritten when missing or different.
3. **Running check (production only).** When a user is signed in to the console session and the real app is not running in that session, the guard starts it as that user: it gets the user's token with `WTSQueryUserToken`, builds the user's environment with `CreateEnvironmentBlock`, and calls `CreateProcessAsUser` on the `winsta0\default` desktop, with a quoted command line so a path with spaces stays in one piece. The app then runs with the user's normal rights, not SYSTEM's. It logs "tray app restarted", and a failed start is logged with its Win32 error code.
   - **What counts as running:** only a `SiteBlockApp.exe` process in the console session whose full program path, read with `QueryFullProcessImageName`, is `C:\Program Files\SiteBlock\SiteBlockApp.exe`. Another program renamed to `SiteBlockApp.exe` cannot stand in for the app. A process whose path cannot be read counts as running, because starting a second app beside a real one would open its panel.
   - **Start spacing:** starts are at least 5 seconds apart, so the guard does not launch the app again while it is still coming up. A just-restored app skips this wait. After three starts in a row that each came within 30 seconds of the previous one, the app is closing right after it starts, so starts are one minute apart and the guard logs "the tray app keeps closing right after it starts; trying again once a minute" at most once a minute. Starts stay one minute apart until the guard sees the app still running 30 seconds or more after a start, which resets the count.

The once-a-minute log rule applies to each kind of failure separately, and the guard stops at once when an uninstall has begun.

### Uninstaller (`src/SiteBlock.Service/Uninstaller.cs`)

**Steps, in order (production):**
1. Save the state with `uninstalling = true`; stop the uninstall when this save fails.
2. Stop the `SiteBlockWatchdog` service, wait up to 10 seconds, and delete it. When the watchdog cannot be stopped and deleted, the uninstall stops here with exit code 1, and it is tried again after the service restarts.
3. Remove the hosts section, remove every owned browser policy value and list subkey, restore the saved DNS servers, and flush the DNS cache.
4. Stop every `SiteBlockApp.exe` process and delete the `Run` value.
5. Delete the backup folder, the state backup, the folder's entry in the system `PATH`, and the Start menu shortcut.
6. Start a detached, hidden `powershell.exe` (not `cmd.exe`) that waits 2 seconds, stops the `SiteBlock` service, waits up to 30 seconds for `siteblockd.exe` to exit, deletes the service with `sc.exe delete`, and then deletes `C:\Program Files\SiteBlock` and `C:\ProgramData\SiteBlock`, trying each folder up to 10 times with one second between tries. A child started by a service keeps running after the service stops, so it outlives the daemon. Before any deletion, the uninstaller checks that each of the two folder paths is fully qualified (it starts at a drive root and has no relative parts) and that its last part is `SiteBlock`, so a mistaken path can never make it delete another folder.

In sandbox mode steps 2, 4, 5 and 6 are replaced by deleting `<sandbox>/siteblock.pipe`, `<sandbox>/app/SiteBlockApp.exe` and the folder `<sandbox>/backup/app`, then exiting with code 0. The sandbox run never flushes the DNS cache.

---

## siteblock.exe CLI

**Purpose:** The same commands, output, options and exit codes as [03-daemon-cli-app.md](03-daemon-cli-app.md) § siteblock CLI and § Path rules in the app and CLI.

**Differences:**
- Passwords are read with `Console.ReadKey(intercept: true)`, so nothing shows while typing, and from the first line of standard input when input is redirected.
- Piped standard input is read as UTF-8, and a leading byte-order mark (the invisible character some programs put at the very start of text) is dropped. Output is written as UTF-8, and the console's code page (the setting that decides how the console shows characters) is restored when the program exits.
- `siteblock recover` must run from an elevated terminal; from a normal one the daemon answers `notRoot` with the Windows sentence from § SiteBlock.Core.
- The installer adds `C:\Program Files\SiteBlock` to the system `PATH`, so `siteblock` works in any new terminal.
- Exit code 2 means the pipe does not exist or refuses the connection.

---

## Tray App (SiteBlockApp.exe)

### Structure

- `SiteBlock.AppLogic` holds every decision the app makes, with no window code: `StatusModel` (polling once a second while the panel is open and every 30 seconds otherwise, skipping an answer equal to the one shown), the panel state (not running, first block, normal, settings), the row model (which buttons, which line, which tone), the temporary unblock form model, the `Updater` flow and the `TabWatcher` loop. Each talks to the outside through an interface (`IDaemonClient`, `IBrowserTabs`, `IUpdateDownloader`, `IElevatedRunner`, `IClock`), so its tests run on the Mac with test doubles.
- `SiteBlockApp` is the WPF app (Windows Presentation Foundation, Microsoft's toolkit for desktop windows). It shows a tray icon with the Windows Forms `NotifyIcon`, and a panel window that binds to the AppLogic models. It runs as a single instance: the first copy holds the mutex (a named lock that only one program can hold at a time) `Local\SiteBlockApp.SingleInstance`, and a second start finds that the mutex is taken, signals the named event `Local\SiteBlockApp.OpenPanel`, and exits, which makes the first copy open its panel.

The status polling loop and the daily update check each survive a failed iteration: an error in one pass is caught, and the loop runs again at the next interval.

The tray app logs to `%LOCALAPPDATA%\SiteBlock\Logs\app.log`. A log file larger than 1 MB is renamed to `app.log.1` before the next line is written.

### The panel

The panel is a borderless window, 440 pixels wide at 100% scaling, that opens just above the tray icon (or beside it when the taskbar is on another edge, using the work area from `SystemParameters.WorkArea`) and hides when it loses focus, like the Windows clock and volume flyouts. On Windows 11 it uses the Mica backdrop (the frosted, see-through window material Windows 11 uses for its own panels, set with `DwmSetWindowAttribute` and `DWMWA_SYSTEMBACKDROP_TYPE`) and rounded corners; on Windows 10 it uses a solid background in the system's light or dark color. It follows the Windows light or dark app mode (`AppsUseLightTheme` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`) and switches when it changes. Text uses Segoe UI Variable, or Segoe UI on Windows 10. Its scroll bars are thin overlay bars with no track, so the see-through panel shows through.

Every screen, field, button label, message, banner, row line and countdown is the Mac's, from [03-daemon-cli-app.md](03-daemon-cli-app.md) § SiteBlock.app Menu Bar App, with the same `SiteTone` colors (brick red `#9E3A2F` / `#E08A78`, pine green `#3D6B4A` / `#8CC29B`, button fills `#9E3A2F` / `#B04A3D`), the same 7% and 13% fills and 22% and 30% edges, and the same lock icons drawn from the Segoe Fluent Icons font (or Segoe MDL2 Assets on Windows 10). The only differences:
- The "not running" screen tells the person to double-click `Install SiteBlock.cmd` again.
- The row of a site whose permanent unblock is pending reads "Still blocked · unblocks in 29:41", the same wording as the Mac app.
- The note under the parts-of-sites choice reads "Works in Chrome, Firefox, Edge and Brave. Other browsers can only block whole sites."
- There is no Automation-permission banner, because Windows does not ask permission for UI Automation.
- The tray icon is the shield, or a shield with a slash when the service cannot be reached. Its right-click menu has "Open SiteBlock" and "Settings" and no Exit, because the app always stays running, as on the Mac.

### TabWatcher (`src/SiteBlock.AppLogic/TabWatcher.cs` and `src/SiteBlockApp/UiaBrowserTabs.cs`)

**Purpose:** The same job as [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher: reload a Chrome, Edge or Brave tab that moved onto a blocked part of a site without loading a page, so the browser's block list shows its block page.

**How it reads tabs:** UI Automation can read the address bar of each browser window, which shows the address of that window's visible tab. A page can only change its address without a load while it is the tab being looked at, so reading the visible tab of every window covers that case. `UiaBrowserTabs` (Windows) does this every 0.5 seconds while at least one path rule exists and a browser runs:
1. List the processes named `chrome`, `msedge` and `brave`, and their top-level windows of class `Chrome_WidgetWin_1` that are visible and have a title.
2. In each window, find the address bar: the element whose class name is `OmniboxViewViews` and whose control type is Edit. The element is remembered per window, so the search runs once per window. Class names do not change with the browser's language, while visible names do.
3. Read its text with the Value pattern. Skip the window while the address bar has keyboard focus, because the person may be typing. Browsers hide `https://` and sometimes `www.`, so text with no scheme gets `https://` in front before it is matched.
4. Feed each process's windows to `TabReloadDecider`, with the window handle as the tab ID.
5. To reload, find the window's toolbar button whose class name is `ReloadButton` and press it with the Invoke pattern, after reading the address bar again and checking that the address still matches a rule.

The same `TabRuleMatcher`, `TabReloadDecider` and rule list (`watchedPathRules`) as the Mac are used. The log line for a reload reads "reloaded a <browser name> tab on a blocked part of a site". It does not name the rule, because no path rule is ever written to a log (§ What Is the Same on Both Systems, item 7). `deniedBrowserNames` is always empty on Windows. A browser whose window exposes no address bar to UI Automation is skipped; its path rules then apply when a page loads.

**Limits:** a background tab that changes its address by itself is not seen until it becomes the visible tab. Firefox is not watched, as on the Mac.

### Updater (`src/SiteBlock.AppLogic/Updater.cs`)

**Purpose:** The same job as [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater, with the same phases, banner sentences, timing (60 seconds after start, then every 24 hours, plus the Settings button) and "Not now" rule. The dismissed build is saved under `HKCU\Software\SiteBlock` as the DWORD `DismissedUpdateBuild`.

**Addresses:** `https://github.com/nokal123/SiteBlock/releases/download/windows-latest/version-windows.json` and `https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip`, held in `UpdateCheck` as `WindowsVersionUrl` and `WindowsPackageUrl`. `UpdateCheck.Parse` takes the expected asset name, which is `SiteBlock-Windows.zip` for Windows.

**Installing:**
1. Download the zip into a new folder under the user's temp folder, with a 5-minute limit.
2. Check its SHA-256 against `version-windows.json`, unzip it, and check that it holds `SiteBlock\bin\siteblockd.exe`, `SiteBlock\bin\siteblock.exe`, `SiteBlock\bin\SiteBlockApp.exe`, `SiteBlock\scripts\install.ps1` and `SiteBlock\Install SiteBlock.cmd`. Any failure gives "The update didn't pass its checks, so nothing was installed." and deletes the folder.
3. Start `powershell.exe` with the `runas` verb, which makes Windows show the UAC prompt "Do you want to allow this app to make changes to your device?". The update step is passed to PowerShell with `-EncodedCommand` (the script given to PowerShell as Base64 text). The elevated PowerShell copies the zip into a fresh folder under `C:\ProgramData\SiteBlock\update-<random>` that only SYSTEM and Administrators can write, checks the SHA-256 of the copy again, unzips it there, and checks the layout again (the same five required files, read from `bin\<arch>\` for this PC's processor) before it runs that copy's `install.ps1`, writing its output to `C:\ProgramData\SiteBlock\Logs\update.log`. Checking again after the copy means a file swapped in the user's temp folder after the first check is never run as administrator. When either of the two checks fails, the elevated step runs nothing and exits with code 3, which the tray app shows as "The update didn't pass its checks, so nothing was installed." Any other non-zero exit code shows "The install didn't finish. Details are in C:\ProgramData\SiteBlock\Logs\update.log." When the elevated step cannot be started at all, the app shows "The installer couldn't be started, so nothing was installed." Pressing "No" in the UAC prompt gives "The update was cancelled." and changes nothing. The elevated PowerShell deletes nothing outside its own protected `update-<random>` folder. The app deletes its download folder in the person's temp folder itself once the update ends, because a recursive delete running as administrator in a folder the person can change could be led through a planted link (a junction, a folder that points to another folder) to other files.
4. `install.ps1` stops the old tray app, replaces the programs and restarts the services; the service's AppGuard then starts the new tray app as the signed-in user within 5 seconds. The elevated PowerShell is its own process, so the install finishes even though the old app is stopped.

**Limits:** the programs are not signed with a code-signing certificate, so the checksum proves the download is complete, not who made it, as on the Mac. Windows SmartScreen (the Windows check that warns about programs downloaded from the internet that few people have run) warns on the first install; the README and `INSTALL.txt` explain "More info" → "Run anyway".

---

## Installed Paths and Permissions

- Programs: `C:\Program Files\SiteBlock\` holding `siteblockd.exe`, `siteblock.exe`, `SiteBlockApp.exe` and the .NET runtime files they share.
- Backup of the programs: `C:\ProgramData\SiteBlock\backup\app\` (a full copy of the program folder).
- State: `C:\ProgramData\SiteBlock\state\state.json`; state backup: `C:\ProgramData\SiteBlock\backup\state.backup.json`.
- Logs: `C:\ProgramData\SiteBlock\Logs\siteblockd.log`, `watchdog.log`, and the update log `update.log`.
- Pipe: `\\.\pipe\siteblock`.
- Hosts file: `%SystemRoot%\System32\drivers\etc\hosts`.
- Browser policies: the four keys in § SiteBlock.Core, Windows browser policy rules.
- Services: `SiteBlock` and `SiteBlockWatchdog`.
- Start at sign-in: the `SiteBlock` value under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`.
- Start menu shortcut: `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\SiteBlock.lnk`.

**Access lists:** `C:\ProgramData` lets ordinary users create files in new subfolders, so the installer and the service set an explicit access list on `C:\ProgramData\SiteBlock` that does not inherit from its parent: full control for SYSTEM and Administrators, read and run for Users. The `state` folder gives Users nothing, so other accounts cannot read the password hash. The backup folder `C:\ProgramData\SiteBlock\backup` gets the same list as the state folder, SYSTEM and Administrators only and not inheriting, because it holds `state.backup.json`, a copy of the state with the password hash. `install.ps1` sets all of these and the guard keeps them. `C:\Program Files\SiteBlock` keeps the default Program Files list, which already stops ordinary users from writing.

**The guard pass (`src/SiteBlock.Service/AclGuard.cs`):** on every guard pass the guard does the following, and it never throws; failures are logged at most once a minute, without any path.
1. It recreates any missing folder (the data, state, log, backup and program backup folders). When a file sits at a folder's path, it renames that file to `<name>.siteblock-moved-<random>` first, because a file at the path would make every save into the folder fail.
2. It checks the owner of the data, state and backup folders. An owner may always rewrite a folder's access list, so an owner other than SYSTEM or Administrators, such as an ordinary user who created `C:\ProgramData\SiteBlock` before the install, is replaced by Administrators and "<folder> owner repaired" is logged. `install.ps1` sets the same owner with `icacls /setowner`.
3. It compares the data, state and backup folders' access lists with the wanted ones and rewrites only those that differ, so a healthy system produces no writes and no log lines. Two lists match when both are protected or both are not and they hold the same entries in any order; the auto-inherited flags Windows adds on its own are ignored, so a list read back in a different order is not rewritten on every pass.
4. It checks each file directly in the state folder, and `state.backup.json`. A file that has access-list entries of its own, or that is protected from inheriting, is reset so it holds only what it inherits from its folder. An entry added to one file, such as "Users may read state.json", would otherwise survive any repair of the folder.
5. When SYSTEM is locked out of a folder or file, the guard takes ownership of it, in the same way as the hosts file takeover in § HostsEnforcer, and writes the list again. A file that vanishes mid-check, such as the temporary file the daemon renames into place when it saves the state, is skipped without a log line.

These lists stop ordinary users. An administrator keeps full control, as § Threat Model on Windows says.

**Sandbox:** `Paths.Sandbox(root)` puts every file under the given folder (`root/hosts`, `root/state/state.json`, `root/backup/state.backup.json`, `root/registry.json`, `root/network-services.json`, `root/app/SiteBlockApp.exe`, `root/backup/app/SiteBlockApp.exe`, `root/siteblock.pipe`, `root/logs/`), as the Mac's sandbox does.

---

## Install, Package and Release

**build.ps1** runs `write-build-number`, then `dotnet publish` for `siteblockd`, `siteblock` and `SiteBlockApp` in Release mode, self-contained (the .NET runtime ships inside the folder, so the PC needs nothing installed), for one runtime (`win-x64` or `win-arm64`), into one shared output folder `windows/build/<rid>/`.

**package.ps1** builds both runtimes and writes `windows/dist/SiteBlock-Windows.zip` holding:

```
SiteBlock/
├── bin/x64/                 the programs for Intel and AMD PCs
├── bin/arm64/               the programs for Arm PCs
├── scripts/install.ps1
├── scripts/verify-install.ps1
├── Install SiteBlock.cmd
└── INSTALL.txt
```

and `windows/dist/version-windows.json` with the same fields as the Mac's `version.json` (`version` `1.0.<build>`, `build`, `displayVersion`, `commit`, `asset` `SiteBlock-Windows.zip`, `sha256`). The updater's layout check reads `bin\<arch>\` for the PC's own processor.

**Install SiteBlock.cmd** asks Windows for administrator rights (it starts itself again through PowerShell's `Start-Process -Verb RunAs` when it is not elevated), changes into its own folder with `pushd` (which also works for a network folder, because it gives the folder a temporary drive letter) and stops with a message when that fails, removes the "downloaded from the internet" mark (`Unblock-File`) only from the files in its own folder, runs `scripts\install.ps1` with `powershell -ExecutionPolicy Bypass`, then runs `verify-install.ps1`, and waits for a key press so the results can be read.

**install.ps1** (must run elevated; safe to run again for an upgrade or a repair):
1. Refuse to run unless elevated and unless the package holds all three programs for this PC's processor.
2. Stop `SiteBlockWatchdog`, then `SiteBlock`, then every `SiteBlockApp.exe` process. `state.json` is never touched.
3. Create the folders and set their access lists (§ Installed Paths and Permissions).
4. Copy the programs to `C:\Program Files\SiteBlock\` and to the backup folder.
5. Create or update both services with `sc.exe` (start automatically, LocalSystem, recovery actions), add the program folder to the system `PATH`, write the `Run` value, and create the Start menu shortcut.
6. Start `SiteBlock`, then `SiteBlockWatchdog`; wait up to 10 seconds for the pipe; run `siteblock status`; the service's AppGuard starts the tray app for the signed-in user.

**Version numbers:** `version.props` holds `WindowsSeries` (`1.0`) and `WindowsSeriesFirstBuild` (the commit count of the first published Windows build), and the generated `BuildNumber`. The version people see is `<WindowsSeries>.<max(0, BuildNumber - WindowsSeriesFirstBuild)>`, so the first published Windows build is `1.0.0`. On GitHub, `write-build-number` fails the build when it cannot read a commit count above 0. The programs read these numbers from their assembly metadata, and `siteblockd.exe --version` prints `siteblockd <version> (build <n>)`.

**GitHub workflow (`.github/workflows/windows.yml`):** runs on pushes to the `windows` and `master` branches that touch `windows/` or the workflow itself, on a `windows-2025` runner (a fresh Windows Server 2025 machine GitHub lends for each run, where the job has administrator rights). Each branch has its own concurrency group (a rule that lets only one run of the workflow go at a time for that group). A newer push cancels a run still in progress on the same branch, except on `master`, where a run is never cancelled, because stopping it between the two release steps would leave `windows-latest` out of step with the newest release:
1. Check out with the full history and set up .NET 10.
2. Run every test project; failed tests become error annotations, as in the Mac workflow. Each annotation carries the whole failure message, with its lines joined with " | " and cut at 1,500 characters.
3. Run `package.ps1`.
4. Run `e2e.ps1`: a real install from the package on the runner, then the checks in § Testing.
5. Only on `master`: create a release tagged `windows-v<version>`, not marked latest, with both files, and replace the files of the fixed release tagged `windows-latest` with the same two files, so the download link `https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip` always gives the newest build. Neither release is marked latest, so the Mac's `releases/latest` links keep pointing at the Mac package.

---

## Threat Model on Windows

SiteBlock for Windows defends against the same thing as on the Mac: the PC's owner acting on impulse. Every item in [01-overview-and-data.md](01-overview-and-data.md) § Threat Model and Honest Limits applies, with Windows names: hand edits of the hosts file and moving it with `DataBasePath` are undone within 2 seconds; a stopped, disabled or deleted service comes back within 5 seconds; a deleted or closed tray app comes back within 5 seconds; a deleted or edited state file is rewritten from memory; DNS changes are undone within about a second; policy keys are rewritten on the next pass; the clock cannot shorten a wait; and five wrong passwords lock checks for 15 minutes.

**What SiteBlock cannot stop on Windows:**
- An administrator who stops both services within the same few seconds and then deletes their files or the state file, or who boots into Safe Mode, where the services do not run. The strongest setup is a standard (non-administrator) Windows account for daily use, with the administrator password held by someone else.
- An administrator who changes a service's security descriptor (the list of who may start, stop or change it, set with `sc sdset`). The guard does not check it.
- A VPN or a proxy that looks up names on the remote side, as on the Mac; the browsers' own block lists still apply in Chrome, Edge, Brave and Firefox.
- Chrome, Edge and Brave can ignore registry policies on a PC that is not managed by an organization only for a small set of policies (such as forced extensions); the block list and filter policies SiteBlock writes are not in that set. The end-to-end test checks that Chrome refuses a blocked site on the test machine.
- A blocked part of a site that shows for up to half a second before the tab reloads, and a background tab that changes its own address, which is seen only when it becomes the visible tab.

---

## Testing

The project's testing budget applies (see `CLAUDE.local.md`), and expected values come from the design, never from the code.

1. **SiteBlock.Core.Tests** ports the unit tests listed in [05-testing-and-operations.md](05-testing-and-operations.md) § Unit Tests, with the same expected values, plus `WindowsBrowserPolicyTests` for the registry contents of each browser and `PeerTests` for the admin rules.
2. **SiteBlock.Integration.Tests** starts the real `siteblockd` in sandbox mode with `--tick 0.2 --policy-fast` and runs the integration tests in [05-testing-and-operations.md](05-testing-and-operations.md) § Integration Tests against the sandbox hosts file, `registry.json` and `network-services.json`, over the real pipe and with the real `siteblock` CLI. It runs on the Mac and on Windows.
3. **SiteBlock.AppLogic.Tests** covers the panel's decisions: which screen shows, each row's buttons, line and tone, the temporary unblock form rules, the update flow phases with a fake downloader and a fake elevated runner (including a checksum failure, a missing file in the package, and a cancelled UAC prompt), and the tab watcher loop with a fake `IBrowserTabs`.
4. **SiteBlock.Windows.Tests** (Windows only) runs `RegistryPolicyStore` against a throwaway key under `HKCU\Software\SiteBlockTest`, the access-list helper on a temp folder, `WindowsDnsBackend` in read-only mode, and `UiaBrowserTabs` against a real Chrome window on the test machine.
5. **e2e.ps1** runs on GitHub's Windows machine after a real install from the package and checks:
   - both services run, and `siteblock status` answers;
   - `siteblock add youtube.com` with the password piped in puts `0.0.0.0 youtube.com` and `0.0.0.0 www.youtube.com` in the real hosts file, and `[System.Net.Dns]::GetHostAddresses('www.youtube.com')` returns `0.0.0.0`;
   - the four browsers' registry keys hold the documented values;
   - Chrome, started headless on `https://www.youtube.com/`, shows its "blocked by your administrator" error (`ERR_BLOCKED_BY_ADMINISTRATOR`);
   - deleting the hosts section is undone within 3 seconds, and pointing `DataBasePath` elsewhere is undone within 3 seconds;
   - stopping `SiteBlock`, setting it to Disabled, and deleting `SiteBlockWatchdog` are each undone within 10 seconds;
   - deleting `state.json` is undone within 3 seconds with the blocks kept;
   - every Ethernet adapter's DNS servers are the family servers (or the saved ones, logged as "family DNS unreachable", when the runner's network blocks them);
   - `siteblock unblock youtube.com` with a wrong password is refused, and a temporary unblock request shorter than the delay is refused without counting a wrong password;
   - the tray app process starts in the console session when a user is signed in there, and it is restarted within 10 seconds after it is stopped;
   - a second run of `install.ps1` (an upgrade) keeps the blocks, the password and the countdowns.
6. **Live tab-watcher test** (`Test-LiveTabWatcher` in `e2e.ps1`): it runs only when the script itself runs in the console session where the tray app runs, and reports a skip otherwise. It blocks `example.com/sbtabtest`, opens two visible Chrome windows (with the DevTools port 9333, the port Chrome opens so a script can control it) on example.com pages, and marks both pages with a script variable. It then moves the first page onto the blocked path with `history.pushState`. The test passes when the first tab lost its mark (it was reloaded), the tray app's log gained exactly one reload line, and the second window kept its mark.
7. **Live update test** (`Test-LiveUpdate` in `e2e.ps1`): it builds `windows/tests/SiteBlock.UpdateProbe`, a test-only console program that runs the tray app's real `Updater`, `HttpUpdateDownloader` and `UacElevatedRunner` against addresses given on its command line (the shipped tray app never accepts other addresses). The script serves the run's package from a local `HttpListener` on `http://127.0.0.1:18765/` under a version file that claims the installed build plus 1000. It checks two things. A version file with a wrong checksum ends in "The update didn't pass its checks, so nothing was installed." and leaves no `SiteBlockUpdate-*` folder behind. A version file with the correct checksum installs, and afterwards the service still blocks youtube.com and accepts the password.

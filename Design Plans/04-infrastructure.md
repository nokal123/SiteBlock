# Infrastructure: Paths, Launchd, Build and Install
> Part of the SiteBlock Design Plans
> See also: [01-overview-and-data.md](01-overview-and-data.md), [03-daemon-cli-app.md](03-daemon-cli-app.md), [05-testing-and-operations.md](05-testing-and-operations.md)

## Table of Contents
1. [Repository Layout](#repository-layout)
2. [Package.swift](#packageswift)
3. [Installed Paths](#installed-paths)
4. [Sandbox Mode](#sandbox-mode)
5. [Launchd Jobs](#launchd-jobs)
6. [Build Script](#build-script)
7. [Install Script](#install-script)
8. [Upgrade Behavior](#upgrade-behavior)
9. [Repairing an Install](#repairing-an-install)

---

## Repository Layout

```
SiteBlock/
├── Package.swift
├── README.md
├── Design Plans/
├── Sources/
│   ├── SiteBlockCore/        library: all policy logic (see 02)
│   ├── siteblockd/           daemon + watchdog executable
│   ├── siteblock/            CLI executable
│   └── SiteBlockApp/         menu bar app executable
├── Tests/
│   ├── SiteBlockCoreTests/   unit tests (Swift Testing)
│   └── IntegrationTests/     runs the real siteblockd in sandbox mode
├── Resources/
│   └── Info.plist            app bundle Info.plist template
└── scripts/
    ├── build.sh
    ├── test.sh
    ├── install.sh
    └── verify-install.sh
```

---

## Package.swift

- `swift-tools-version:5.10`, `platforms: [.macOS(.v14)]`, language mode Swift 5 (`swiftLanguageVersions: [.v5]`) so the strict Swift 6 concurrency checks do not block the C socket code.
- Targets: `SiteBlockCore` (library), `siteblockd`, `siteblock`, `SiteBlockApp` (executables depending on `SiteBlockCore`), `SiteBlockCoreTests` and `IntegrationTests` (test targets using Swift Testing).
- `SiteBlockCore` links `Security` (for `SecRandomCopyBytes`). CommonCrypto is available through `import CommonCrypto` with no extra setting.

**Swift Testing on Command Line Tools:** This Mac has the Command Line Tools but not Xcode. The `Testing` framework is in `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and is not on the default search path, so `scripts/test.sh` passes it explicitly:

```
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays "$@"
```

The last flag is needed because the Command Line Tools ship `_Testing_Foundation.framework` without its module files. Without the flag, any test file that imports both `Foundation` and `Testing` fails with "no such module '_Testing_Foundation'". The flag tells the compiler not to look for that combined module.

When Xcode is installed, plain `swift test` also works, and the script detects `xcode-select -p` pointing at Xcode and skips the extra flags.

---

## Installed Paths

`Paths` (`Sources/SiteBlockCore/Paths.swift`) holds every location. `Paths.production` uses:

- Daemon program: `/Library/Application Support/SiteBlock/bin/siteblockd`
- Backup program (restored by the guard if the main one is deleted): `/usr/local/libexec/siteblock/siteblockd`
- State file: `/Library/Application Support/SiteBlock/state.json`
- State backup (restored from if the main state file is deleted while the daemon is stopped): `/usr/local/libexec/siteblock/state.backup.json`
- Socket: `/var/run/siteblock.sock`
- Hosts file: `/etc/hosts`
- Chrome policy, machine-wide copy: `/Library/Managed Preferences/com.google.Chrome.plist`
- Chrome policy, copy for the user logged in at the screen: `/Library/Managed Preferences/<console user>/com.google.Chrome.plist` (not written when nobody is logged in)
- Log file: `/Library/Logs/SiteBlock/siteblockd.log` (watchdog: `watchdog.log`)
- Daemon plist: `/Library/LaunchDaemons/com.nokal.siteblock.daemon.plist`
- Watchdog plist: `/Library/LaunchDaemons/com.nokal.siteblock.watchdog.plist`
- App LaunchAgent plist: `/Library/LaunchAgents/com.nokal.siteblock.app.plist`
- App: `/Applications/SiteBlock.app`
- CLI: `/usr/local/bin/siteblock` (a copy, not a link, so it keeps working if the repository is deleted)

`Paths.sandbox(root:)` puts every file under the given folder: `root/hosts`, `root/state/state.json`, `root/siteblock.sock`, `root/LaunchDaemons/…`, `root/ManagedPreferences/com.google.Chrome.plist`, `root/ManagedPreferences/<console user>/com.google.Chrome.plist` and so on. A Unix socket path must be shorter than 104 bytes, so tests create their sandbox under `/tmp` with a short random name.

---

## Sandbox Mode

Sandbox mode lets the real `siteblockd` program run as an ordinary user against a temporary folder. Integration tests and manual checks use it. In sandbox mode the daemon:

- uses `Paths.sandbox(root:)` for every file,
- does not flush the macOS name cache,
- does not call `launchctl` and does not run the watchdog check,
- accepts `--tick` and `--policy-fast`.

The CLI and app reach a sandbox daemon when the `SITEBLOCK_SOCKET` environment variable points at the sandbox socket.

---

## Launchd Jobs

Labels:
- `com.nokal.siteblock.daemon` — runs `siteblockd --daemon`.
- `com.nokal.siteblock.watchdog` — runs `siteblockd --watchdog` from the same program file.
- `com.nokal.siteblock.app` — a LaunchAgent (started in each user's login session) that runs `/Applications/SiteBlock.app/Contents/MacOS/SiteBlock`. It sets `RunAtLoad` true and `KeepAlive` false, so quitting the app keeps it closed until the next login.

Both LaunchDaemon plists contain `Label`, `ProgramArguments`, `RunAtLoad` true, `KeepAlive` true, `ProcessType` `Interactive`, `AbandonProcessGroup` true (so the uninstall shell is not killed with the daemon), `StandardOutPath` and `StandardErrorPath` set to the log file, and `ThrottleInterval` `5` (launchd waits at least 5 seconds between restarts).

---

## Build Script

`scripts/build.sh` (runs as the normal user):

1. `swift build -c release --product siteblockd`, then `siteblock`, then `SiteBlockApp`.
2. Assemble `build/SiteBlock.app`:
   - `Contents/MacOS/SiteBlock` — the `SiteBlockApp` program.
   - `Contents/Info.plist` — from `Resources/Info.plist` with `CFBundleIdentifier` `com.nokal.siteblock.app`, `CFBundleName` `SiteBlock`, `CFBundleExecutable` `SiteBlock`, `LSUIElement` true, `LSMinimumSystemVersion` `14.0`, and the version.
3. Copy `siteblockd` and `siteblock` into `build/`.
4. Sign all three with an ad-hoc signature (`codesign --force --sign -`), which marks them as unchanged since build. Apple Silicon Macs refuse to run unsigned programs, and an ad-hoc signature needs no Apple developer account.
5. Print the paths of the results.

---

## Install Script

`scripts/install.sh` must run with `sudo`. It is safe to run again for an upgrade.

1. Refuse to run unless the effective user is root, and refuse unless `build/` contains all three programs (it tells the user to run `scripts/build.sh` first).
2. Create `/Library/Application Support/SiteBlock/bin` (mode `0755`), `/usr/local/libexec/siteblock`, `/Library/Logs/SiteBlock`, all owned by `root:wheel`.
3. If the daemon and watchdog are loaded, `bootout` the watchdog first, then the daemon, so neither restarts the other during the copy. `state.json` is never touched.
4. Copy `siteblockd` to both the main and backup paths (mode `0755`, `root:wheel`). Copy `siteblock` to `/usr/local/bin/siteblock`. Copy `SiteBlock.app` to `/Applications/` (replacing any older copy).
5. Write both LaunchDaemon plists by running the root-owned installed copy, `"/Library/Application Support/SiteBlock/bin/siteblockd" --print-plist daemon` and `--print-plist watchdog`, so the plist text has one source in code. Write the LaunchAgent plist the same way with `--print-plist app`. The script never runs a program from `build/` or `/usr/local/bin` as root, because the user's account can replace files in those folders.
5a. Write `/etc/newsyslog.d/siteblock.conf` (mode `0644`, `root:wheel`) so macOS's log rotation tool keeps each log file under 1 MB with 3 compressed old copies:
    ```
    /Library/Logs/SiteBlock/siteblockd.log  root:wheel  644  3  1024  *  JN
    /Library/Logs/SiteBlock/watchdog.log    root:wheel  644  3  1024  *  JN
    ```
6. `launchctl bootstrap system` the daemon plist, then the watchdog plist.
7. Load the app for the user who ran `sudo` with `launchctl bootstrap gui/$SUDO_UID /Library/LaunchAgents/com.nokal.siteblock.app.plist`.
8. Wait up to 10 seconds for the socket to appear, run `siteblock status` as the invoking user (`sudo -u "#$SUDO_UID"`, or skip it when `SUDO_UID` is empty), and print next steps (set a password from the menu bar icon or with `siteblock setup`).

`Install SiteBlock.command` at the repository root is a double-clickable wrapper. Finder opens it in Terminal, where it runs `scripts/build.sh` as the user, then `sudo scripts/install.sh` (Terminal asks for the Mac password), then `scripts/verify-install.sh`, and leaves the window open so the results can be read.

This adds the flag `--print-plist <daemon|watchdog|app>` to `siteblockd`, which prints the plist XML for that job to standard output and exits.

---

## Upgrade Behavior

Running `install.sh` again replaces the programs and plists and restarts the jobs. The state file, including the block list, password and every countdown, survives. Countdowns lose only the time the daemon was stopped, which makes waits longer, never shorter.

---

## Repairing an Install

Running `sudo scripts/install.sh` again repairs a broken install: it replaces the programs and plists and restarts both jobs, and it never removes the state files, so every block, the password and every countdown survive. The only way to remove SiteBlock is `siteblock uninstall` (or the Uninstall button in Settings), which needs the password and waits for the delay. The repository holds no script that removes SiteBlock without them, because the person who owns the Mac is also the person the block protects.

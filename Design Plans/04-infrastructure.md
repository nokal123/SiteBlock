# Infrastructure: Paths, Launchd, Build and Install
> Part of the SiteBlock Design Plans
> See also: [01-overview-and-data.md](01-overview-and-data.md), [03-daemon-cli-app.md](03-daemon-cli-app.md), [05-testing-and-operations.md](05-testing-and-operations.md)

## Table of Contents
1. [Repository Layout](#repository-layout)
2. [Package.swift](#packageswift)
3. [Installed Paths](#installed-paths)
4. [Sandbox Mode](#sandbox-mode)
5. [Launchd Jobs](#launchd-jobs)
6. [Version Numbers](#version-numbers)
7. [Build Script](#build-script)
8. [Install Script](#install-script)
9. [Upgrade Behavior](#upgrade-behavior)
10. [Repairing an Install](#repairing-an-install)
11. [Packaging for Another Mac](#packaging-for-another-mac)
12. [Automatic Package Builds](#automatic-package-builds)

---

## Repository Layout

```
SiteBlock/
├── Package.swift
├── README.md
├── Design Plans/
├── Sources/
│   ├── SiteBlockCore/        library: all policy logic (see 02)
│   │   ├── TabRuleMatcher.swift     does a tab address fall under a path rule (see 02)
│   │   ├── TabReloadDecider.swift   which tabs to reload, each once per address (see 02)
│   │   ├── UpdateCheck.swift        version file check, newer-build rule, checksum (see 02)
│   │   ├── FamilyDNSProviders.swift reads the providers file (see 02)
│   │   └── FamilyDNSProviders.json  the family DNS services and the active one, built into the programs (see 02)
│   ├── siteblockd/           daemon + watchdog executable
│   ├── siteblock/            CLI executable
│   └── SiteBlockApp/         menu bar app executable
│       ├── TabWatcher.swift         polls browser tabs and reloads blocked ones (see 03)
│       ├── ChromiumTabs.swift       Apple Events bridge to Chrome, Edge and Brave (see 03)
│       └── Updater.swift            checks GitHub for a newer version and installs it on request (see 03)
├── Tests/
│   ├── SiteBlockCoreTests/   unit tests (Swift Testing)
│   └── IntegrationTests/     runs the real siteblockd in sandbox mode
├── Resources/
│   └── Info.plist            app bundle Info.plist template (includes the Apple Events usage text)
└── scripts/
    ├── release-check.sh
    ├── build.sh
    ├── test.sh
    ├── install.sh
    ├── package.sh
    └── verify-install.sh
```

---

## Package.swift

- `swift-tools-version:5.10`, `platforms: [.macOS(.v14)]`, language mode Swift 5 (`swiftLanguageVersions: [.v5]`) so the strict Swift 6 concurrency checks do not block the C socket code.
- Targets: `SiteBlockCore` (library), `siteblockd`, `siteblock`, `SiteBlockApp` (executables depending on `SiteBlockCore`), `SiteBlockCoreTests` and `IntegrationTests` (test targets using Swift Testing).
- `SiteBlockCore` links `Security` (for `SecRandomCopyBytes`). CommonCrypto is available through `import CommonCrypto` with no extra setting.
- `SiteBlockCore` declares `resources: [.embedInCode("FamilyDNSProviders.json")]`. SwiftPM writes the file's bytes into the library as `PackageResources.FamilyDNSProviders_json`, so the installed programs need no file beside them and nothing on the installed computer can change which family DNS provider is used. The file is at `Sources/SiteBlockCore/FamilyDNSProviders.json` (see [02-core-components.md](02-core-components.md) § FamilyDNSProviders), and the Windows build embeds the same file (see [06-windows.md](06-windows.md) § SiteBlock.Core).

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
- Backup app (restored by AppGuard if the app is deleted or moved to the Trash): `/usr/local/libexec/siteblock/SiteBlock.app`
- State file: `/Library/Application Support/SiteBlock/state.json`
- State backup (restored from if the main state file is deleted while the daemon is stopped): `/usr/local/libexec/siteblock/state.backup.json`
- Socket: `/var/run/siteblock.sock`
- Hosts file: `/etc/hosts`
- Chrome policy, machine-wide copy: `/Library/Managed Preferences/com.google.Chrome.plist`
- The same policy files for Edge (`com.microsoft.Edge.plist`), Brave (`com.brave.Browser.plist`) and Firefox (`org.mozilla.firefox.plist`), machine-wide and per console user under `/Library/Managed Preferences`, plus Firefox's `/Library/Preferences/org.mozilla.firefox.plist` (see [03-daemon-cli-app.md](03-daemon-cli-app.md) § BrowserPolicyEnforcer).
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
- does not call `launchctl` and does not run the watchdog check (the app-bundle part of AppGuard still runs, against the sandbox's own app and backup),
- accepts `--tick` and `--policy-fast`.

The CLI and app reach a sandbox daemon when the `SITEBLOCK_SOCKET` environment variable points at the sandbox socket.

---

## Launchd Jobs

Labels:
- `com.nokal.siteblock.daemon` — runs `siteblockd --daemon`.
- `com.nokal.siteblock.watchdog` — runs `siteblockd --watchdog` from the same program file.
- `com.nokal.siteblock.app` — a LaunchAgent (started in each user's login session) that runs `/Applications/SiteBlock.app/Contents/MacOS/SiteBlock`. It sets `RunAtLoad` true, `KeepAlive` true and `ThrottleInterval` 5, so launchd starts the app again (at most every 5 seconds) whenever it exits; the app has no Quit button. The daemon reloads this agent if it is unloaded (see [03-daemon-cli-app.md](03-daemon-cli-app.md) § AppGuard).

Both LaunchDaemon plists contain `Label`, `ProgramArguments`, `RunAtLoad` true, `KeepAlive` true, `ProcessType` `Interactive`, `AbandonProcessGroup` true (so the uninstall shell is not killed with the daemon), `StandardOutPath` and `StandardErrorPath` set to the log file, and `ThrottleInterval` `5` (launchd waits at least 5 seconds between restarts).

---

## Version Numbers

Every build has a version people see and a build number. The version is `<series>.<n>`: the series (`siteBlockSeries`, currently `1.3`) followed by how far the build number is past the series' first build (`siteBlockSeriesFirstBuild`, currently 95). The first build of a series is `<series>.0`, the next `<series>.1`, and so on, and a new series starts again at `.0`; starting a series means changing those two constants in `Sources/SiteBlockCore/Models.swift` together. Updates are ordered by the build number only, so the version starting again at `.0` never hides an update.

**The release number.** The build number is a release number kept by hand in a checked-in file: `public let siteBlockBuildNumber = 94` in `Sources/SiteBlockCore/Models.swift`, next to `siteBlockSeries` and `siteBlockSeriesFirstBuild`. It started at 94, the build that was already published. To make a release, raise the number by one and push to `master`; each release therefore raises the version people see by one. The number never goes down, because an installed copy takes an update only when the update's build is higher than its own. A push that leaves the number alone is built and tested but not published (see § Automatic Package Builds). No generated file and no script write the number, so every machine that builds the same commit gets the same number.

**Where the number is used:**
- `siteBlockMarketingVersion` in `Sources/SiteBlockCore/Models.swift` is the version people see, for example `1.2.0`, and `siteBlockVersion` is the same text. The daemon's status reply, the CLI (`siteblock version` and the first line of `siteblock status`) and the app (the Settings lines) show only that version, for example `1.2.0`. `siteblockd --version` adds the build number (`siteblockd 1.2.0 (build 51)`), because the build scripts read both numbers from it. `siteBlockBuildID` is the technical id `1.0.<build>` written into `version.json`'s `version` field.
- `scripts/build.sh` writes the same values into the built app's `Info.plist`: `CFBundleShortVersionString` is the version people see (for example `1.2.0`) and `CFBundleVersion` is the build number. Both are read from `siteblockd --version`. `Resources/Info.plist` in the repository keeps placeholder values (`0.0.0` and `0`).
- `version.json` carries the technical id in `version` (`1.0.<build>`, the form copies of SiteBlock older than 1.2.0 require before they accept an update), the build number in `build`, and the version people see in `displayVersion`, which the banner shows (see § Packaging for Another Mac). The menu bar app compares its own `siteBlockBuildNumber` with the published `build` to decide whether an update exists ([02-core-components.md](02-core-components.md) § UpdateCheck).
- The release number is read from a file in the checkout, so the GitHub workflow checks out only the newest commit.

---

## Build Script

`scripts/build.sh` (runs as the normal user):

1. Build each of the three products (`siteblockd`, `siteblock`, `SiteBlockApp`) once for each processor family, with `swift build -c release --scratch-path .build-release --product <product> --triple <arch>-apple-macosx14.0`, for `arm64` (Apple chips) and for `x86_64` (Intel processors). Each part is checked with `lipo -archs` to hold only its own family. The two parts of each product are then joined with `lipo -create` into one universal program (a single file that holds a copy for each family) in `.build-release/universal/`. The script reads the version by running the joined `siteblockd --version`.
3. Assemble `build/SiteBlock.app`:
   - `Contents/MacOS/SiteBlock` — the `SiteBlockApp` program.
   - `Contents/Info.plist` — from `Resources/Info.plist` with `CFBundleIdentifier` `com.nokal.siteblock.app`, `CFBundleName` `SiteBlock`, `CFBundleExecutable` `SiteBlock`, `LSUIElement` true, `LSMinimumSystemVersion` `14.0`, `CFBundleShortVersionString` set to the version people see and `CFBundleVersion` set to the build number.
   - The template also carries `NSAppleEventsUsageDescription` = "SiteBlock checks the address of each open tab so a blocked part of a site closes as soon as you go to it." This is the sentence macOS shows in its prompt when the tab watcher first asks to control a browser (see [03-daemon-cli-app.md](03-daemon-cli-app.md) § TabWatcher). Without the key, macOS refuses the app's Apple Events without asking. The app is signed ad hoc without the hardened runtime (Apple's stricter code-signing mode), so no entitlement is needed for Apple Events.
4. Copy `siteblockd` and `siteblock` into `build/`.
5. Sign all three with an ad-hoc signature (`codesign --force --sign -`), which marks them as unchanged since build. Macs with an Apple chip refuse to run unsigned programs, and an ad-hoc signature needs no Apple developer account. `codesign` signs both copies inside each universal file. The script then verifies the signatures.
6. Check every finished program in `build/` (`siteblockd`, `siteblock` and `SiteBlock.app/Contents/MacOS/SiteBlock`) with `lipo -verify_arch arm64 x86_64`, so a program missing either copy stops the build.
7. Print the paths of the results.

---

## Install Script

`scripts/install.sh` must run with `sudo`. It is safe to run again for an upgrade.

1. Refuse to run unless the effective user is root, and refuse unless `build/` contains all three programs (it tells the user to run `scripts/build.sh` first). Then check that this Mac can run them, before anything is copied. The script prints `this Mac: <an Apple chip|an Intel processor> (<arch>), macOS <version>`. The family is `arm64` when `sysctl -n hw.optional.arm64` prints 1 (which is also true when the script itself runs translated by Rosetta, the macOS layer that runs Intel programs on an Apple chip), and `x86_64` otherwise. The version comes from `sw_vers -productVersion`. The script stops with exit code 1 when macOS is older than 14 (the message names the installed version and points to Software Update), and when any of the three programs has no copy for this Mac's family. That second check reads each program with macOS's own `file -b` and not with `lipo`, because on a Mac without developer tools `lipo` opens an "install developer tools" window; the pattern `executable arm64` must not match `arm64e`. The refusal names the program, what it is built for, and the download link for the newest `SiteBlock.zip`. When the check passes, the script prints `the programs have a copy for this Mac's processor`. In `--dry-run` only, the variables `SITEBLOCK_TEST_MAC_ARCH` and `SITEBLOCK_TEST_MACOS_VERSION` stand in for the Mac's family and version, so tests can act out an Intel Mac or an old macOS; a real install never reads them.
2. Create `/Library/Application Support/SiteBlock/bin` (mode `0755`), `/usr/local/libexec/siteblock`, `/Library/Logs/SiteBlock`, all owned by `root:wheel`.
3. If the daemon and watchdog are loaded, `bootout` the watchdog first, then the daemon, so neither restarts the other during the copy. `state.json` is never touched.
4. Copy `SiteBlock.app` to its backup path `/usr/local/libexec/siteblock/SiteBlock.app` with `ditto` (owner `root:wheel`), replacing any older backup. Then copy `siteblockd` to both the main and backup paths (mode `0755`, `root:wheel`). Copy `siteblock` to `/usr/local/bin/siteblock`. Copy `SiteBlock.app` to `/Applications/` (replacing any older copy).
5. Write both LaunchDaemon plists by running the root-owned installed copy, `"/Library/Application Support/SiteBlock/bin/siteblockd" --print-plist daemon` and `--print-plist watchdog`, so the plist text has one source in code. Write the LaunchAgent plist the same way with `--print-plist app`. The script never runs a program from `build/` or `/usr/local/bin` as root, because the user's account can replace files in those folders.
5a. Write `/etc/newsyslog.d/siteblock.conf` (mode `0644`, `root:wheel`) so macOS's log rotation tool keeps each log file under 1 MB with 3 compressed old copies:
    ```
    /Library/Logs/SiteBlock/siteblockd.log  root:wheel  644  3  1024  *  JN
    /Library/Logs/SiteBlock/watchdog.log    root:wheel  644  3  1024  *  JN
    ```
6. `launchctl bootstrap system` the daemon plist, then the watchdog plist.
7. Load the app for the user who ran `sudo` with `launchctl bootstrap gui/$SUDO_UID /Library/LaunchAgents/com.nokal.siteblock.app.plist`. Without `SUDO_UID` (the script run as root from a macOS administrator password window), use the owner of `/dev/console`, the person at the screen; when that is root, skip this step.
8. Wait up to 10 seconds for the socket to appear, run `siteblock status` as the invoking user (`sudo -u "#$SUDO_UID"`, or skip it when `SUDO_UID` is empty), and print next steps (set a password from the menu bar icon or with `siteblock setup`).

`Install SiteBlock.command` at the repository root is a double-clickable wrapper. Finder opens it in Terminal, where it runs `scripts/build.sh` as the user, then `sudo scripts/install.sh` (Terminal asks for the Mac password), then `scripts/verify-install.sh`, and leaves the window open so the results can be read.

This adds the flag `--print-plist <daemon|watchdog|app>` to `siteblockd`, which prints the plist XML for that job to standard output and exits.

---

## Upgrade Behavior

Running `install.sh` again replaces the programs and plists and restarts the jobs. The state file, including the block list, password and every countdown, survives. Countdowns lose only the time the daemon was stopped, which makes waits longer, never shorter.

The "Update" button in the menu bar app runs this same script from an unzipped copy of the downloaded package, so an update behaves exactly like this upgrade (see [03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater). The new app starts with the new build number, and the update banner no longer shows.

The ad hoc signature of the app changes with every build. After an upgrade, macOS may therefore ask again whether SiteBlock may control Chrome, Edge or Brave. Until the person answers, the tab watcher reads nothing from that browser, and a refusal makes the panel show the permission banner.

---

## Repairing an Install

Running `sudo scripts/install.sh` again repairs a broken install: it replaces the programs and plists and restarts both jobs, and it never removes the state files, so every block, the password and every countdown survive. The only way to remove SiteBlock is `siteblock uninstall` (or the Uninstall button in Settings), which needs the password and then waits 48 hours, or the unblock delay if that is longer. The repository holds no script that removes SiteBlock without them, because the person who owns the Mac is also the person the block protects.

---

## Packaging for Another Mac

`scripts/package.sh` (runs as the normal user) builds fresh release programs with `scripts/build.sh`, and writes two files into `dist/`:
- `SiteBlock.zip` — the package. It always has this one name, so the download link `https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip` never changes.
- `version.json` — a small JSON file that describes the package. Its fields are `displayVersion` (the version people see, for example `1.2.0`), `version` (the technical id `1.0.<build>`), `build` (the build number, as a number), `commit` (the full 40-character hash of the commit the package was built from, in lowercase), `asset` (the package's file name, `SiteBlock.zip`) and `sha256` (the SHA-256 checksum of `SiteBlock.zip`, written as 64 lowercase hexadecimal characters). The menu bar app reads this file to learn which build is newest, and it checks the downloaded package against `sha256`. The rules the app applies to these fields are in [02-core-components.md](02-core-components.md) § UpdateCheck.

The `version` and `build` fields are those of the programs the script just built. When git is not available, the `commit` is 40 zeros. The zip holds one `SiteBlock` folder:

```
SiteBlock/
├── build/                      ready-built, ad-hoc signed universal programs (Apple chip and Intel)
├── scripts/install.sh
├── scripts/verify-install.sh
├── Install SiteBlock.command   double-click installer for the other Mac
└── INSTALL.txt                 plain-language instructions
```

The packaged `Install SiteBlock.command` differs from the repository's: it does not build. It removes the `com.apple.quarantine` extended attribute (the mark macOS puts on files that arrive from another computer) from its own folder, runs `sudo scripts/install.sh` and then `scripts/verify-install.sh`, and waits for Return. The programs carry only an ad-hoc signature, so the first opening needs right-click > Open (or System Settings > Privacy & Security > Open Anyway); `INSTALL.txt` explains this and gives the two-line Terminal fallback.

Before zipping, the script checks every copied program with `codesign --verify --strict` and that each of the three programs holds a copy for Apple chips (`arm64`) and a copy for Intel processors (`x86_64`); a program missing either stops the script with the message "is not built for Apple chips (arm64)" or "is not built for Intel processors (x86_64)". `INSTALL.txt` states the requirement as "a Mac with an Apple chip or an Intel processor, macOS 14 (Sonoma) or newer". The zip is made with `ditto -c -k --keepParent`, which keeps the app bundle's signature and the scripts' run permissions. `dist/` is ignored by git. The target Mac needs an Apple chip or an Intel processor and macOS 14 or newer; nothing in the package is tied to the Mac that built it, and no blocked sites or password are carried over.

---

## Automatic Package Builds

`.github/workflows/package.yml` is a GitHub Actions workflow (a script GitHub runs on its own machines) that runs on every push to `master` that touches `Sources/`, `Resources/`, `scripts/`, `Package.swift`, `Install SiteBlock.command` or the workflow itself, and can also be started by hand from the repository's Actions tab. It runs on a `macos-26` runner (Apple chip), in this order:

**SDK:** the package is built with the macOS 26 SDK, the same as local builds. The SDK an app is built with decides its look and layout on newer macOS, so a package built with the macOS 15 SDK looked and laid out differently from the tested app. A workflow step stops the run before building when `xcrun --sdk macosx --show-sdk-version` is below 26.

1. Check out the code (only the newest commit, because the release number is read from `Models.swift`). Print the macOS and Swift versions.
2. Run `scripts/test.sh` (with Xcode present it runs plain `swift test`). A failing test stops the run, so a broken package is never published. The step also turns each failed test line into a GitHub error annotation (a red message attached to the run), up to the first 20. A failed test line is a line of the test output that contains `✘`. GitHub shows annotations on the public run page, while the full log can be read only by someone logged in to GitHub, so the failing test names are readable without logging in.
3. Install Rosetta (`sudo softwareupdate --install-rosetta --agree-to-license`), then run the tests again on Intel under Rosetta: `arch -x86_64 /bin/bash scripts/test.sh --triple x86_64-apple-macosx14.0 --scratch-path .build-x86`. The whole command runs under Rosetta because SwiftPM's test runner loads only tests built for its own processor. Each failed test line becomes a "Failed Intel test" annotation, as in step 2. GitHub has no Intel Mac with the macOS 26 SDK, so the Intel code is tested under Rosetta on the Apple chip runner.
4. Run `scripts/package.sh`, which writes `dist/SiteBlock.zip` and `dist/version.json`.
5. Run the packaged Intel programs under Rosetta. The step checks the three programs with `lipo -verify_arch arm64 x86_64`, runs `arch -x86_64` on `siteblockd --version` and `siteblock --version`, runs `arch -x86_64 siteblockd --print-plist daemon`, `watchdog` and `app` and pipes each result to `plutil -lint -`, and runs `SITEBLOCK_TEST_MAC_ARCH=x86_64 scripts/install.sh --dry-run`, which must print the line `the programs have a copy for this Mac's processor`.
6. Keep the zip as a run artifact for 30 days.
7. Decide whether this is a release. The step downloads `version.json` from the release marked latest (`gh release download --pattern version.json`) and runs `scripts/release-check.sh <new version.json> <published version.json>`, which reads the `build` field of both files with `plutil`. The check prints `release` when the new build is higher than the published one and `skip` when the two are equal. It exits with code 1 when the new build is lower, or when either file's `build` is not a JSON whole number (text such as `"95"` and a decimal such as `95.0` are refused, because installed copies would never take a lower build and a malformed file cannot be compared). The step stops the run, with the reason as an error annotation, when the published file cannot be downloaded or the check fails. On `skip` it adds a notice titled "Not a release" that names the number to raise (`siteBlockBuildNumber` in `Models.swift`), and the release step does not run.
8. Only when the decision is `release`, create a new release for this version, tagged `v<version>` (for example `v1.2.3`) at the pushed commit, with both files, `SiteBlock.zip` and `version.json`, and mark it as the latest release (`gh release create … --latest`), using the `gh` command line and the run's own `GITHUB_TOKEN` (the workflow has `contents: write`). Older releases are kept, so GitHub keeps each version's download counts. The links `…/releases/latest/download/SiteBlock.zip` and `…/version.json` always point at the release marked latest. The step first removes the single release once published under the tag `latest`, if it still exists, so that tag name never shadows those links.

**Download counts:** `scripts/stats.sh` reads the public release data (no login) and prints, per version and in total, the downloads of `SiteBlock.zip` (installs and updates) and of `version.json` (update checks; each installed copy checks about once a day, so checks per day roughly counts copies in use). GitHub counts downloads, not people, and never says who downloaded.

The fixed download link for the package is `https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip`, and the version file is at `https://github.com/nokal123/SiteBlock/releases/latest/download/version.json`. Both stay the same from build to build, because the files always have these names. The README and the workflow's header comment give the package link, and `UpdateCheck` holds both links ([02-core-components.md](02-core-components.md) § UpdateCheck). A newer push cancels a run still in progress (`concurrency: package`).


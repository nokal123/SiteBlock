# SiteBlock

SiteBlock blocks websites on a Mac or a Windows PC, in every browser at once (Safari, Chrome, Edge, Brave, Firefox and any other app), with no browser extension. A blocked site stays blocked until you unblock it. Unblocking needs the SiteBlock password, and even then the site stays blocked for a waiting period (30 minutes by default) before it opens, so a block cannot be undone on impulse. SiteBlock also always blocks adult websites.

SiteBlock is deliberately hard to remove. Only install it on a computer whose user wants it.

## Contents

1. [Requirements](#requirements)
2. [Install](#install)
3. [Using SiteBlock](#using-siteblock)
4. [The adult content filter](#the-adult-content-filter)
5. [Updating](#updating)
6. [Forgotten password](#forgotten-password)
7. [Uninstalling](#uninstalling)
8. [What SiteBlock can and cannot stop](#what-siteblock-can-and-cannot-stop)
9. [How it works](#how-it-works)
10. [Logs and repairs](#logs-and-repairs)
11. [Building from source](#building-from-source)

## Requirements

**Mac:** a Mac with an Apple chip or an Intel processor, macOS 14 (Sonoma) or newer, and the Mac's administrator password. One download serves both kinds of Mac, because each program holds a copy for Apple chips and one for Intel processors, and macOS runs the one that matches.

**Windows:** Windows 11, or Windows 10 version 2004 or newer, on an Intel, AMD or Arm PC, and an administrator account (or someone who knows an administrator password). One download serves every PC, because the package holds the programs for both Intel/AMD and Arm processors and the installer picks the right ones.

## Install

Both download links below always give the newest version, and SiteBlock updates itself after that. Every version is listed on the [releases page](https://github.com/nokal123/SiteBlock/releases); Windows versions are the ones whose tags start with `windows-v`.

### Install on a Mac

1. Download **[SiteBlock.zip](https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip)** and unzip it. Keep the `SiteBlock` folder together, because the installer needs everything in it.
2. Open the `SiteBlock` folder, right-click **`Install SiteBlock.command`** and choose Open.
3. macOS warns that the file is from an unidentified developer, because SiteBlock is not signed with a paid Apple developer certificate. Click Open. If there is no Open button, go to System Settings → Privacy & Security, scroll down, click "Open Anyway" next to the SiteBlock message, and try again.
4. Terminal (the Mac's command-line window) opens and asks for the Mac's administrator password. Nothing appears while you type it; that is normal. If macOS asks whether Terminal may open the folder the zip is in (for example Downloads), click Allow.
5. When Terminal says "SiteBlock is installed and running", a shield icon appears in the menu bar at the top of the screen.

If double-clicking does not work, open Terminal and run these two lines, changing the path if the folder is somewhere other than Downloads. The first line removes the "downloaded from the internet" mark that stops macOS from running the installer, and the second runs the installer.

```bash
xattr -dr com.apple.quarantine ~/Downloads/SiteBlock
```

```bash
cd ~/Downloads/SiteBlock && sudo scripts/install.sh
```

### Install on Windows

1. Download **[SiteBlock-Windows.zip](https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip)**.
2. Unzip it: right-click the zip, choose "Extract All...", then click Extract. Keep the `SiteBlock` folder together, because the installer needs everything in it.
3. Open the `SiteBlock` folder, right-click **`Install SiteBlock.cmd`** and choose "Run as administrator". Double-clicking it also works, because it then asks for administrator rights itself.
4. Windows may show a blue box that says "Windows protected your PC". This is Windows SmartScreen, which warns about programs that few people have downloaded and that are not signed with a paid code-signing certificate, which is true of SiteBlock. Click "More info", then "Run anyway".
5. Windows asks "Do you want to allow this app to make changes to your device?". This is the UAC prompt (User Account Control, the box Windows shows before a program gets administrator rights). Click Yes. On an account that is not an administrator, type an administrator's password here.
6. A window shows the installer working. It copies SiteBlock into `C:\Program Files\SiteBlock`, sets up the two background services that keep the block in place, makes SiteBlock start every time someone signs in, and checks that everything works. Lines that start with SKIP are normal before you have blocked a site. When it says "SiteBlock is installed", press any key to close the window.

SiteBlock then lives in a shield icon by the clock, at the right end of the taskbar. Windows often hides new tray icons, so if you cannot see the shield, click the small ^ arrow by the clock; the shield is in the box that opens. Drag it onto the taskbar next to the clock to keep it visible, or on Windows 11 turn SiteBlock on under Settings → Personalization → Taskbar → Other system tray icons.

Both zips also contain an `INSTALL.txt` file with these steps, for anyone who installs it from the zip alone.

## Using SiteBlock

SiteBlock works the same way on both systems. You control it from the shield icon (in the Mac's menu bar, or by the clock on Windows) or from the `siteblock` command in a terminal.

**Choose your password.** Installing asks only for the computer's administrator password. You choose your SiteBlock password the first time you block a site: click the shield icon, type a site, press Block, and the panel asks you to choose it. This password is separate from the computer's password. It cannot be shown again, so store it somewhere you trust, or give it to someone else to hold.

**Block a site.** Click the shield icon, type the site (for example `youtube.com`, or paste a full link) and press Block. Blocking never needs the password and takes effect at once. A tab that was already open on the site may keep working for a minute or two, until the browser closes its existing connection; reloading after that shows the block. Blocking a site also blocks its common variants: blocking `youtube.com` also blocks `www.youtube.com`, `m.youtube.com`, `youtu.be`, `music.youtube.com`, YouTube Kids, and the servers that hold YouTube's thumbnails and page files.

**Block part of a site.** Type a path after the site name, such as `youtube.com/shorts`, or paste a link to the page you want gone. The panel then offers "Only this part" (already selected) and "Whole site". "Only this part" blocks every address on that site whose path starts with what you typed, such as `youtube.com/shorts/abc`, and leaves the rest of the site open. Blocked parts have their own list in the panel and unblock the same way as whole sites. Only the browsers' own block lists can block part of a site, so this works in Chrome, Edge, Brave and Firefox, while Safari can only block whole sites.

Some sites change the page without loading a new one, which a browser's block list does not notice; YouTube does this when you tap a Short on its home page. In Chrome, Edge and Brave, SiteBlock watches the address of each open tab and reloads a tab that moves to a blocked part, so the block page appears. On a Mac, macOS asks once whether SiteBlock may control each of these browsers; click OK, or the panel shows a notice with a button that opens the right setting. In Firefox, the block page appears only when you reload or open the address directly.

**Unblock a site for good.** Press "Unblock…" next to the site, choose "For good" and enter the password. The site stays blocked for the waiting period and then opens. While it waits, the row says "Still blocked" with a countdown, and "Keep blocked" cancels the unblock without a password.

**Unblock a site for a while.** Press "Unblock…" and choose "For a while". Pick how long the site stays open (15 minutes up to 4 hours) and when it opens (after the waiting period at the soonest, or later), then enter the password and press "Schedule unblock". The site opens at that time and is blocked again on its own when the time is up. "Keep blocked" cancels it while it waits, and "Block now" ends it early once it is open. Neither needs the password.

**Change the waiting period.** Open Settings in the panel. A longer wait applies at once. A shorter wait only takes effect after the current wait has passed, so it cannot be shortened on impulse.

**Browser menus.** While any site is blocked, Chrome's and Edge's menus say "Managed by your organization". That only refers to SiteBlock's block list.

### The `siteblock` command

The `siteblock` command does everything the panel does. On a Mac, run it in Terminal. On Windows, it works in any terminal opened after the install (Command Prompt, PowerShell or Windows Terminal).

```
siteblock status                          # show the blocked sites, countdowns and settings
siteblock add youtube.com                 # block a site
siteblock add youtube.com/shorts          # block part of a site
siteblock add --whole-site <link>         # block the whole site a link points to
siteblock unblock youtube.com             # unblock for good, after the waiting period
siteblock unblock youtube.com --for 1h    # unblock for an hour, after the waiting period
siteblock unblock youtube.com --for 30m --in 3h   # unblock for 30 minutes, starting in 3 hours
siteblock cancel youtube.com              # keep a site blocked, or end a temporary unblock
siteblock delay 2h                        # change the waiting period
siteblock passwd                          # change the SiteBlock password
siteblock version
```

Every command that loosens a block asks for the SiteBlock password.

## The adult content filter

SiteBlock blocks adult websites whether or not they are on your list. No setting, password or waiting period turns this off; only uninstalling SiteBlock removes it. The filter has two layers, and they work the same way on both systems.

The first layer changes the DNS servers (the servers that turn a site's name into its numeric address) of every network connection to the CleanBrowsing Family Filter. That service refuses to look up adult sites. It also refuses VPN and proxy sites (services that would route around the filter), blocks mixed-content sites such as Reddit, and forces SafeSearch in Google and Bing and YouTube's restricted mode, in every browser and app. SiteBlock saves the DNS servers each connection had before and puts them back when you uninstall.

The second layer works inside the browsers, through the same browser settings that hold your block list. Chrome, Edge and Brave are set to always use Google SafeSearch, Chrome and Brave turn on their adult-site filter, and Edge makes Bing SafeSearch strict. Each browser's own encrypted name lookups (Secure DNS in Chrome, Edge and Brave, DNS-over-HTTPS in Firefox) are switched off, and locked off in Firefox, because they would skip both the hosts file and the family DNS servers.

The family servers are used only while they answer. On Wi-Fi with a sign-in page (a captive portal, such as in a hotel or café) and on networks that force their own DNS, they do not answer, so SiteBlock leaves the network's own DNS in place and you can sign in and browse. It checks again every 30 seconds and whenever the network changes, and switches back to the family servers as soon as they answer. Until then only the browser layer is active. A VPN supplies its own DNS servers, and SiteBlock does not change VPN connections, so a VPN skips the DNS layer; the browser layer still applies.

## Updating

SiteBlock checks for a new version once a day. When one exists, the panel shows "Update available" with an Update button. Press it, then enter the Mac's password, or on Windows click Yes when Windows asks for permission. You can also press "Check for updates" in Settings, which also shows the installed version.

To update by hand instead, download the zip again, unzip it and run the installer again (`Install SiteBlock.command` on a Mac, `Install SiteBlock.cmd` on Windows). Either way, your blocked sites, the SiteBlock password, the waiting period and every running countdown are kept.

## Forgotten password

Start a password reset with administrator rights.

On a Mac, run this in Terminal and enter the Mac's password:

```bash
sudo siteblock recover
```

On Windows, open the Start menu, type "Terminal" (or "PowerShell"), right-click it, choose "Run as administrator", and run:

```
siteblock recover
```

After 48 hours the SiteBlock password is cleared, and you choose a new one the next time you block a site. Your blocked sites stay blocked the whole time. `siteblock recover --cancel` stops the reset.

## Uninstalling

Click the shield icon, open Settings and press "Uninstall SiteBlock…", or run `siteblock uninstall`. Both ask for the SiteBlock password and then wait 48 hours (or your waiting period, if you have set it longer than that) before removing SiteBlock. Every site stays blocked during the wait, and `siteblock uninstall --cancel` stops it.

When the wait ends, SiteBlock removes its background services, the menu bar or tray app, its lines in the hosts file and its settings in Chrome, Edge, Brave and Firefox, and puts your original DNS servers back.

## What SiteBlock can and cannot stop

SiteBlock is built to stop the person who uses the computer from undoing a block on impulse. It cannot stop a determined administrator.

**On both systems**, SiteBlock undoes changes made to get around it, usually within a few seconds. It rewrites its lines in the hosts file if anyone edits them, including lines elsewhere in the file that point a blocked site at a real address. It restarts its background service if the service is stopped, restores its files and folders if they are deleted, rewrites its saved settings if that file is deleted, restarts the shield app if it is closed, and resets browser and DNS settings that are changed by hand. Countdowns use a clock that cannot be changed, so moving the computer's date forward does not skip a wait. Five wrong passwords lock password checks for 15 minutes.

**On a Mac**, it also clears the "locked" file flag that the `chflags` command can set on the hosts file, and it puts the menu bar app back if the app is deleted or moved to the Trash. SiteBlock also keeps iCloud Private Relay turned off; see [How it works](#how-it-works) for why.

**On Windows**, it also puts the hosts file back when the file is made read-only, locked against Windows' own SYSTEM account, or moved by changing the `DataBasePath` registry setting. It re-enables a service that is set to Disabled and recreates a service that is deleted.

**What it cannot stop.** An administrator can always remove any program from their own computer. On a Mac, an administrator can stop both background jobs at once, or stop the service and edit its saved settings before it restarts, or switch SiteBlock off under System Settings → General → Login Items & Extensions → "Allow in the Background" (leave that switch on). On Windows, an administrator can stop both services within the same few seconds and then delete SiteBlock's files, or start Windows in Safe Mode, where the services do not run. SiteBlock also does not stop a VPN (a service that sends all traffic through another computer) or a proxy that looks up site names remotely, although the block lists inside Chrome, Edge, Brave and Firefox still apply.

**For the strongest protection**, use a standard (non-administrator) account day to day, and let someone else keep the administrator password. Then none of the administrator workarounds are available.

## How it works

Before any app connects to a website, it looks up the site's numeric address, and the operating system checks a file called the hosts file before asking the internet. On a Mac the file is `/etc/hosts`; on Windows it is `C:\Windows\System32\drivers\etc\hosts`. SiteBlock writes lines such as `0.0.0.0 youtube.com` into that file. `0.0.0.0` is an address that leads nowhere, so the browser shows a "can't connect" page. Because this happens below the browser, it applies to every browser and app. The hosts file cannot use wildcards, which is why SiteBlock writes each common variant of a site separately.

SiteBlock also writes your blocked sites into the block lists that Chrome, Edge, Brave and Firefox read from their policy settings (settings browsers normally use on company computers). The browsers then refuse those sites themselves, in every window and profile, even in a window that sends its traffic through a proxy or SSH tunnel and so never checks the hosts file. These block lists are also what makes blocking part of a site possible.

Three programs make this work:

- `siteblockd` is a background service that runs with full system rights (root on a Mac, the SYSTEM account on Windows). It owns the block list and the password check, and it keeps the hosts file, the browser settings and the DNS settings the way they should be.
- A second copy of `siteblockd` runs as a watchdog. The service and the watchdog each restart the other if it is stopped.
- The shield app and the `siteblock` command are how you control it. They send each request to the service, which decides whether to accept it.

On a Mac, SiteBlock keeps iCloud Private Relay (Apple's paid service that sends Safari's traffic through Apple's servers) turned off for as long as SiteBlock is installed. Private Relay sends Safari's site lookups to Apple instead of checking `/etc/hosts`, which would let Safari skip both the block and the adult content filter. SiteBlock uses the method Apple documents for networks: it blocks the two names Private Relay needs, so macOS reports Private Relay as unavailable.

## Logs and repairs

**On a Mac**, the service writes to `/Library/Logs/SiteBlock/siteblockd.log` and the watchdog to `/Library/Logs/SiteBlock/watchdog.log`.

**On Windows**, the service writes to `C:\ProgramData\SiteBlock\Logs\siteblockd.log`, and the watchdog log (`watchdog.log`) and the update log (`update.log`) are in the same folder.

A line saying "hosts file repaired" means something edited the hosts file and SiteBlock put its lines back. A line saying "family DNS unreachable" means the family DNS servers do not answer on the current network, so SiteBlock is using the network's own DNS until they do. The logs never contain your sites or your password.

If an install breaks, run the installer again (`Install SiteBlock.command` or `Install SiteBlock.cmd`). It replaces the programs and restarts the background services, and it keeps every block, the password and every countdown.

## Building from source

The design documents are in `Design Plans/`, starting with `00-INDEX.md`. The Mac version is written in Swift and lives at the top of the repository; the Windows version is written in C# and lives in `windows/`, with its design in `Design Plans/06-windows.md`.

### Mac

Building needs Xcode or Apple's Command Line Tools (install them with `xcode-select --install`). From the repository folder, double-click `Install SiteBlock.command`; it builds SiteBlock, installs it and checks that it runs. The same steps in Terminal, run from the repository folder:

```bash
scripts/build.sh && sudo scripts/install.sh && scripts/verify-install.sh
```

`scripts/verify-install.sh` checks the installed system. Once you have blocked `youtube.com`, it also confirms the site is blocked in Safari and Chrome.

Run the tests with `scripts/test.sh`. It adds the compiler flags that Swift Testing needs when only the Command Line Tools are installed, and leaves them out when Xcode is. The integration tests start the real `siteblockd` in sandbox mode, which uses a temporary folder in place of `/etc/hosts` and the system folders, so the tests need no administrator password.

To build a package for other Macs, run `scripts/package.sh`. It writes `dist/SiteBlock.zip` and `dist/version.json` (the small file the app reads to learn the newest version). A GitHub Actions workflow (`.github/workflows/package.yml`) builds the package on a fresh Apple Silicon Mac and runs every test on each push to `master` that changes the app. It publishes the zip and `version.json` as a new release only when the release number, `siteBlockBuildNumber` in `Sources/SiteBlockCore/Models.swift`, is higher than the published one, so a release means raising that number by one and pushing. A failing test stops it, so a broken package is never published.

To see what SiteBlock finds on each network connection and what it would do about its DNS servers, run `build/siteblockd --print-dns-plan` (the installed copy is `/usr/local/libexec/siteblock/siteblockd`). It only reads and changes nothing, so it needs no administrator rights.

### Windows

Building needs the .NET 10 SDK. On Windows, right-click `windows\Install SiteBlock.cmd` in the repository and choose "Run as administrator"; it builds SiteBlock for the PC's processor, installs it and checks that it runs. To only build, run:

```
powershell -ExecutionPolicy Bypass -File windows\scripts\build.ps1
```

Run the tests on Windows with `dotnet test windows/SiteBlock.sln`. `windows/scripts/package.ps1` builds the Intel/AMD and Arm programs and writes `windows/dist/SiteBlock-Windows.zip`. The `.github/workflows/windows.yml` workflow runs every test, installs the package on a fresh Windows machine, and runs the end-to-end checks (`windows/scripts/e2e.ps1`). On `master` it publishes a release only when `SiteBlockBuildNumber` in `windows/version.props` is higher than the published one, so a Windows release means raising that number by one and pushing.

### Download counts

`scripts/stats.sh` (Mac) and `windows/scripts/stats.sh` (Windows) print how often each version has been downloaded, plus the number of update checks, which roughly counts the copies in use. They read GitHub's public release data and need no login.

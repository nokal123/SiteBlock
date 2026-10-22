# SiteBlock

SiteBlock blocks websites on your Mac or Windows PC for every browser at once, including Safari, Chrome, Edge and Firefox, with no browser extension. It keeps a site blocked until you unblock it. Unblocking needs the SiteBlock password, and even then the site stays blocked for a waiting period (30 minutes by default) before it opens.

## Download

- **Mac** (Apple chip, M1 or newer, macOS 14 or newer): **https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip**. See [Installing on another Mac](#installing-on-another-mac).
- **Windows** (Windows 11, or Windows 10 version 2004 or newer, on an Intel, AMD or Arm PC): **https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip**. See [SiteBlock for Windows](#siteblock-for-windows).

Both links always give the newest version, and the app updates itself after that. The first Windows release is [version 1.0.0](https://github.com/nokal123/SiteBlock/releases/tag/windows-v1.0.0); every Windows version is listed on the [releases page](https://github.com/nokal123/SiteBlock/releases) under tags that start with `windows-v`.

## How it works

Before any app on a Mac connects to a website, it looks up the site's numeric address, and macOS checks the file `/etc/hosts` before asking the internet. SiteBlock writes lines such as `0.0.0.0 youtube.com` into that file. `0.0.0.0` is an address that leads nowhere, so the browser shows a "can't connect" page. Because this happens below the browser, it applies to Safari, Chrome, Firefox and every other app.

Three programs make this work:

- `siteblockd` is a background service that runs as root (the administrator account allowed to change system files). It owns the block list and rewrites its part of `/etc/hosts` within two seconds if anyone edits it.
- A second copy of `siteblockd` runs as a watchdog. The service and the watchdog each restart the other if it is stopped.
- `SiteBlock.app` (the shield icon in the menu bar) and the `siteblock` Terminal command are how you control it.

SiteBlock also keeps iCloud Private Relay (Apple's paid service that sends Safari's traffic through Apple's servers) turned off, for as long as SiteBlock is installed. Private Relay sends Safari's site lookups to Apple instead of checking `/etc/hosts`, which would let Safari skip the block, and it would also skip the adult content filter described below. SiteBlock uses the method Apple documents for networks: it blocks the two names Private Relay needs, so macOS reports Private Relay as unavailable. SiteBlock also writes your blocked sites into Chrome's own block list, a setting Chrome normally uses on company computers. Chrome then refuses those sites itself, in every window and profile, even in a Chrome window that sends its traffic through a proxy or SSH tunnel and so never checks `/etc/hosts`. Chrome's menu always shows "Managed by your organization"; that only refers to SiteBlock's settings. Microsoft Edge, Brave and Firefox get the same protected block list, and Firefox's own encrypted name lookups (DNS-over-HTTPS), which would otherwise skip `/etc/hosts`, are switched off and locked.

A site you block also blocks its common variants, because the hosts file cannot use wildcards. Blocking `youtube.com` also blocks `www.youtube.com`, `m.youtube.com`, `youtu.be`, `music.youtube.com`, YouTube Kids, and the servers that hold YouTube's thumbnails and page files.

## Adult content filter (always on)

SiteBlock blocks adult websites whether or not they are on your list. There is no setting, password or waiting period that turns this off; only uninstalling SiteBlock removes it. It has two layers. First, it sets the DNS servers (the servers that turn site names into addresses) of every network connection to Cloudflare for Families, which refuses to look up adult sites. SiteBlock saves the servers each connection had before and puts them back when you uninstall. Second, through the same Chrome settings file that holds your block list, it turns on SafeSearch and Chrome's adult-site filter, and it turns off Chrome's Secure DNS so that Chrome uses the Mac's DNS servers too.

The family servers are used only while they answer. On Wi-Fi with a sign-in page (a captive portal, such as in a hotel or café) and on networks that force their own DNS, they do not answer, so SiteBlock leaves the network's own DNS in place and you can sign in and browse. It checks again every 30 seconds and when the network changes, and sets the family servers again as soon as they answer. Until then only the Chrome layer is active. A VPN supplies its own DNS servers, and SiteBlock does not change VPN connections, so a VPN bypasses the DNS layer; the Chrome layer still applies in Chrome.

## Install

Double-click **`Install SiteBlock.command`** in this folder. Terminal opens, builds SiteBlock, asks for your Mac password to install the background service, and checks that the service is running. Once you have blocked youtube.com from the menu bar, run `scripts/verify-install.sh` to confirm it is blocked in Safari and Chrome.

The same steps from Terminal:

```bash
cd ~/Desktop/Work/Projects/SiteBlock && scripts/build.sh && sudo scripts/install.sh && scripts/verify-install.sh
```

Installing asks only for your Mac password. You choose your SiteBlock password the first time you block a site: click the shield icon in the menu bar, type a site and press Block, and the panel asks you to choose it. This password is separate from your Mac password, and it cannot be shown again, so store it somewhere you trust (or give it to someone else to hold).

## Installing on another Mac

The newest package is always at **https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip**. A GitHub Actions workflow rebuilds it on every push to `master` that changes the app: it builds on a fresh Apple Silicon Mac, runs every test, runs `scripts/package.sh`, and replaces the "latest" release with `SiteBlock.zip` and `version.json` (the small file the app reads to learn the newest version). A failing test stops it, so a broken package is never published.

To build one yourself instead, run `scripts/package.sh`. It builds SiteBlock and writes `dist/SiteBlock.zip` (under 1 MB) and `dist/version.json`. Send that zip to the other Mac, which needs an Apple chip (M1 or newer) and macOS 14 or newer; it needs no developer tools. The `INSTALL.txt` inside tells the person there what to do: unzip, right-click "Install SiteBlock.command" and choose Open (macOS warns because SiteBlock is not signed with an Apple developer certificate), and enter that Mac's administrator password. They choose their own SiteBlock password at their first block; nothing from your Mac is copied. Only install it on a Mac whose user wants it, because it is deliberately hard to remove.

## Updating

The menu bar app checks GitHub once a day. When a newer version exists, the panel shows "Update available" with an Update button; press it, and macOS asks for your Mac password to install it. You can also press "Check for updates" in Settings. To update by hand instead, download **https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip** again, unzip it and rerun the installer (`Install SiteBlock.command`). Either way, your blocked sites, the SiteBlock password, the waiting period and every running countdown are kept. The version is `1.0.` followed by the number of commits the build was made from, and Settings shows the installed one.

## Everyday use

**Block a site:** open the menu bar panel, type the site (for example `youtube.com`, or paste a full link) and press Block. Blocking never needs the password and takes effect at once. A tab that was already open on the site may keep working for a minute or two until the browser closes its existing connection; reloading after that shows the block.

**Block part of a site:** type a path after the site name, such as `youtube.com/shorts`, or paste a link to the page you want gone. The panel then offers "Only this part" (already selected) and "Whole site". "Only this part" blocks every address on that site whose path starts with what you typed, such as `youtube.com/shorts/abc`, and leaves the rest of the site open. In Terminal, `siteblock add youtube.com/shorts` does the same, and `siteblock add --whole-site <link>` blocks the whole site instead. Blocked parts have their own list in the panel and unblock the same way as sites, with the password and then the waiting period. Two limits apply. Only the browsers' own block lists can block part of a site, so this works in Chrome, Edge, Brave and Firefox, and Safari can only block whole sites. And a browser checks its block list when a page loads, so a site that switches pages without loading a new one (YouTube does this when you tap a Short on its home page) is caught only when you reload or open the address directly.

**Unblock a site:** press "Unblock…" next to it and enter the password. The site stays blocked for the waiting period and then opens. While it waits, the row says "Still blocked" with a countdown, and "Keep blocked" cancels the unblock without a password.

**Change the waiting period:** open Settings. A longer wait applies at once. A shorter wait only takes effect after the current wait has passed, so it can't be shortened on impulse.

The Terminal command does all of the same things:

```
siteblock status
siteblock add youtube.com
siteblock add youtube.com/shorts
siteblock unblock youtube.com
siteblock cancel youtube.com
siteblock delay 2h
siteblock passwd
```

## Forgotten password

Run this in Terminal and enter your Mac password:

```bash
sudo siteblock recover
```

After 48 hours the SiteBlock password is cleared and you can set a new one. Your blocked sites stay blocked the whole time. `siteblock recover --cancel` stops the reset.

## Uninstall

Open Settings and press "Uninstall SiteBlock…", or run `siteblock uninstall`. Both ask for the password and then wait 48 hours (or your unblock delay, if you have set it longer than that) before removing SiteBlock. Every site stays blocked during the wait. When it ends, SiteBlock removes its background service, the menu bar app, its lines in `/etc/hosts` and its settings in Chrome, Edge, Brave and Firefox, and puts your original DNS servers back. `siteblock uninstall --cancel` stops a pending uninstall.

## What SiteBlock can and cannot stop

SiteBlock is built to stop the person who owns the Mac from undoing a block on impulse. It undoes hand edits to `/etc/hosts` within two seconds, including lines elsewhere in the file that point a blocked site at a real address, and it clears the "locked" file flag that `chflags` can set. It restarts its service if the service is stopped, restores its files and folders if they are deleted, and, while the service runs, rewrites its saved state if that is deleted or edited. The menu bar app is put back from a protected backup if it is deleted or moved to the Trash, and it is relaunched if it is closed. Countdowns use a clock that cannot be changed, so moving the Mac's date forward does not skip a wait. Five wrong passwords lock password checks for 15 minutes.

It cannot stop a determined administrator with time and knowledge, because the root account can always remove any program on its own Mac. For example, root can stop the service and edit its saved state before it restarts, or stop both background jobs at once. An administrator can also switch SiteBlock off under System Settings → General → Login Items & Extensions → "Allow in the Background"; leave that switch on. It also does not stop a VPN (a service that sends all traffic through another computer) or a proxy that looks up site names remotely.

For the strongest protection, use a standard (non-administrator) macOS account day to day and let someone else keep the administrator password. Then none of the root-level workarounds are available.

## Logs

The service writes to `/Library/Logs/SiteBlock/siteblockd.log` and the watchdog to `/Library/Logs/SiteBlock/watchdog.log`. A line saying "hosts file repaired" means something edited `/etc/hosts` and SiteBlock put its lines back. A line saying "family DNS unreachable" means the family DNS servers do not answer on the current network, so SiteBlock is using the network's own DNS until they do.

## SiteBlock for Windows

SiteBlock for Windows does the same job as the Mac version. It blocks the sites you choose in every browser and app on the PC, for everyone who uses it. Unblocking needs the SiteBlock password and then the waiting period, and it always blocks adult websites. It works the same way underneath: it writes the blocked sites into the Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`, the file Windows checks before looking a site up on the internet), puts them in the block lists of Chrome, Edge, Brave and Firefox, and sets every network connection's DNS servers to Cloudflare for Families.

**Requirements:** Windows 11, or Windows 10 version 2004 or newer, on an Intel, AMD or Arm PC, and an administrator account (or someone who knows an administrator password). One download serves every PC: the package holds the programs for both Intel/AMD and Arm processors, and the installer picks the right ones.

### Install on Windows

1. Download **https://github.com/nokal123/SiteBlock/releases/download/windows-latest/SiteBlock-Windows.zip**.
2. Unzip it: right-click the zip, choose "Extract All...", then click Extract. Keep the `SiteBlock` folder together, because the installer needs everything in it.
3. Open the `SiteBlock` folder, right-click **`Install SiteBlock.cmd`** and choose "Run as administrator". Double-clicking it also works; it then asks for administrator rights itself.
4. Windows may show a blue box that says "Windows protected your PC". This is Windows SmartScreen, which warns about programs that few people have downloaded and that are not signed with a paid code-signing certificate, which is true of SiteBlock. Click "More info", then "Run anyway".
5. Windows asks "Do you want to allow this app to make changes to your device?" (the UAC prompt, User Account Control). Click Yes. On an account that is not an administrator, type an administrator's password here.
6. A window shows the installer working. It copies SiteBlock into `C:\Program Files\SiteBlock`, sets up the two background services that keep the block in place, makes SiteBlock start every time someone signs in, and checks that everything works. Lines that start with SKIP are normal before you have blocked a site. When it says "SiteBlock is installed", press any key to close the window.

The same steps are in `INSTALL.txt` inside the zip, for the person installing it on another PC. Only install SiteBlock on a PC whose user wants it, because it is deliberately hard to remove.

### Using it on Windows

SiteBlock lives in a shield icon by the clock, at the right end of the taskbar. Click it, type a site (for example `youtube.com`) and press Block. The first time, SiteBlock asks you to choose your SiteBlock password; keep it safe, because it cannot be shown again. Blocking part of a site, unblocking, "Keep blocked", the "For a while" temporary unblock and the waiting period in Settings all work as on the Mac (see [Everyday use](#everyday-use)).

Windows often hides new tray icons. If you cannot see the shield, click the small ^ arrow by the clock; the shield is in the box that opens. Drag it onto the taskbar next to the clock to keep it visible, or on Windows 11 turn SiteBlock on under Settings > Personalization > Taskbar > Other system tray icons.

The `siteblock` command works in any new terminal (Command Prompt, PowerShell or Windows Terminal) after the install, with the same commands as on the Mac, such as `siteblock status` and `siteblock add youtube.com`. While any site is blocked, Chrome's and Edge's menus say "Managed by your organization"; that only refers to SiteBlock's block list.

### Updating on Windows

The tray app checks GitHub once a day. When a newer version exists, the panel shows a banner with an Update button; click it, then click Yes when Windows asks for permission. To update by hand instead, download the zip again and run `Install SiteBlock.cmd` again. Either way, your blocked sites, the SiteBlock password, the waiting period and every running countdown are kept. Settings shows the installed version.

### Forgotten password on Windows

Open the Start menu, type "Terminal" (or "PowerShell"), right-click it and choose "Run as administrator", then run:

```
siteblock recover
```

After 48 hours the SiteBlock password is cleared and you choose a new one the next time you block a site. Your blocked sites stay blocked the whole time, and `siteblock recover --cancel` stops the reset.

### Uninstall on Windows

Click the shield icon, open Settings and press "Uninstall SiteBlock…", or run `siteblock uninstall`. Both ask for the SiteBlock password and then wait 48 hours (or your unblock delay, if that is longer) before removing SiteBlock. Every site stays blocked during the wait. When it ends, SiteBlock removes its services, the tray app, its lines in the hosts file and its browser settings, and puts your original DNS servers back.

### What SiteBlock can and cannot stop on Windows

SiteBlock undoes changes made to get around it, usually within seconds. It puts back its lines in the hosts file, including when the file is made read-only, locked against Windows' own SYSTEM account, or moved by changing the `DataBasePath` registry setting. It restarts a service that is stopped, re-enables a service that is set to Disabled, and recreates a service that is deleted. It restores its program files from a protected backup, rewrites its saved state if that file is deleted, restarts the tray app if it is closed, and resets browser and DNS settings that are changed by hand. Countdowns use a clock that cannot be changed, and five wrong passwords lock password checks for 15 minutes.

It cannot stop a determined administrator, who can stop both services within the same few seconds and then delete SiteBlock's files, or start Windows in Safe Mode, where the services do not run. It also does not stop a VPN or a proxy that looks up site names remotely, although the browsers' own block lists still apply in Chrome, Edge, Brave and Firefox. For the strongest protection, use a standard (non-administrator) Windows account day to day and let someone else keep the administrator password.

### Logs on Windows

The service writes to `C:\ProgramData\SiteBlock\Logs\siteblockd.log` and the watchdog to `watchdog.log` in the same folder; the update log is `update.log` there too. The logs never contain your sites or your password. Running `Install SiteBlock.cmd` again repairs a broken install and keeps your blocked sites, the password and every countdown.

The Windows source code is in the `windows/` folder and its design is in `Design Plans/06-windows.md`.

## For developers

The design documents are in `Design Plans/`, starting with `00-INDEX.md`.

Run the tests with `scripts/test.sh`. It adds the compiler flags that Swift Testing needs on a Mac that has only the Command Line Tools and not Xcode. The integration tests start the real `siteblockd` in sandbox mode, which uses a temporary folder in place of `/etc/hosts` and the system folders, so the tests need no administrator password.

To see what SiteBlock finds on each network connection and what it would do about its DNS servers, run `siteblockd --print-dns-plan` (the installed copy is `/usr/local/libexec/siteblock/siteblockd`, and `build/` holds the copy that `scripts/build.sh` made). It only reads, needs no administrator rights, and changes nothing.

If an install breaks, run `sudo scripts/install.sh` again. It replaces the programs and restarts the background jobs, and it keeps every block, the password and every countdown.

To see how often SiteBlock has been downloaded (per version, plus update checks, which roughly count copies in use), run `scripts/stats.sh` for the Mac and `windows/scripts/stats.sh` for Windows.

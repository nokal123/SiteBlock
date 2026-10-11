# SiteBlock

SiteBlock blocks websites on your Mac for every browser at once, including Safari and Chrome, with no browser extension. It keeps a site blocked until you unblock it. Unblocking needs the SiteBlock password, and even then the site stays blocked for a waiting period (30 minutes by default) before it opens.

## How it works

Before any app on a Mac connects to a website, it looks up the site's numeric address, and macOS checks the file `/etc/hosts` before asking the internet. SiteBlock writes lines such as `0.0.0.0 youtube.com` into that file. `0.0.0.0` is an address that leads nowhere, so the browser shows a "can't connect" page. Because this happens below the browser, it applies to Safari, Chrome, Firefox and every other app.

Three programs make this work:

- `siteblockd` is a background service that runs as root (the administrator account allowed to change system files). It owns the block list and rewrites its part of `/etc/hosts` within two seconds if anyone edits it.
- A second copy of `siteblockd` runs as a watchdog. The service and the watchdog each restart the other if it is stopped.
- `SiteBlock.app` (the shield icon in the menu bar) and the `siteblock` Terminal command are how you control it.

While at least one site is blocked, SiteBlock also turns off iCloud Private Relay (Apple's paid service that sends Safari's traffic through Apple's servers). Private Relay sends Safari's site lookups to Apple instead of checking `/etc/hosts`, which would let Safari skip the block. SiteBlock uses the method Apple documents for networks: it blocks the two names Private Relay needs, so macOS reports Private Relay as unavailable. Private Relay comes back on its own once nothing is blocked. SiteBlock also writes your blocked sites into Chrome's own block list, a setting Chrome normally uses on company computers. Chrome then refuses those sites itself, in every window and profile, even in a Chrome window that sends its traffic through a proxy or SSH tunnel and so never checks `/etc/hosts`. While any site is blocked, Chrome's menu shows "Managed by your organization"; that only refers to this block list.

A site you block also blocks its common variants, because the hosts file cannot use wildcards. Blocking `youtube.com` also blocks `www.youtube.com`, `m.youtube.com`, `youtu.be`, `music.youtube.com`, YouTube Kids, and the servers that hold YouTube's thumbnails and page files.

## Install

Double-click **`Install SiteBlock.command`** in this folder. Terminal opens, builds SiteBlock, asks for your Mac password to install the background service, and checks that the service is running. Once you have blocked youtube.com from the menu bar, run `scripts/verify-install.sh` to confirm it is blocked in Safari and Chrome.

The same steps from Terminal:

```bash
cd ~/Desktop/Work/Projects/SiteBlock && scripts/build.sh && sudo scripts/install.sh && scripts/verify-install.sh
```

Installing asks only for your Mac password. You choose your SiteBlock password the first time you block a site: click the shield icon in the menu bar, type a site and press Block, and the panel asks you to choose it. This password is separate from your Mac password, and it cannot be shown again, so store it somewhere you trust (or give it to someone else to hold).

## Installing on another Mac

Run `scripts/package.sh`. It builds SiteBlock and writes `dist/SiteBlock-1.0.0.zip` (under 1 MB). Send that zip to the other Mac, which needs an Apple chip (M1 or newer) and macOS 14 or newer; it needs no developer tools. The `INSTALL.txt` inside tells the person there what to do: unzip, right-click "Install SiteBlock.command" and choose Open (macOS warns because SiteBlock is not signed with an Apple developer certificate), and enter that Mac's administrator password. They choose their own SiteBlock password at their first block; nothing from your Mac is copied. Only install it on a Mac whose user wants it, because it is deliberately hard to remove.

## Everyday use

**Block a site:** open the menu bar panel, type the site (for example `youtube.com`, or paste a full link) and press Block. Blocking never needs the password and takes effect at once. A tab that was already open on the site may keep working for a minute or two until the browser closes its existing connection; reloading after that shows the block.

**Unblock a site:** press "Unblock…" next to it and enter the password. The site stays blocked for the waiting period and then opens. While it waits, the row says "Still blocked" with a countdown, and "Keep blocked" cancels the unblock without a password.

**Change the waiting period:** open Settings. A longer wait applies at once. A shorter wait only takes effect after the current wait has passed, so it can't be shortened on impulse.

The Terminal command does all of the same things:

```
siteblock status
siteblock add youtube.com
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

Open Settings and press "Uninstall SiteBlock…", or run `siteblock uninstall`. Both ask for the password and then wait 48 hours (or your unblock delay, if you have set it longer than that) before removing SiteBlock. Every site stays blocked during the wait. When it ends, SiteBlock removes its background service, the menu bar app and its lines in `/etc/hosts`. `siteblock uninstall --cancel` stops a pending uninstall.

## What SiteBlock can and cannot stop

SiteBlock is built to stop the person who owns the Mac from undoing a block on impulse. It undoes hand edits to `/etc/hosts` within two seconds, including lines elsewhere in the file that point a blocked site at a real address, and it clears the "locked" file flag that `chflags` can set. It restarts its service if the service is stopped, restores its files and folders if they are deleted, and, while the service runs, rewrites its saved state if that is deleted or edited. The menu bar app is put back from a protected backup if it is deleted or moved to the Trash, and it is relaunched if it is closed. Countdowns use a clock that cannot be changed, so moving the Mac's date forward does not skip a wait. Five wrong passwords lock password checks for 15 minutes.

It cannot stop a determined administrator with time and knowledge, because the root account can always remove any program on its own Mac. For example, root can stop the service and edit its saved state before it restarts, or stop both background jobs at once. An administrator can also switch SiteBlock off under System Settings → General → Login Items & Extensions → "Allow in the Background"; leave that switch on. It also does not stop a VPN (a service that sends all traffic through another computer) or a proxy that looks up site names remotely.

For the strongest protection, use a standard (non-administrator) macOS account day to day and let someone else keep the administrator password. Then none of the root-level workarounds are available.

## Logs

The service writes to `/Library/Logs/SiteBlock/siteblockd.log` and the watchdog to `/Library/Logs/SiteBlock/watchdog.log`. A line saying "hosts file repaired" means something edited `/etc/hosts` and SiteBlock put its lines back.

## For developers

The design documents are in `Design Plans/`, starting with `00-INDEX.md`.

Run the tests with `scripts/test.sh`. It adds the compiler flags that Swift Testing needs on a Mac that has only the Command Line Tools and not Xcode. The integration tests start the real `siteblockd` in sandbox mode, which uses a temporary folder in place of `/etc/hosts` and the system folders, so the tests need no administrator password.

If an install breaks, run `sudo scripts/install.sh` again. It replaces the programs and restarts the background jobs, and it keeps every block, the password and every countdown.

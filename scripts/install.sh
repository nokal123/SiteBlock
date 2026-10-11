#!/bin/bash
# Installs (or upgrades) SiteBlock: copies the programs into place, writes the launchd plists, and starts the
# background jobs. Run it with sudo after scripts/build.sh. It is safe to run again for an upgrade.
#
#   sudo scripts/install.sh
#   scripts/install.sh --dry-run     (prints every action without doing it; needs no root)
#
# An upgrade never deletes state.json or state.backup.json: this script never removes the state folder
# or the backup folder, it only replaces the programs and plists.
set -euo pipefail

# Work from the repository root, wherever the script is started from.
cd "$(dirname "$0")/.."

# Read the command line: no argument, or --dry-run.
DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *)
        echo "usage: sudo scripts/install.sh [--dry-run]" >&2
        exit 64
        ;;
esac
if [[ $# -gt 1 ]]; then
    echo "usage: sudo scripts/install.sh [--dry-run]" >&2
    exit 64
fi

# Every location SiteBlock installs to (these match Paths.production in the Swift code).
BUILD_DIR="build"
APP_SUPPORT_DIR="/Library/Application Support/SiteBlock"
DAEMON_PROGRAM="$APP_SUPPORT_DIR/bin/siteblockd"
BACKUP_DIR="/usr/local/libexec/siteblock"
BACKUP_PROGRAM="$BACKUP_DIR/siteblockd"
BACKUP_APP="$BACKUP_DIR/SiteBlock.app"
LOG_DIR="/Library/Logs/SiteBlock"
CLI_DIR="/usr/local/bin"
CLI_DEST="$CLI_DIR/siteblock"
APP_DEST="/Applications/SiteBlock.app"
DAEMON_LABEL="com.nokal.siteblock.daemon"
WATCHDOG_LABEL="com.nokal.siteblock.watchdog"
APP_LABEL="com.nokal.siteblock.app"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
WATCHDOG_PLIST="/Library/LaunchDaemons/$WATCHDOG_LABEL.plist"
AGENT_PLIST="/Library/LaunchAgents/$APP_LABEL.plist"
SOCKET="/var/run/siteblock.sock"
NEWSYSLOG_DIR="/etc/newsyslog.d"
NEWSYSLOG_CONF="$NEWSYSLOG_DIR/siteblock.conf"

# If anything fails, say so clearly. Re-running the script is always safe.
trap 'echo "install.sh failed near line $LINENO. It is safe to run it again." >&2' ERR

# Prints a heading for the next group of actions.
step() {
    echo
    echo "==> $*"
}

# Runs a command, or only prints it in dry-run mode.
act() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Runs a command and ignores its failure (used for "unload this if it is loaded"), or only prints it in dry-run mode.
act_ignore() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] would run (failure ignored):'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

# Creates a folder (and any missing parents) and gives it the requested mode and root:wheel ownership.
make_dir() {
    local mode="$1" path="$2"
    act mkdir -p "$path"
    act chown root:wheel "$path"
    act chmod "$mode" "$path"
}

# Replaces a file with a fresh copy that has the requested mode and root:wheel ownership.
# The old file is removed first so a running or cached copy is never overwritten in place.
install_file() {
    local mode="$1" source="$2" dest="$3"
    act rm -f "$dest"
    act install -m "$mode" -o root -g wheel "$source" "$dest"
}

# Writes a launchd plist by asking the installed daemon program for its text, so the plist text has one source in the code.
# The program run here is the root-owned copy that step 4 installed, never build/siteblockd: the user's account can replace
# files under build/, and this script runs as root.
# The text goes to a temp file first, is checked with plutil, and is then moved into place.
write_plist() {
    local name="$1" dest="$2"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would write $dest from: $DAEMON_PROGRAM --print-plist $name (mode 0644, root:wheel)"
        return
    fi
    local temp="$dest.install.tmp"
    "$DAEMON_PROGRAM" --print-plist "$name" > "$temp"
    plutil -lint "$temp" >/dev/null
    chown root:wheel "$temp"
    chmod 0644 "$temp"
    mv -f "$temp" "$dest"
}

# Writes the log rotation settings that make macOS's newsyslog keep each SiteBlock log under 1 MB with 3 compressed old copies.
# The file goes to a temp file first and is then moved into place with mode 0644 and root:wheel ownership.
write_newsyslog_conf() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would write $NEWSYSLOG_CONF (mode 0644, root:wheel) rotating $LOG_DIR/siteblockd.log and $LOG_DIR/watchdog.log at 1024 KB with 3 compressed copies"
        return
    fi
    # The folder normally exists on macOS; mkdir -p only fills in a missing one and leaves an existing one alone.
    mkdir -p "$NEWSYSLOG_DIR"
    local temp="$NEWSYSLOG_CONF.install.tmp"
    {
        echo "$LOG_DIR/siteblockd.log  root:wheel  644  3  1024  *  JN"
        echo "$LOG_DIR/watchdog.log    root:wheel  644  3  1024  *  JN"
    } > "$temp"
    chown root:wheel "$temp"
    chmod 0644 "$temp"
    mv -f "$temp" "$NEWSYSLOG_CONF"
}

# True when launchd has the job loaded in the system domain.
is_loaded() {
    launchctl print "system/$1" >/dev/null 2>&1
}

# Unloads the watchdog and the daemon so neither restarts the other during the copy.
# Order: watchdog, daemon, watchdog again. The second watchdog call covers the rare case where the daemon
# reloaded the watchdog in the moment between the first two calls. The loop repeats until both are really gone.
unload_services() {
    if [[ $DRY_RUN -eq 1 ]]; then
        act_ignore launchctl bootout "system/$WATCHDOG_LABEL"
        act_ignore launchctl bootout "system/$DAEMON_LABEL"
        act_ignore launchctl bootout "system/$WATCHDOG_LABEL"
        echo "[dry-run] would check with 'launchctl print' that both jobs are unloaded, and repeat up to 5 times if not"
        return
    fi
    local attempt
    for attempt in 1 2 3 4 5; do
        launchctl bootout "system/$WATCHDOG_LABEL" >/dev/null 2>&1 || true
        launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
        launchctl bootout "system/$WATCHDOG_LABEL" >/dev/null 2>&1 || true
        if ! is_loaded "$WATCHDOG_LABEL" && ! is_loaded "$DAEMON_LABEL"; then
            return
        fi
        sleep 1
    done
    echo "error: could not unload the running SiteBlock jobs; stop them with launchctl and run this script again" >&2
    exit 1
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN: nothing will be changed, and no root access is needed."
fi

# Step 1: only root may install, and only when the build step has produced all three programs.
step "Step 1: checking requirements"
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
    echo "error: this script must run as root. Use: sudo scripts/install.sh" >&2
    exit 1
fi
missing=0
for item in siteblockd siteblock SiteBlock.app; do
    if [[ ! -e "$BUILD_DIR/$item" ]]; then
        echo "missing: $BUILD_DIR/$item"
        missing=1
    fi
done
if [[ $missing -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "(a real install would stop here: run scripts/build.sh first)"
    else
        echo "error: run scripts/build.sh first (as your normal user, without sudo)." >&2
        exit 1
    fi
else
    echo "found $BUILD_DIR/siteblockd, $BUILD_DIR/siteblock and $BUILD_DIR/SiteBlock.app"
fi

# Work out which user to start the menu bar app for: the person who ran sudo.
# When this script runs as real root (no SUDO_UID), there is no user to start it for.
AGENT_UID="${SUDO_UID:-}"
if [[ $DRY_RUN -eq 1 && -z "$AGENT_UID" ]]; then
    # A dry run is not under sudo; show the lines using the current user, which is who sudo would report.
    AGENT_UID="$(id -u)"
fi
if [[ "$AGENT_UID" == "0" ]]; then
    AGENT_UID=""
fi

# Step 2: create the folders. The state folder is root-only (0700) because it holds the password hash.
step "Step 2: creating folders"
make_dir 0700 "$APP_SUPPORT_DIR"
make_dir 0755 "$APP_SUPPORT_DIR/bin"
make_dir 0755 "$BACKUP_DIR"
make_dir 0755 "$LOG_DIR"
# /usr/local/bin may not exist on a new Apple Silicon Mac. It is only created when missing; an existing one is left alone,
# because on an Intel Mac it can belong to Homebrew and changing its owner or mode would break Homebrew.
act mkdir -p "$CLI_DIR"

# Step 3: unload the old jobs if they are loaded. state.json and state.backup.json are never touched here.
step "Step 3: unloading any running SiteBlock jobs (watchdog first, then the daemon)"
unload_services

# Step 4: copy the programs. The daemon and the menu bar app each go to two places: the one that is used, and a root-owned backup that the guards restore from.
# This step runs only after step 3 has unloaded the daemon and the watchdog (and checked that both are gone). That order matters:
# the daemon's app guard puts back a deleted or changed app within 5 seconds, so a daemon that was still running here would restore
# the old app from the old backup in the middle of the copy.
step "Step 4: copying programs"
# The backup of the menu bar app comes first. ditto copies the bundle with its signature intact; the old backup is removed first so no old file survives inside it.
act rm -rf "$BACKUP_APP"
act ditto "$BUILD_DIR/SiteBlock.app" "$BACKUP_APP"
act chown -R root:wheel "$BACKUP_APP"
install_file 0755 "$BUILD_DIR/siteblockd" "$DAEMON_PROGRAM"
install_file 0755 "$BUILD_DIR/siteblockd" "$BACKUP_PROGRAM"
install_file 0755 "$BUILD_DIR/siteblock" "$CLI_DEST"
# On an upgrade the old menu bar app may still be running and loaded; stop it so the new copy can be loaded in step 7.
# The agent is booted out before the app is killed: the agent restarts the app whenever it exits (KeepAlive), so killing first would only start it again.
if [[ -n "$AGENT_UID" ]]; then
    act_ignore launchctl bootout "gui/$AGENT_UID/$APP_LABEL"
fi
act_ignore pkill -x SiteBlock
act rm -rf "$APP_DEST"
act ditto "$BUILD_DIR/SiteBlock.app" "$APP_DEST"
act chown -R root:wheel "$APP_DEST"

# Step 5: write the launchd plists (two LaunchDaemons and one LaunchAgent) using the installed daemon program, then the log rotation settings.
step "Step 5: writing launchd plists and the log rotation settings"
write_plist daemon "$DAEMON_PLIST"
write_plist watchdog "$WATCHDOG_PLIST"
write_plist app "$AGENT_PLIST"
write_newsyslog_conf

# Step 6: start the daemon, then the watchdog.
step "Step 6: starting the daemon and the watchdog"
act launchctl bootstrap system "$DAEMON_PLIST"
act launchctl bootstrap system "$WATCHDOG_PLIST"

# Step 7: start the menu bar app in the login session of the person who ran sudo.
step "Step 7: starting the menu bar app"
if [[ -n "$AGENT_UID" ]]; then
    # A missing login session is not fatal: the app starts at the next login anyway.
    if [[ $DRY_RUN -eq 1 ]]; then
        act launchctl bootstrap "gui/$AGENT_UID" "$AGENT_PLIST"
    elif ! launchctl bootstrap "gui/$AGENT_UID" "$AGENT_PLIST"; then
        # The daemon's app guard loads the agent itself within a few seconds of starting in step 6, so the agent may already be loaded; that is a success, not a failure.
        if launchctl print "gui/$AGENT_UID/$APP_LABEL" >/dev/null 2>&1; then
            echo "The menu bar app is already loaded (the daemon's app guard loaded it)."
        else
            echo "warning: could not start the menu bar app now. It will start at your next login, or run: open $APP_DEST"
        fi
    fi
else
    echo "Not started: this script was not run through sudo from a login session, so there is no user to start it for."
    echo "Start it yourself with: open $APP_DEST"
fi

# Step 8: wait for the daemon's socket, show the status, and print what to do next.
# The status check runs as the person who ran sudo, not as root: it proves an ordinary account can reach the daemon, and it never runs a
# program from a user-writable folder (such as /usr/local/bin) as root. Without SUDO_UID there is no such person, so the check is skipped.
step "Step 8: checking that the daemon is answering"
STATUS_UID="${SUDO_UID:-}"
if [[ $DRY_RUN -eq 1 && -z "$STATUS_UID" ]]; then
    # A dry run is not under sudo; show the command using the current user, which is who sudo would report.
    STATUS_UID="$(id -u)"
fi
if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -n "$STATUS_UID" ]]; then
        echo "[dry-run] would wait up to 10 seconds for $SOCKET, then run as the invoking user: sudo -u \"#$STATUS_UID\" $CLI_DEST status"
    else
        echo "[dry-run] would wait up to 10 seconds for $SOCKET, then skip the status check (no SUDO_UID)"
    fi
else
    ready=0
    for _ in $(seq 1 20); do
        if [[ -S "$SOCKET" ]]; then
            ready=1
            break
        fi
        sleep 0.5
    done
    if [[ $ready -eq 0 ]]; then
        echo "error: the daemon did not create $SOCKET within 10 seconds. Look at $LOG_DIR/siteblockd.log" >&2
        exit 1
    fi
    if [[ -n "$STATUS_UID" ]]; then
        sudo -u "#$STATUS_UID" "$CLI_DEST" status
    else
        echo "Skipping the status check: this script was not run through sudo, so there is no user to run it as."
    fi
fi

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run finished. Nothing was changed."
    exit 0
fi
echo "SiteBlock is installed."
echo "Next steps:"
echo "  1. Click the shield icon in the menu bar, type a site (for example youtube.com) and press Block."
echo "     The first time, it asks you to choose your SiteBlock password."
echo "  2. Then run scripts/verify-install.sh to check that the block works in Safari and Chrome."
echo "Logs: $LOG_DIR"

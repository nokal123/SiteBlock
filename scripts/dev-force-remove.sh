#!/bin/bash
# DEVELOPER TOOL. Removes every installed SiteBlock file and the managed section of /etc/hosts at once, without the
# SiteBlock password and without the waiting period. It exists so a developer can recover a broken test install.
# It is never copied to the installed system. Normal users should uninstall with: siteblock uninstall
#
#   sudo scripts/dev-force-remove.sh
#   scripts/dev-force-remove.sh --dry-run     (prints every action without doing it; needs no root)
set -euo pipefail

# Work from the repository root, wherever the script is started from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Every location SiteBlock installs to (these match Paths.production in the Swift code).
APP_SUPPORT_DIR="/Library/Application Support/SiteBlock"
BACKUP_DIR="/usr/local/libexec/siteblock"
BACKUP_STATE="$BACKUP_DIR/state.backup.json"
LOG_DIR="/Library/Logs/SiteBlock"
CLI_PATH="/usr/local/bin/siteblock"
APP_PATH="/Applications/SiteBlock.app"
SOCKET="/var/run/siteblock.sock"
HOSTS_FILE="/etc/hosts"
DAEMON_LABEL="com.nokal.siteblock.daemon"
WATCHDOG_LABEL="com.nokal.siteblock.watchdog"
APP_LABEL="com.nokal.siteblock.app"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
WATCHDOG_PLIST="/Library/LaunchDaemons/$WATCHDOG_LABEL.plist"
AGENT_PLIST="/Library/LaunchAgents/$APP_LABEL.plist"

DRY_RUN=0

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

# Runs a command and ignores its failure (used for "stop this if it is running"), or only prints it in dry-run mode.
act_ignore() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] would run (failure ignored):'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

# True when launchd has the job loaded in the system domain.
is_loaded() {
    launchctl print "system/$1" >/dev/null 2>&1
}

# Unloads the watchdog and the daemon. Order: watchdog, daemon, watchdog again, repeated until neither is loaded.
# The second watchdog call covers the case where the daemon reloaded the watchdog between the first two calls.
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
    echo "warning: a SiteBlock job is still loaded after 5 attempts; removing files anyway" >&2
}

# Copies the hosts text from standard input to standard output without SiteBlock's managed section.
# A section is the lines from "# BEGIN SiteBlock..." to "# END SiteBlock". A BEGIN line with no END after it removes only
# that one line (so the rest of the file is never lost), and a stray END line is removed. Trailing blank lines are dropped,
# which also removes the blank line SiteBlock puts in front of its section.
# (awk is used instead of a sed range because a sed range with no END would delete everything to the end of the file.)
strip_managed_section() {
    awk '
        # Prints a line, holding blank lines back until a non-blank line follows so trailing blanks vanish.
        function emit(line) {
            if (line ~ /^[[:space:]]*$/) { blanks++; return }
            for (b = 0; b < blanks; b++) print ""
            blanks = 0
            print line
        }
        # A BEGIN with no END: drop the BEGIN line itself and keep everything that followed it.
        function release_orphan(   i) {
            for (i = 2; i <= held; i++) emit(buffer[i])
            held = 0
            inside = 0
        }
        /^[[:space:]]*# BEGIN SiteBlock/ {
            if (inside) release_orphan()
            inside = 1
            held = 1
            buffer[1] = $0
            next
        }
        /^[[:space:]]*# END SiteBlock[[:space:]]*$/ {
            # Closes the section (dropping it), or is a stray END; either way the line itself is not kept.
            inside = 0
            held = 0
            next
        }
        {
            if (inside) { buffer[++held] = $0 } else { emit($0) }
        }
        END { if (inside) release_orphan() }
    '
}

# Removes the managed section from the hosts file in place (the file keeps its owner and mode).
remove_hosts_section() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would remove the '# BEGIN SiteBlock' ... '# END SiteBlock' section from $HOSTS_FILE"
        return
    fi
    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo "$HOSTS_FILE does not exist; nothing to clean"
        return
    fi
    local temp
    temp="$(mktemp /tmp/siteblock-hosts.XXXXXX)"
    strip_managed_section < "$HOSTS_FILE" > "$temp"
    # Refuse to write an empty result over a hosts file that had content: that would mean the filter failed.
    if [[ ! -s "$temp" && -s "$HOSTS_FILE" ]]; then
        echo "error: the cleaned hosts file came out empty; leaving $HOSTS_FILE unchanged" >&2
        rm -f "$temp"
        return 1
    fi
    if cmp -s "$temp" "$HOSTS_FILE"; then
        echo "$HOSTS_FILE has no SiteBlock section"
    else
        # cat into the existing file keeps its inode, owner and mode.
        cat "$temp" > "$HOSTS_FILE"
        echo "removed the SiteBlock section from $HOSTS_FILE"
    fi
    rm -f "$temp"
}

# Runs the whole removal.
main() {
    case "${1:-}" in
        "") ;;
        --dry-run) DRY_RUN=1 ;;
        *)
            echo "usage: sudo scripts/dev-force-remove.sh [--dry-run]" >&2
            exit 64
            ;;
    esac
    if [[ $# -gt 1 ]]; then
        echo "usage: sudo scripts/dev-force-remove.sh [--dry-run]" >&2
        exit 64
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY RUN: nothing will be changed, and no root access is needed."
    elif [[ $EUID -ne 0 ]]; then
        echo "error: this script must run as root. Use: sudo scripts/dev-force-remove.sh" >&2
        exit 1
    fi

    # The user who ran sudo, for stopping the menu bar app in their login session.
    local agent_uid="${SUDO_UID:-}"
    if [[ $DRY_RUN -eq 1 && -z "$agent_uid" ]]; then
        # A dry run is not under sudo; show the lines using the current user, which is who sudo would report.
        agent_uid="$(id -u)"
    fi
    if [[ "$agent_uid" == "0" ]]; then
        agent_uid=""
    fi

    # Step 1: stop the menu bar app first (its LaunchAgent, then any copy that was opened by hand).
    step "Step 1: stopping the menu bar app"
    if [[ -n "$agent_uid" ]]; then
        act_ignore launchctl bootout "gui/$agent_uid/$APP_LABEL"
    else
        echo "no SUDO_UID, so the LaunchAgent is not booted out (it is removed with its plist below)"
    fi
    act_ignore pkill -x SiteBlock

    # Step 2: unload the watchdog, then the daemon, so neither restarts the other or rewrites files during the removal.
    step "Step 2: unloading the watchdog and the daemon"
    unload_services

    # Step 3: delete every installed file, the state file and its backup copy included.
    step "Step 3: removing installed files"
    act rm -f "$AGENT_PLIST" "$DAEMON_PLIST" "$WATCHDOG_PLIST"
    act rm -f "$CLI_PATH"
    act rm -rf "$APP_PATH"
    act rm -f "$SOCKET"
    act rm -f "$BACKUP_STATE"
    act rm -rf "$BACKUP_DIR"
    act rm -rf "$APP_SUPPORT_DIR"
    act rm -rf "$LOG_DIR"
    act rm -f "$HOSTS_FILE.siteblock.tmp"

    # Step 4: take SiteBlock's section out of the hosts file and clear the name cache.
    step "Step 4: cleaning the hosts file and flushing the name cache"
    remove_hosts_section
    act_ignore dscacheutil -flushcache
    act_ignore killall -HUP mDNSResponder

    echo
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "Dry run finished. Nothing was changed."
    else
        echo "SiteBlock has been removed."
    fi
}

# Run main only when the script is executed, not when another script sources it (the test for strip_managed_section does).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

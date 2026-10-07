#!/bin/bash
# Checks an installed SiteBlock end to end: the launchd jobs, the CLI, the hosts file, the name lookup, a real
# connection attempt, and what Safari and Chrome actually show. Run it as your normal user (not with sudo) after
# "sudo scripts/install.sh".
#
# It never asks for a SiteBlock password and never blocks anything: the password is chosen the first time you block
# a site. It uses youtube.com as the test site, so block youtube.com from the menu bar icon first. Checks 1, 2 and 6
# always run. The blocking checks (3, 4, 5 and 7) run only when "siteblock status" lists youtube.com; otherwise each
# prints SKIP and says what to do. Run the script again after blocking youtube.com to perform every check.
# To unblock youtube.com afterwards: siteblock unblock youtube.com
#
# Every check runs even when an earlier one fails (there is no "set -e" on purpose). Each check prints PASS, FAIL,
# SKIP or MANUAL CHECK, and a summary follows. The exit code is 1 when any check printed FAIL, otherwise 0. A SKIP
# never makes the script fail.
set -uo pipefail

# Work from the repository root, wherever the script is started from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The test site, and the page the browser checks open.
TEST_DOMAIN="youtube.com"
TEST_PAGE_URL="https://www.youtube.com"
# Where the programs and files are. The environment can override them so the script itself can be tested against a sandbox daemon.
CLI="${SITEBLOCK_CLI:-/usr/local/bin/siteblock}"
HOSTS_FILE="${SITEBLOCK_HOSTS:-/etc/hosts}"
# How long to wait for a browser to load the page before reading it.
BROWSER_WAIT_SECONDS="${SITEBLOCK_BROWSER_WAIT:-6}"
DAEMON_LABEL="com.nokal.siteblock.daemon"
WATCHDOG_LABEL="com.nokal.siteblock.watchdog"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
MANUAL_COUNT=0

# Records and prints a passed check.
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: $*"
}

# Records and prints a failed check.
fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: $*"
}

# Records and prints a check that was skipped because it does not apply (for example Chrome is not installed).
skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo "SKIP: $*"
}

# Records and prints a check that a person has to finish by looking at the screen.
manual() {
    MANUAL_COUNT=$((MANUAL_COUNT + 1))
    echo "MANUAL CHECK: $*"
}

# Prints a heading for a check.
heading() {
    echo
    echo "[$1] $2"
}

# Prints text indented, for command output shown under a check.
indent() {
    sed 's/^/    /'
}

# Check 1: both launchd jobs are loaded.
check_jobs_loaded() {
    heading 1 "launchd jobs are loaded"
    local label
    for label in "$DAEMON_LABEL" "$WATCHDOG_LABEL"; do
        if launchctl print "system/$label" >/dev/null 2>&1; then
            pass "$label is loaded"
        else
            fail "$label is not loaded (try: sudo scripts/install.sh)"
        fi
    done
}

# Check 2: the command-line tool can talk to the daemon. The status text and the exit code are kept in STATUS_TEXT
# and STATUS_CODE for the checks that follow.
STATUS_TEXT=""
STATUS_CODE=1
check_status() {
    heading 2 "siteblock status works"
    STATUS_TEXT="$("$CLI" status 2>&1)"
    STATUS_CODE=$?
    echo "$STATUS_TEXT" | indent
    if [[ $STATUS_CODE -eq 0 ]]; then
        pass "siteblock status exited 0"
    else
        fail "siteblock status exited $STATUS_CODE"
    fi
}

# True when the status text saved by check 2 lists the test site as a blocked site. Each site line looks like
# "  youtube.com (28 hosts)", so a line is a match when it starts with two spaces, the domain, and a space.
test_site_is_blocked() {
    [[ $STATUS_CODE -eq 0 ]] || return 1
    local line
    while IFS= read -r line; do
        if [[ "$line" == "  $TEST_DOMAIN "* ]]; then
            return 0
        fi
    done <<<"$STATUS_TEXT"
    return 1
}

# Prints the SKIP line for a blocking check when the test site is not blocked. This script never blocks anything
# itself, so the person has to do it. When "siteblock status" itself failed, the site's state is unknown, and
# telling the person to block it would be the wrong advice.
skip_until_blocked() {
    if [[ $STATUS_CODE -ne 0 ]]; then
        skip "cannot tell whether $TEST_DOMAIN is blocked, because siteblock status failed (see check 2)"
    else
        skip "Block $TEST_DOMAIN from the menu bar icon, then run scripts/verify-install.sh again."
    fi
}

# Check 3: the hosts file has the lines that block the test site: the site itself, its www and m forms, and its short
# link name youtu.be, each in the IPv4 form (0.0.0.0), plus the site itself in the IPv6 form (::). Needs the test
# site to be blocked already.
check_hosts_lines() {
    heading 3 "the hosts file has the lines that block $TEST_DOMAIN"
    if ! test_site_is_blocked; then
        skip_until_blocked
        return
    fi
    local line missing=0
    for line in "0.0.0.0 $TEST_DOMAIN" "0.0.0.0 www.$TEST_DOMAIN" "0.0.0.0 m.$TEST_DOMAIN" "0.0.0.0 youtu.be" ":: $TEST_DOMAIN"; do
        if grep -qxF "$line" "$HOSTS_FILE" 2>/dev/null; then
            echo "    found: $line"
        else
            echo "    MISSING: $line"
            missing=1
        fi
    done
    if [[ $missing -eq 0 ]]; then
        pass "$HOSTS_FILE contains every expected line for $TEST_DOMAIN"
    else
        fail "$HOSTS_FILE is missing at least one expected line for $TEST_DOMAIN"
    fi
}

# Check 4: the macOS name lookup (not just the file) returns 0.0.0.0 for the test site.
check_lookup() {
    heading 4 "the system name lookup returns 0.0.0.0 for $TEST_DOMAIN"
    if ! test_site_is_blocked; then
        skip_until_blocked
        return
    fi
    local output="" attempt
    # The daemon clears the name cache before it replies, but a retry or two costs nothing and avoids a false alarm.
    for attempt in 1 2 3; do
        output="$(dscacheutil -q host -a name "$TEST_DOMAIN" 2>&1)"
        if [[ "$output" == *"0.0.0.0"* ]]; then
            break
        fi
        sleep 1
    done
    echo "$output" | indent
    if [[ "$output" == *"0.0.0.0"* ]]; then
        pass "dscacheutil resolves $TEST_DOMAIN to 0.0.0.0"
    else
        fail "dscacheutil did not return 0.0.0.0 for $TEST_DOMAIN"
    fi
}

# Check 5: a real connection attempt fails. curl is told to ignore any proxy settings, since a proxy would do the lookup elsewhere.
check_connection() {
    heading 5 "a real connection to $TEST_DOMAIN fails"
    if ! test_site_is_blocked; then
        skip_until_blocked
        return
    fi
    local url code
    for url in "https://$TEST_DOMAIN" "$TEST_PAGE_URL"; do
        curl --noproxy '*' --silent --show-error --output /dev/null --max-time 5 "$url" 2>/dev/null
        code=$?
        if [[ $code -eq 0 ]]; then
            fail "curl reached $url, so the site is NOT blocked"
        else
            pass "curl could not reach $url (curl exit code $code: 6 = cannot resolve, 7 = cannot connect, 28 = timed out)"
        fi
    done
}

# Check 6: the daemon says the hosts file is healthy, and the managed section is really in the file. SiteBlock
# removes its section from the hosts file while nothing is blocked, so the BEGIN and END markers are expected only
# once at least one site is blocked.
check_hosts_healthy() {
    heading 6 "the daemon reports a healthy hosts file"
    local output code
    output="$("$CLI" status 2>&1)"
    code=$?
    if [[ $code -ne 0 ]]; then
        fail "siteblock status exited $code"
    elif [[ "$output" == *"hosts file could not be brought into the right state"* ]]; then
        fail "siteblock status warns that the hosts file is not in the right state"
    else
        pass "siteblock status shows no hosts file warning"
    fi
    if [[ $code -ne 0 ]]; then
        skip "cannot tell whether $HOSTS_FILE should hold a SiteBlock section, because siteblock status failed"
    elif [[ "$output" != *"Blocked sites ("* ]]; then
        pass "no site is blocked yet, so SiteBlock keeps no section in $HOSTS_FILE (nothing to look for)"
    elif grep -q "^# BEGIN SiteBlock" "$HOSTS_FILE" 2>/dev/null && grep -q "^# END SiteBlock" "$HOSTS_FILE" 2>/dev/null; then
        pass "$HOSTS_FILE has SiteBlock's BEGIN and END markers"
    else
        fail "$HOSTS_FILE is missing SiteBlock's BEGIN and END markers"
    fi
}

# Runs one line of AppleScript with a 30 second limit (so a stuck permission prompt cannot hang the script).
# The output (or the error text) is left in OSA_OUT and osascript's exit code is returned.
OSA_OUT=""
osa() {
    OSA_OUT="$(osascript -e 'with timeout of 30 seconds' -e "$1" -e 'end timeout' 2>&1)"
    return $?
}

# True when AppleScript's error text says macOS refused to let this program control the browser (error -1743).
osa_was_denied() {
    [[ "$OSA_OUT" == *"-1743"* || "$OSA_OUT" == *"Not authorized to send Apple events"* ]]
}

# Opens the test page in one browser, waits, reads what the front tab shows, and decides.
# Arguments: label, application name, then three AppleScript lines: read the title with page JavaScript,
# read the title from the tab itself (the fallback), and read the tab's URL.
# JavaScript from Apple Events is off by default in both browsers, so the fallback is the usual path.
check_one_browser() {
    local label="$1" app="$2" js_script="$3" title_script="$4" url_script="$5"
    echo
    echo "--- $label"

    local open_output
    if ! open_output="$(open -a "$app" "$TEST_PAGE_URL" 2>&1)"; then
        skip "$label could not be opened ($open_output)"
        return
    fi
    echo "opened $TEST_PAGE_URL in $label; waiting $BROWSER_WAIT_SECONDS seconds for it to load"
    sleep "$BROWSER_WAIT_SECONDS"

    local title="" method="" denied=0 problem=""
    # First choice: ask the page itself for its title.
    if osa "$js_script" && [[ -n "$OSA_OUT" ]]; then
        title="$OSA_OUT"
        method="page JavaScript"
    elif osa_was_denied; then
        denied=1
    else
        # JavaScript from Apple Events is off (or the page returned nothing): read the tab's title instead.
        if osa "$title_script"; then
            title="$OSA_OUT"
            method="tab title"
        elif osa_was_denied; then
            denied=1
        else
            problem="$OSA_OUT"
        fi
    fi

    if [[ $denied -eq 1 ]]; then
        manual "macOS did not allow this script to read $label. Look at the $label window that just opened. It should say it cannot connect (Safari: \"Can't Connect to the Server\"; Chrome: \"This site can't be reached\"), and must not show the YouTube home page. To let the script read the tab next time, allow your terminal app under System Settings > Privacy & Security > Automation."
        return
    fi
    if [[ -z "$title" ]]; then
        manual "could not read a page title from $label${problem:+ ($problem)}. Look at the $label window: it should say it cannot connect, not show YouTube."
        return
    fi

    # Also read the URL, to make sure the front tab is really the test page and not some other tab.
    local url=""
    if osa "$url_script"; then
        url="$OSA_OUT"
        # A page that failed to load can report "missing value" instead of its address; that means unknown.
        if [[ "$url" == "missing value" ]]; then
            url=""
        fi
    fi
    echo "read via $method: title=\"$title\" url=\"${url:-unknown}\""

    if [[ -n "$url" && "$url" != *youtube.com* ]]; then
        manual "the front $label tab is not the test page (its URL is $url). Look at $label and check that $TEST_PAGE_URL cannot connect."
    elif [[ "$title" == *YouTube* ]]; then
        fail "$label shows a page titled \"$title\", so YouTube loaded and is NOT blocked"
    else
        pass "$label shows \"$title\", not YouTube (a blocked page)"
    fi
}

# Check 7: what the real browsers show.
check_browsers() {
    heading 7 "Safari and Chrome cannot load $TEST_PAGE_URL"
    if ! test_site_is_blocked; then
        skip_until_blocked
        return
    fi
    check_one_browser "Safari" "Safari" \
        'tell application "Safari" to do JavaScript "document.title" in front document' \
        'tell application "Safari" to name of front document' \
        'tell application "Safari" to URL of front document'
    check_one_browser "Chrome" "Google Chrome" \
        'tell application "Google Chrome" to execute front window'"'"'s active tab javascript "document.title"' \
        'tell application "Google Chrome" to title of active tab of front window' \
        'tell application "Google Chrome" to URL of active tab of front window'
    echo
    echo "You can close the $TEST_DOMAIN tabs that were opened. A browser tab that was already connected to a site before it was blocked may keep loading for a short while; reload it after a minute."
}

# Prints the result totals and the follow-up commands a person can run. Skipped checks do not count as failures.
print_summary() {
    echo
    echo "=============================================="
    echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $MANUAL_COUNT manual checks, $SKIP_COUNT skipped"
    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo "RESULT: PASS (no failed checks)"
    else
        echo "RESULT: FAIL ($FAIL_COUNT failed checks)"
    fi
    if [[ $MANUAL_COUNT -gt 0 ]]; then
        echo "Some checks need you to look at the screen; see the MANUAL CHECK lines above."
    fi
    if test_site_is_blocked; then
        echo
        echo "$TEST_DOMAIN stays blocked. To unblock it later (needs your SiteBlock password and a wait):"
        echo "    siteblock unblock $TEST_DOMAIN"
        echo
        echo "To test that hand edits are undone, run this. It prints how many lines mention $TEST_DOMAIN after the repair; a number above 0 means SiteBlock put them back, and 0 means the repair did not happen:"
        echo "    sudo sed -i '' '/$TEST_DOMAIN/d' /etc/hosts; sleep 3; grep -c $TEST_DOMAIN /etc/hosts"
    elif [[ $STATUS_CODE -eq 0 ]]; then
        echo
        echo "The blocking checks were skipped because $TEST_DOMAIN is not blocked yet."
        echo "Block $TEST_DOMAIN from the menu bar icon, then run scripts/verify-install.sh again."
    fi
}

# Runs every check in order, then prints the summary. The exit code is 1 when any check failed.
main() {
    if [[ $EUID -eq 0 ]]; then
        echo "note: run this script as your normal user, without sudo, so the browser checks can reach your apps."
    fi
    check_jobs_loaded
    check_status
    check_hosts_lines
    check_lookup
    check_connection
    check_hosts_healthy
    check_browsers
    print_summary
    if [[ $FAIL_COUNT -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Run main only when the script is executed, not when another script sources it (the tests do).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi

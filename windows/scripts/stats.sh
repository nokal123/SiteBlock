#!/bin/bash
# Prints how often SiteBlock has been downloaded, from GitHub's public release data (no login needed):
#   - SiteBlock.zip downloads (SiteBlock-Windows.zip for Windows): installs and updates, per version and in total.
#   - version.json downloads (version-windows.json for Windows): update checks. Each installed copy checks about once
#     a day, so checks per day is a rough count of copies in use.
# Mac and Windows releases are listed together and totalled apart. Windows rows start with "win"; "win latest" is the
# fixed windows-latest release, whose files every Windows build replaces.
# GitHub counts downloads, not people: one person downloading twice counts twice, and GitHub never says who.
#
# It lives with the Windows code, so changing it never starts a Mac package build (scripts/stats.sh is the Mac-only report).
#
#   windows/scripts/stats.sh
set -euo pipefail

REPO="nokal123/SiteBlock"

# Reads every page of the repository's releases (100 per page) and prints one line per version, then the totals.
page=1
all="[]"
while :; do
    chunk="$(curl -fsS "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page")"
    count="$(printf '%s' "$chunk" | /usr/bin/python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    all="$(printf '%s\n%s' "$all" "$chunk" | /usr/bin/python3 -I -c 'import json,sys; a,b=sys.stdin.read().split("\n",1); print(json.dumps(json.loads(a)+json.loads(b)))')"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
done

# The table is printed by a short Python program (macOS ships /usr/bin/python3); the release data arrives on its standard input.
printf '%s' "$all" | /usr/bin/python3 -I -c "$(cat <<'PY'
import json, sys
releases = json.load(sys.stdin)
totals = {"Mac": [0, 0], "Windows": [0, 0]}
print("%-14s%-12s%10s%15s" % ("version", "published", "downloads", "update checks"))
for r in releases:
    assets = {a["name"]: a["download_count"] for a in r.get("assets", [])}
    tag = r.get("tag_name") or ""
    if tag.startswith("windows-"):
        system = "Windows"
        z, c = assets.get("SiteBlock-Windows.zip", 0), assets.get("version-windows.json", 0)
        name = "win latest" if tag == "windows-latest" else "win " + tag[len("windows-v"):]
    else:
        system = "Mac"
        z, c = assets.get("SiteBlock.zip", 0), assets.get("version.json", 0)
        name = (r.get("name") or tag).replace("SiteBlock ", "").replace(" (latest build)", "")
    totals[system][0] += z
    totals[system][1] += c
    print("%-14s%-12s%10d%15d" % (name, (r.get("published_at") or "")[:10], z, c))
for system in ("Mac", "Windows"):
    print("%-26s%10d%15d" % ("total (%s)" % system, totals[system][0], totals[system][1]))
PY
)"

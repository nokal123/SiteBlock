#!/bin/bash
# Builds SiteBlock and packs everything another Apple Silicon Mac needs into two files in dist/:
#   SiteBlock.zip   the package, always under this one name so the download link never changes
#   version.json    describes the package (version, build number, commit, file name and SHA-256 checksum),
#                   so the app can tell whether a newer build exists and check its download
# The other Mac needs no developer tools; it only runs the installer.
#
#   scripts/package.sh
#
# The zip holds a SiteBlock folder with:
#   build/                      the ready-built, ad-hoc signed programs
#   scripts/install.sh          the installer (run with sudo)
#   scripts/verify-install.sh   the post-install checks
#   Install SiteBlock.command   a double-click installer for the other Mac
#   INSTALL.txt                 instructions for the person installing it
set -euo pipefail

# Work from the repository root, wherever the script is started from.
cd "$(dirname "$0")/.."

# Write the build number (the commit count) first; build.sh runs the same script again and finds nothing to change.
scripts/write-build-number.sh

# Build fresh release programs, so the package never ships stale ones.
scripts/build.sh

# The version and the build number come from the daemon itself, so version.json and INSTALL.txt always match what is inside.
VERSION_LINE="$(build/siteblockd --version)"
# The daemon prints "siteblockd <version> (build <number>)", for example "siteblockd 1.2.0 (build 52)".
if [[ ! "$VERSION_LINE" =~ ^siteblockd\ ([0-9]+\.[0-9]+\.[0-9]+)\ \(build\ ([0-9]+)\)$ ]]; then
    echo "error: could not read the version from siteblockd --version; got: '$VERSION_LINE'" >&2
    exit 1
fi
VERSION="${BASH_REMATCH[1]}"
BUILD="${BASH_REMATCH[2]}"
DIST="dist"
STAGE="$DIST/SiteBlock"
ZIP="$DIST/SiteBlock.zip"
VERSION_JSON="$DIST/version.json"

# Start from an empty staging folder each time. Any older zip (including ones named after a version) is removed too.
rm -rf "$STAGE" "$DIST"/SiteBlock*.zip "$VERSION_JSON"
mkdir -p "$STAGE/scripts"

# ditto copies the app bundle with its code signature and permissions intact (a plain cp can break the signature).
ditto build "$STAGE/build"
cp scripts/install.sh scripts/verify-install.sh "$STAGE/scripts/"
chmod 755 "$STAGE/scripts/install.sh" "$STAGE/scripts/verify-install.sh"

# The double-click installer for the other Mac. It does not build anything. It first removes the
# "downloaded from another computer" mark (com.apple.quarantine) from its own folder, because macOS
# refuses to run marked programs that lack an Apple developer signature, then runs the installer
# with sudo (which asks for that Mac's password) and the checks, and keeps the window open.
cat > "$STAGE/Install SiteBlock.command" <<'COMMAND'
#!/bin/bash
# Double-click (or right-click > Open) to install SiteBlock on this Mac.
cd "$(dirname "$0")" || exit 1

# Waits for Return before the window can close, so the output stays readable.
pause_at_end() {
    echo
    read -r -p "Press Return to close this window. " _
}
trap pause_at_end EXIT

echo "=== Step 1 of 3: clearing the download mark from the SiteBlock folder ==="
xattr -dr com.apple.quarantine . 2>/dev/null || true

echo
echo "=== Step 2 of 3: installing SiteBlock (this Mac's administrator password is needed) ==="
if ! sudo scripts/install.sh; then
    echo
    echo "The install failed. Read the messages above. It is safe to run this file again."
    exit 1
fi

echo
echo "=== Step 3 of 3: checking the installation ==="
scripts/verify-install.sh
status=$?

echo
if [[ $status -eq 0 ]]; then
    echo "SiteBlock is installed and running. Click the shield icon in the menu bar to block your first site;"
    echo "it will ask you to choose your SiteBlock password then."
else
    echo "SiteBlock is installed, but at least one check failed. Read the FAIL lines above."
fi
exit $status
COMMAND
chmod 755 "$STAGE/Install SiteBlock.command"

# Instructions for the person installing it, in plain language.
cat > "$STAGE/INSTALL.txt" <<EOF
SiteBlock $VERSION — installing on this Mac

SiteBlock blocks websites in every browser (Safari, Chrome and others) for everyone using this Mac.
It also always blocks adult websites: it sets this Mac's DNS servers to the CleanBrowsing Family Filter
(which also blocks VPN and proxy sites and mixed-content sites such as Reddit, and forces SafeSearch and
YouTube's restricted mode) and turns on Chrome's adult-site filter and SafeSearch. Only uninstalling
SiteBlock removes this.
Unblocking a site needs the SiteBlock password and then a waiting period, and uninstalling needs the
password and then a 48-hour wait. Only install it if the person who uses this Mac wants it.

Requirements: a Mac with an Apple chip (M1 or newer), macOS 14 (Sonoma) or newer, and this Mac's
administrator password.

Install:
1. Unzip SiteBlock.zip. Keep the SiteBlock folder together; the installer needs everything in it.
2. Open the SiteBlock folder, right-click "Install SiteBlock.command" and choose Open.
   macOS warns that it is from an unidentified developer, because SiteBlock is not signed with an
   Apple developer certificate. Click Open. (If there is no Open button, go to System Settings >
   Privacy & Security, scroll down, click "Open Anyway" next to the SiteBlock message, then try again.)
3. Terminal opens and asks for this Mac's administrator password. Typing shows nothing; that is normal.
   If macOS asks whether Terminal may access the folder the zip is in (for example Downloads), click Allow.
4. When it says "SiteBlock is installed and running", click the shield icon in the menu bar, type a
   site (for example youtube.com) and press Block. The first time, it asks you to choose your
   SiteBlock password. Keep that password safe: it cannot be shown again.

If double-clicking does not work, open Terminal and run these two lines (adjust the path if the
folder is somewhere else):
    xattr -dr com.apple.quarantine ~/Downloads/SiteBlock
    cd ~/Downloads/SiteBlock && sudo scripts/install.sh

Chrome: while any site is blocked, Chrome's menu shows "Managed by your organization". That only
refers to SiteBlock's block list.

Forgotten password: run "sudo siteblock recover" in Terminal; the password is cleared after 48 hours.
Removing SiteBlock: Settings in the menu bar panel > Uninstall, or "siteblock uninstall".
EOF

# Check the copies before zipping: every program still passes its signature check and runs on Apple chips.
for program in "$STAGE/build/siteblockd" "$STAGE/build/siteblock" "$STAGE/build/SiteBlock.app"; do
    codesign --verify --strict "$program"
done
for binary in "$STAGE/build/siteblockd" "$STAGE/build/siteblock" "$STAGE/build/SiteBlock.app/Contents/MacOS/SiteBlock"; do
    lipo -archs "$binary" | grep -qw arm64 || { echo "$binary is not built for Apple chips (arm64)" >&2; exit 1; }
done

# ditto -c -k makes a standard zip that keeps the app bundle's signature and the scripts' permissions.
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
rm -rf "$STAGE"

# Describe the package. The commit is the full 40-character hash of the checked-out commit. Without git (the build
# number is then 0) it is all zeros, and the app ignores a version.json whose build is 0, so a package made without git
# is never offered as an update. The checksum is written in lowercase hexadecimal, as the app expects.
COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    COMMIT="0000000000000000000000000000000000000000"
fi
SHA256="$(shasum -a 256 "$ZIP" | awk '{print tolower($1)}')"
# "version" stays the technical id 1.0.<build>, because copies of SiteBlock older than 1.2.0 accept an update only when it
# reads exactly so; "displayVersion" is the number people see (for example 1.2.0), which newer copies show in the banner.
printf '{\n  "version": "1.0.%s",\n  "build": %s,\n  "displayVersion": "%s",\n  "commit": "%s",\n  "asset": "SiteBlock.zip",\n  "sha256": "%s"\n}\n' "$BUILD" "$BUILD" "$VERSION" "$COMMIT" "$SHA256" > "$VERSION_JSON"

echo
echo "Package ready: $(pwd)/$ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
echo "Version file: $(pwd)/$VERSION_JSON (version $VERSION, build $BUILD, sha256 $SHA256)"
echo "Send the zip to the other Mac and follow INSTALL.txt inside it."

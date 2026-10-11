#!/bin/bash
# Builds SiteBlock and packs everything another Apple Silicon Mac needs into one zip file:
# dist/SiteBlock-<version>.zip. The other Mac needs no developer tools; it only runs the installer.
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

# Build fresh release programs, so the package never ships stale ones.
scripts/build.sh

# The version comes from the daemon itself, so the zip name always matches what is inside.
VERSION="$(build/siteblockd --version | awk '{print $NF}')"
DIST="dist"
STAGE="$DIST/SiteBlock"
ZIP="$DIST/SiteBlock-$VERSION.zip"

# Start from an empty staging folder each time.
rm -rf "$STAGE" "$ZIP"
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
Unblocking a site needs the SiteBlock password and then a waiting period, and uninstalling needs the
password and then a 48-hour wait. Only install it if the person who uses this Mac wants it.

Requirements: a Mac with an Apple chip (M1 or newer), macOS 14 (Sonoma) or newer, and this Mac's
administrator password.

Install:
1. Unzip SiteBlock-$VERSION.zip. Keep the SiteBlock folder together; the installer needs everything in it.
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

echo
echo "Package ready: $(pwd)/$ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
echo "Send it to the other Mac and follow INSTALL.txt inside it."

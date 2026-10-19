#!/bin/bash
# Builds the three SiteBlock programs in release mode and assembles the results in build/:
# build/siteblockd, build/siteblock and build/SiteBlock.app. Runs as the normal user (no sudo).
set -euo pipefail

# Work from the repository root, wherever the script is started from.
cd "$(dirname "$0")/.."

# A separate scratch folder, so this build never collides with the build folders other tools use (.build, .build-daemon, ...).
SCRATCH=".build-release"
OUT="build"

# Refuse early with a clear message when the Swift toolchain is missing.
if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' was not found. Install the Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
fi

# Write the generated build number file (the commit count) before compiling, so every program shows the same version.
scripts/write-build-number.sh

# Compile each program. Building one product at a time keeps the error output readable.
for product in siteblockd siteblock SiteBlockApp; do
    echo "==> Building $product (release)"
    swift build -c release --scratch-path "$SCRATCH" --product "$product"
done

# Find the folder SwiftPM put the release programs in.
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"
for product in siteblockd siteblock SiteBlockApp; do
    if [[ ! -x "$BIN_DIR/$product" ]]; then
        echo "error: expected program not found: $BIN_DIR/$product" >&2
        exit 1
    fi
done

# The version comes from the built daemon, so the code has the only copy of the version number. It is 1.0.<build>,
# where <build> is the commit count, and the app's Info.plist gets the same two values.
VERSION="$("$BIN_DIR/siteblockd" --version | awk '{print $2}')"
if [[ ! "$VERSION" =~ ^1\.0\.[0-9]+$ ]]; then
    echo "error: could not read the version (1.0.<build>) from siteblockd --version; got: '$VERSION'" >&2
    exit 1
fi
BUILD="${VERSION##*.}"

# Start from a clean output folder, so nothing stale from an earlier build is left behind.
rm -rf "$OUT"
mkdir -p "$OUT/SiteBlock.app/Contents/MacOS"

# Assemble the app bundle: the program, and the Info.plist template with the version (1.0.<build>) and the build number filled in.
# The template already holds the bundle identifier (com.nokal.siteblock.app), the name and executable name (SiteBlock),
# LSUIElement true (no Dock icon) and LSMinimumSystemVersion 14.0.
cp "$BIN_DIR/SiteBlockApp" "$OUT/SiteBlock.app/Contents/MacOS/SiteBlock"
cp "Resources/Info.plist" "$OUT/SiteBlock.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$OUT/SiteBlock.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$OUT/SiteBlock.app/Contents/Info.plist"
plutil -lint "$OUT/SiteBlock.app/Contents/Info.plist" >/dev/null

# Copy the command-line programs next to the app.
cp "$BIN_DIR/siteblockd" "$OUT/siteblockd"
cp "$BIN_DIR/siteblock" "$OUT/siteblock"

# Sign everything with an ad-hoc signature (the "-" identity). Apple Silicon Macs refuse to run unsigned programs,
# and an ad-hoc signature needs no Apple developer account. The app bundle is signed last, after its contents are final.
codesign --force --sign - "$OUT/siteblockd"
codesign --force --sign - "$OUT/siteblock"
codesign --force --sign - "$OUT/SiteBlock.app"

# Check the signatures now, so a problem shows up here and not at install time.
codesign --verify --strict "$OUT/siteblockd"
codesign --verify --strict "$OUT/siteblock"
codesign --verify --strict "$OUT/SiteBlock.app"

echo
echo "Built SiteBlock $VERSION:"
echo "  $PWD/$OUT/SiteBlock.app"
echo "  $PWD/$OUT/siteblockd"
echo "  $PWD/$OUT/siteblock"
echo "Next: sudo scripts/install.sh"

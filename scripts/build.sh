#!/bin/bash
# Builds the three SiteBlock programs in release mode and assembles the results in build/:
# build/siteblockd, build/siteblock and build/SiteBlock.app. Each program is universal: it holds a copy for Apple chips
# (arm64) and one for Intel processors (x86_64), and macOS runs the one that matches the Mac. Runs as the normal user (no sudo).
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

# The two processor families every program is built for, and the oldest macOS they run on (the same as Package.swift's platform).
ARCHS=(arm64 x86_64)
MIN_MACOS="14.0"

# Compile each program once per processor family. Building one product at a time keeps the error output readable.
# SwiftPM keeps each family's build in its own folder under the scratch folder, named after the target (for example x86_64-apple-macosx).
for arch in "${ARCHS[@]}"; do
    for product in siteblockd siteblock SiteBlockApp; do
        echo "==> Building $product for $arch (release)"
        swift build -c release --scratch-path "$SCRATCH" --product "$product" --triple "$arch-apple-macosx$MIN_MACOS"
    done
done

# Join each program's two copies into one universal file in a staging folder. A copy that is missing, or that is not
# built for the family it was asked for, stops the build, so a package can never ship without one of the two.
BIN_DIR="$SCRATCH/universal"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"
for product in siteblockd siteblock SiteBlockApp; do
    parts=()
    for arch in "${ARCHS[@]}"; do
        part="$(swift build -c release --scratch-path "$SCRATCH" --triple "$arch-apple-macosx$MIN_MACOS" --show-bin-path)/$product"
        if [[ ! -x "$part" ]]; then
            echo "error: expected program not found: $part" >&2
            exit 1
        fi
        if [[ "$(lipo -archs "$part")" != "$arch" ]]; then
            echo "error: $part should hold only $arch code but holds: $(lipo -archs "$part")" >&2
            exit 1
        fi
        parts+=("$part")
    done
    lipo -create "${parts[@]}" -output "$BIN_DIR/$product"
done

# The version (set by hand in Models.swift, for example 1.2.0) and the build number (the release number in Models.swift) come from the
# built daemon, so the code has the only copy of both, and the app's Info.plist gets the same two values.
VERSION_LINE="$("$BIN_DIR/siteblockd" --version)"
# The daemon prints "siteblockd <version> (build <number>)", for example "siteblockd 1.2.0 (build 52)".
if [[ ! "$VERSION_LINE" =~ ^siteblockd\ ([0-9]+\.[0-9]+\.[0-9]+)\ \(build\ ([0-9]+)\)$ ]]; then
    echo "error: could not read the version from siteblockd --version; got: '$VERSION_LINE'" >&2
    exit 1
fi
VERSION="${BASH_REMATCH[1]}"
BUILD="${BASH_REMATCH[2]}"

# Start from a clean output folder, so nothing stale from an earlier build is left behind.
rm -rf "$OUT"
mkdir -p "$OUT/SiteBlock.app/Contents/MacOS"

# Assemble the app bundle: the program, and the Info.plist template with the version (for example 1.2.0) and the build number filled in.
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

# Sign everything with an ad-hoc signature (the "-" identity). Macs with Apple chips refuse to run unsigned programs,
# and an ad-hoc signature needs no Apple developer account. codesign signs both copies inside each universal file. The app bundle is signed last, after its contents are final.
codesign --force --sign - "$OUT/siteblockd"
codesign --force --sign - "$OUT/siteblock"
codesign --force --sign - "$OUT/SiteBlock.app"

# Check the signatures now, so a problem shows up here and not at install time.
codesign --verify --strict "$OUT/siteblockd"
codesign --verify --strict "$OUT/siteblock"
codesign --verify --strict "$OUT/SiteBlock.app"

# Check that every finished program still holds both copies, so an Intel Mac and a Mac with an Apple chip can both run it.
for program in "$OUT/siteblockd" "$OUT/siteblock" "$OUT/SiteBlock.app/Contents/MacOS/SiteBlock"; do
    for arch in "${ARCHS[@]}"; do
        if ! lipo "$program" -verify_arch "$arch"; then
            echo "error: $program has no $arch copy" >&2
            exit 1
        fi
    done
done

echo
echo "Built SiteBlock $VERSION:"
echo "  $PWD/$OUT/SiteBlock.app"
echo "  $PWD/$OUT/siteblockd"
echo "  $PWD/$OUT/siteblock"
echo "Next: sudo scripts/install.sh"

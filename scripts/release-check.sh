#!/bin/bash
# Decides whether a freshly built package is a new release, by comparing the build number in its version.json with the one
# already published. Prints "release" when the new build is higher, so the workflow publishes it, and "skip" when it is the same,
# because the release number in Sources/SiteBlockCore/Models.swift was not raised and this push is not meant as a release.
# A lower new build, or a file without a whole-number build, is an error (exit 1): installed copies would never take a lower
# build, so publishing it would strand them.
#
#   scripts/release-check.sh <new version.json> <published version.json>
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/release-check.sh <new version.json> <published version.json>" >&2
    exit 1
fi

# Prints the "build" field of a version file, or stops with an error naming the file when it is missing or not a whole number.
build_of() {
    local build=""
    # Only a JSON whole number counts: plutil would also print the text "95" or the decimal 95.0 as digits, so the type is checked first.
    if [[ "$(/usr/bin/plutil -type build "$1" 2>/dev/null || true)" == "integer" ]]; then
        build="$(/usr/bin/plutil -extract build raw -o - "$1" 2>/dev/null || true)"
    fi
    if [[ ! "$build" =~ ^[0-9]+$ ]]; then
        echo "error: $1 has no whole-number build field" >&2
        exit 1
    fi
    echo "$build"
}

NEW="$(build_of "$1")"
PUBLISHED="$(build_of "$2")"
# Compared as base-10 numbers (10#), so 100 is above 99.
if (( 10#$NEW > 10#$PUBLISHED )); then
    echo "release"
elif (( 10#$NEW == 10#$PUBLISHED )); then
    echo "skip"
else
    echo "error: the new build $NEW is lower than the published build $PUBLISHED; installed copies would never take it" >&2
    exit 1
fi

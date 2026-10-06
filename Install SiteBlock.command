#!/bin/bash
# Double-click this file in Finder to build, install and check SiteBlock. Finder opens it in Terminal.
#   1. builds the programs as your normal user,
#   2. installs them with sudo (Terminal asks for your Mac password),
#   3. runs the verification script,
# and then leaves the window open so you can read the results.

# Work from the folder this file is in (the repository root), whatever Finder's starting folder is.
cd "$(dirname "$0")" || exit 1

# Waits for Return before the window can close, so the output stays readable.
pause_at_end() {
    echo
    read -r -p "Press Return to close this window. " _
}
trap pause_at_end EXIT

echo "=== Step 1 of 3: building SiteBlock ==="
if ! scripts/build.sh; then
    echo
    echo "The build failed, so nothing was installed. Read the messages above."
    exit 1
fi

echo
echo "=== Step 2 of 3: installing SiteBlock (your Mac password is needed) ==="
if ! sudo scripts/install.sh; then
    echo
    echo "The install failed. Read the messages above. It is safe to run this file again."
    exit 1
fi

echo
echo "=== Step 3 of 3: checking that blocking works ==="
scripts/verify-install.sh
verify_status=$?

echo
if [[ $verify_status -eq 0 ]]; then
    echo "SiteBlock is installed and the checks passed. You can open the shield icon in the menu bar."
else
    echo "SiteBlock is installed, but at least one check failed. Read the FAIL lines above."
fi
exit $verify_status

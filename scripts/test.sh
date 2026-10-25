#!/bin/bash
# Runs the Swift Testing suites. On a Mac with only the Command Line Tools (no Xcode), the Testing
# framework is not on the default search path, so this script passes its location explicitly.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]]; then
    F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    # The Command Line Tools ship _Testing_Foundation.framework without its Modules folder, so a test
    # file that imports both Foundation and Testing fails with "no such module '_Testing_Foundation'".
    # Turning off cross-import overlays avoids the broken framework; tests still use Foundation normally.
    exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays "$@"
else
    exec swift test "$@"
fi

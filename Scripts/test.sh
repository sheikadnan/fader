#!/bin/sh
# Runs the test suite.
#
# With Xcode installed this is just `swift test`. With only the Command Line
# Tools, XCTest is absent and swift-testing is not on the default search path,
# so the framework and its macro plugin have to be pointed at explicitly.
set -e
cd "$(dirname "$0")/.."

DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
FLAGS=""

if [ -d "$DEVELOPER_DIR/Library/Developer/Frameworks/Testing.framework" ] \
   && [ ! -d "/Applications/Xcode.app/Contents/Developer/Platforms" ]; then
    FW="$DEVELOPER_DIR/Library/Developer/Frameworks"
    PLUGIN="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [ -f "$PLUGIN" ]; then
        FLAGS="-Xswiftc -F -Xswiftc $FW -Xswiftc -load-plugin-library -Xswiftc $PLUGIN -Xlinker -F -Xlinker $FW -Xlinker -rpath -Xlinker $FW"
    fi
fi

# shellcheck disable=SC2086
exec swift test $FLAGS "$@"

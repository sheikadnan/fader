#!/bin/sh
# Builds Fader.app — a menu bar app bundle. Swift Package Manager produces a
# bare executable; the bundle, Info.plist and ad-hoc signature are what make it
# launchable and what let it hold a privacy permission.
#
#   ./Scripts/build-app.sh            release build, ad-hoc signed
#   CODESIGN_ID="Developer ID…" ./Scripts/build-app.sh   signed for distribution
set -e
cd "$(dirname "$0")/.."

CONFIGURATION=${CONFIGURATION:-release}
APP="Fader.app"
CONTENTS="$APP/Contents"

swift build -c "$CONFIGURATION" --product Fader
BINARY=$(swift build -c "$CONFIGURATION" --show-bin-path)/Fader

if [ ! -x "$BINARY" ]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

rm -rf "$CONTENTS"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/Fader"
cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ -n "$CODESIGN_ID" ]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" "$APP"
else
    # Ad-hoc signing is enough to run locally and is required before macOS will
    # remember a privacy decision for the app.
    codesign --force --sign - "$APP"
fi

echo "built $(pwd)/$APP"

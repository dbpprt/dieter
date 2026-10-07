#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$1
BUNDLE="$STAGE/DieterDaemon.app"
test ! -e "$BUNDLE"
for executable in dieter dieter-capture; do
    test -f "$STAGE/$executable" && test ! -L "$STAGE/$executable" && test -x "$STAGE/$executable"
done
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Library/LaunchDaemons"
cp "$SCRIPT_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/com.dbpprt.dieter.privacy.plist" "$BUNDLE/Contents/Library/LaunchDaemons/"
if [ -n "${DIETER_RELEASE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DIETER_RELEASE_VERSION" "$BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DieterReleaseVersion string $DIETER_RELEASE_VERSION" "$BUNDLE/Contents/Info.plist"
fi
mv "$STAGE/dieter" "$STAGE/dieter-capture" "$BUNDLE/Contents/MacOS/"
# Release signing signs the nested capture executable before the enclosing app.
codesign --force --identifier com.dbpprt.dieter.capture --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

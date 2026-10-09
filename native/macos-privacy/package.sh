#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$1
BUNDLE="$STAGE/DieterPrivacyHelper.app"
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
"$SCRIPT_DIR/build.sh" "$BUNDLE/Contents/MacOS/dieter-privacy"
if [ "${DIETER_PRIVACY_RELEASE:-0}" != "1" ]; then
    # Bind development IPC to this exact standalone capture build. The plist is
    # sealed by the enclosing signature, and releases never read this override.
    CAPTURE_HASH=$(codesign -dv --verbose=4 "$STAGE/dieter-capture" 2>&1 | sed -n 's/^CDHash=//p')
    test "${#CAPTURE_HASH}" -eq 40
    /usr/libexec/PlistBuddy -c "Add :DieterDevelopmentCaptureHash string $CAPTURE_HASH" "$BUNDLE/Contents/Info.plist"
fi
codesign --force --identifier com.dbpprt.dieter.privacy --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

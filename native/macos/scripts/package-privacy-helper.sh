#!/bin/sh
# Assembles DieterPrivacyHelper.app beside an existing `dieter` and
# `dieter-capture` in STAGE:
#
#   native/macos/scripts/package-privacy-helper.sh STAGE
#
# Development packages (the default) build dieter-privacy in the debug
# configuration, which trusts only the exact capture build in STAGE.
# DIETER_PRIVACY_RELEASE=1 builds the release configuration, which requires
# Developer ID signatures of the configured team. Identifiers come from
# config/identity.json. DIETER_RELEASE_VERSION stamps the bundle version.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PACKAGE_DIR/../.." && pwd)
STAGE=$1
BUNDLE="$STAGE/DieterPrivacyHelper.app"
test ! -e "$BUNDLE"
for executable in dieter dieter-capture; do
    test -f "$STAGE/$executable" && test ! -L "$STAGE/$executable" && test -x "$STAGE/$executable"
done

PREFIX=$(plutil -extract bundle_prefix raw -o - "$REPO_ROOT/config/identity.json")
PRIVACY_ID="$PREFIX.privacy"
CONFIGURATION=debug
if [ "${DIETER_PRIVACY_RELEASE:-0}" = "1" ]; then
    CONFIGURATION=release
fi
swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --product dieter-privacy
PRODUCTS=$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --show-bin-path)

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Library/LaunchDaemons"
cp "$PACKAGE_DIR/Packaging/Info.plist" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PRIVACY_ID" "$BUNDLE/Contents/Info.plist"
DAEMON_PLIST="$BUNDLE/Contents/Library/LaunchDaemons/$PRIVACY_ID.plist"
cp "$PACKAGE_DIR/Packaging/LaunchDaemon.plist" "$DAEMON_PLIST"
/usr/libexec/PlistBuddy -c "Set :Label $PRIVACY_ID" "$DAEMON_PLIST"
/usr/libexec/PlistBuddy -c "Set :Sockets:Control:SockPathName /var/run/$PRIVACY_ID.sock" "$DAEMON_PLIST"
if [ -n "${DIETER_RELEASE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DIETER_RELEASE_VERSION" "$BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DieterReleaseVersion string $DIETER_RELEASE_VERSION" "$BUNDLE/Contents/Info.plist"
fi
cp "$PRODUCTS/dieter-privacy" "$BUNDLE/Contents/MacOS/dieter-privacy"
codesign --force --identifier "$PRIVACY_ID" --sign - "$BUNDLE/Contents/MacOS/dieter-privacy"
if [ "$CONFIGURATION" = debug ]; then
    # Bind development IPC to this exact standalone capture build. The plist is
    # sealed by the enclosing signature, and releases never read this override.
    CAPTURE_HASH=$(codesign -dv --verbose=4 "$STAGE/dieter-capture" 2>&1 | sed -n 's/^CDHash=//p')
    test "${#CAPTURE_HASH}" -eq 40
    /usr/libexec/PlistBuddy -c "Add :DieterDevelopmentCaptureHash string $CAPTURE_HASH" "$BUNDLE/Contents/Info.plist"
fi
codesign --force --identifier "$PRIVACY_ID" --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

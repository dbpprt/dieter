#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/../.."
if pgrep -x DieterMac >/dev/null; then
  echo 'A Dieter app is running. Native viewer integration is unavailable until it exits.' >&2
  exit 1
fi
SCREEN_TEST_ROOT=$(mktemp -d /tmp/dieter-native-viewer-tests.XXXXXX)
trap 'rm -rf "$SCREEN_TEST_ROOT"' EXIT
"$SCRIPT_DIR/build.sh" "$SCREEN_TEST_ROOT/dieter-capture"
go build -o "$SCREEN_TEST_ROOT/screens-fixture" ./scripts/screens-fixture
mkdir -p "$SCREEN_TEST_ROOT/InputTarget.app/Contents/MacOS"
cat > "$SCREEN_TEST_ROOT/InputTarget.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InputTarget</string>
<key>CFBundleIdentifier</key><string>com.dbpprt.dieter.screen-input-fixture</string>
<key>CFBundleName</key><string>Dieter Input Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -O -framework AppKit "$SCRIPT_DIR/tests/InputTarget.swift" -o "$SCREEN_TEST_ROOT/InputTarget.app/Contents/MacOS/InputTarget"
codesign --force --sign - "$SCREEN_TEST_ROOT/InputTarget.app"
DIETER_TEST_CAPTURE_HELPER="$SCREEN_TEST_ROOT/dieter-capture" \
DIETER_TEST_SCREEN_FIXTURE="$SCREEN_TEST_ROOT/screens-fixture" \
DIETER_TEST_INPUT_TARGET="$SCREEN_TEST_ROOT/InputTarget.app" \
just mac test remoteDesktop

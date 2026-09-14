#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_OUTPUT=$(mktemp -d /tmp/dieter-native-screen-tests.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
"$SCRIPT_DIR/build.sh" "$TEST_OUTPUT/dieter-capture"
xcrun swiftc -parse-as-library -O -D DIETER_CAPTURE_TEST \
  -framework AppKit -framework ScreenCaptureKit -framework VideoToolbox \
  "$SCRIPT_DIR"/*.swift "$SCRIPT_DIR/../../apps/mac/Sources/DieterCore/RemoteDesktopKeyMap.swift" \
  "$SCRIPT_DIR/tests/InputState.swift" -o "$TEST_OUTPUT/input-state"
"$TEST_OUTPUT/input-state"
cd "$SCRIPT_DIR/../.."
DIETER_TEST_CAPTURE_HELPER="$TEST_OUTPUT/dieter-capture" go test -race ./internal/remotedesktop

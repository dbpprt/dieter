#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_OUTPUT=$(mktemp -d /tmp/dieter-native-screen-tests.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
"$SCRIPT_DIR/build.sh" "$TEST_OUTPUT/dieter-capture"
xcrun clang -fobjc-arc -target arm64-apple-macos15.0 -c "$SCRIPT_DIR/VirtualDisplayBridge.m" -o "$TEST_OUTPUT/virtual-display-bridge.o"
xcrun swiftc -import-objc-header "$SCRIPT_DIR/VirtualDisplayBridge.h" "$TEST_OUTPUT/virtual-display-bridge.o" -parse-as-library -O -D DIETER_CAPTURE_TEST \
    -framework AppKit -framework ScreenCaptureKit -framework VideoToolbox \
    "$SCRIPT_DIR"/*.swift "$SCRIPT_DIR/../../apps/mac/Sources/DieterTransport/RemoteDesktopKeyMap.swift" \
    "$SCRIPT_DIR/../../apps/mac/Sources/DieterTransport/ScreenClipboardContent.swift" \
    "$SCRIPT_DIR/tests/InputState.swift" -o "$TEST_OUTPUT/input-state"
"$TEST_OUTPUT/input-state"
cd "$SCRIPT_DIR/../.."
DIETER_TEST_CAPTURE_HELPER="$TEST_OUTPUT/dieter-capture" go test -race ./internal/remotedesktop

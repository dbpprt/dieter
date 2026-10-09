#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/build/dieter-capture"}
mkdir -p "$(dirname -- "$OUTPUT")"
BRIDGE_DIR=$(mktemp -d /tmp/dieter-display-bridge.XXXXXX)
trap 'rm -rf "$BRIDGE_DIR"' EXIT
xcrun clang -fobjc-arc -target arm64-apple-macos15.0 -c "$SCRIPT_DIR/VirtualDisplayBridge.m" -o "$BRIDGE_DIR/bridge.o"
xcrun swiftc \
    -import-objc-header "$SCRIPT_DIR/VirtualDisplayBridge.h" \
    "$BRIDGE_DIR/bridge.o" \
    -parse-as-library \
    -O \
    -target arm64-apple-macos15.0 \
    -framework AppKit \
    -framework CoreGraphics \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Foundation \
    -framework IOKit \
    -framework Security \
    -framework ServiceManagement \
    -framework SystemConfiguration \
    -framework ScreenCaptureKit \
    -framework VideoToolbox \
    "$SCRIPT_DIR"/*.swift \
    "$SCRIPT_DIR/../../apps/mac/Sources/DieterTransport/RemoteDesktopKeyMap.swift" \
    "$SCRIPT_DIR/../../apps/mac/Sources/DieterTransport/ScreenClipboardContent.swift" \
    -o "$OUTPUT"
codesign --force --sign - "$OUTPUT"
echo "$OUTPUT"

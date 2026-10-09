#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=$1
mkdir -p "$(dirname -- "$OUTPUT")"
PRIVACY_DEVELOPMENT_FLAG=""
if [ "${DIETER_PRIVACY_RELEASE:-0}" != "1" ]; then
    PRIVACY_DEVELOPMENT_FLAG="-DDIETER_PRIVACY_DEVELOPMENT"
fi
xcrun swiftc $PRIVACY_DEVELOPMENT_FLAG -parse-as-library -O \
    -target arm64-apple-macos15.0 \
    -framework Foundation -framework IOKit -framework Security \
    -framework ServiceManagement -framework SystemConfiguration \
    "$SCRIPT_DIR/PrivacyHIDProtection.swift" \
    "$SCRIPT_DIR/PrivacyHIDService.swift" \
    "$SCRIPT_DIR/DieterPrivacy.swift" \
    "$SCRIPT_DIR/../macos-capture/PrivacyHIDProtocol.swift" \
    -o "$OUTPUT"
codesign --force --identifier com.dbpprt.dieter.privacy --sign - "$OUTPUT"

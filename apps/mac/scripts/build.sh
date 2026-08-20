#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
BRAND_ROOT="$REPO_ROOT/assets/brand"
CONFIGURATION=${CONFIGURATION:-debug}
OUTPUT_ROOT="$APP_ROOT/build"
APP_BUNDLE="$OUTPUT_ROOT/Nauclio.app"

"$SCRIPT_DIR/sync-proto.sh" >&2
swift build --package-path "$APP_ROOT" -c "$CONFIGURATION" >&2
NAUCLIO_BINARY=$(find "$APP_ROOT/.build" -type f -path "*/$CONFIGURATION/NauclioMac" -perm -111 -print -quit)
if [ -z "$NAUCLIO_BINARY" ]; then
    echo "NauclioMac binary was not produced" >&2
    exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BRAND_ROOT/assets/Nauclio.icns" "$APP_BUNDLE/Contents/Resources/Nauclio.icns"
cp "$BRAND_ROOT/assets/png/app-icon-dark-1024.png" "$APP_BUNDLE/Contents/Resources/NauclioAppIcon.png"
cp "$BRAND_ROOT/assets/png/favicon-32.png" "$APP_BUNDLE/Contents/Resources/NauclioFavicon.png"
cp "$NAUCLIO_BINARY" "$APP_BUNDLE/Contents/MacOS/NauclioMac"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "$APP_BUNDLE"

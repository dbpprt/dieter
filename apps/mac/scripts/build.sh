#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
BRAND_ROOT="$REPO_ROOT/assets/brand"
CONFIGURATION=${CONFIGURATION:-debug}
SWIFT_SCRATCH_PATH=${NAUCLIO_SWIFT_SCRATCH_PATH:-$APP_ROOT/.build/nauclio-local}
OUTPUT_ROOT="$APP_ROOT/build"
APP_BUNDLE="$OUTPUT_ROOT/Nauclio.app"
BUNDLE_MANIFEST="$OUTPUT_ROOT/.Nauclio.bundle-inputs"
BUNDLE_OUTPUT_MANIFEST="$OUTPUT_ROOT/.Nauclio.bundle-outputs"

"$SCRIPT_DIR/sync-proto.sh" >&2
"$SCRIPT_DIR/swiftpm.sh" build -c "$CONFIGURATION" >&2
NAUCLIO_BINARY="$SWIFT_SCRATCH_PATH/$CONFIGURATION/NauclioMac"
if [ ! -x "$NAUCLIO_BINARY" ]; then
    echo "NauclioMac binary was not produced" >&2
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"
NEW_BUNDLE_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/nauclio-mac-bundle.XXXXXX")
NEW_BUNDLE_OUTPUT_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/nauclio-mac-bundle-output.XXXXXX")
trap 'rm -f "$NEW_BUNDLE_MANIFEST" "$NEW_BUNDLE_OUTPUT_MANIFEST"' EXIT INT TERM
stat -f '%N %Fm %z %i' \
    "$APP_ROOT/Resources/Info.plist" \
    "$BRAND_ROOT/assets/Nauclio.icns" \
    "$BRAND_ROOT/assets/png/app-icon-dark-1024.png" \
    "$BRAND_ROOT/assets/png/favicon-32.png" \
    "$NAUCLIO_BINARY" >"$NEW_BUNDLE_MANIFEST"

BUNDLE_OUTPUTS_MATCH=0
if [ -f "$APP_BUNDLE/Contents/Info.plist" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/Nauclio.icns" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/NauclioAppIcon.png" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/NauclioFavicon.png" ] && \
    [ -x "$APP_BUNDLE/Contents/MacOS/NauclioMac" ]; then
    stat -f '%N %Fm %z %i' \
        "$APP_BUNDLE/Contents/Info.plist" \
        "$APP_BUNDLE/Contents/Resources/Nauclio.icns" \
        "$APP_BUNDLE/Contents/Resources/NauclioAppIcon.png" \
        "$APP_BUNDLE/Contents/Resources/NauclioFavicon.png" \
        "$APP_BUNDLE/Contents/MacOS/NauclioMac" >"$NEW_BUNDLE_OUTPUT_MANIFEST"
    if [ -f "$BUNDLE_OUTPUT_MANIFEST" ] && \
        cmp -s "$NEW_BUNDLE_OUTPUT_MANIFEST" "$BUNDLE_OUTPUT_MANIFEST"; then
        BUNDLE_OUTPUTS_MATCH=1
    fi
fi

if [ ! -f "$BUNDLE_MANIFEST" ] || \
    ! cmp -s "$NEW_BUNDLE_MANIFEST" "$BUNDLE_MANIFEST" || \
    [ "$BUNDLE_OUTPUTS_MATCH" -ne 1 ]; then
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    cp "$BRAND_ROOT/assets/Nauclio.icns" "$APP_BUNDLE/Contents/Resources/Nauclio.icns"
    cp "$BRAND_ROOT/assets/png/app-icon-dark-1024.png" "$APP_BUNDLE/Contents/Resources/NauclioAppIcon.png"
    cp "$BRAND_ROOT/assets/png/favicon-32.png" "$APP_BUNDLE/Contents/Resources/NauclioFavicon.png"
    cp "$NAUCLIO_BINARY" "$APP_BUNDLE/Contents/MacOS/NauclioMac"
    codesign --force --deep --sign - "$APP_BUNDLE" >&2
    stat -f '%N %Fm %z %i' \
        "$APP_BUNDLE/Contents/Info.plist" \
        "$APP_BUNDLE/Contents/Resources/Nauclio.icns" \
        "$APP_BUNDLE/Contents/Resources/NauclioAppIcon.png" \
        "$APP_BUNDLE/Contents/Resources/NauclioFavicon.png" \
        "$APP_BUNDLE/Contents/MacOS/NauclioMac" >"$NEW_BUNDLE_OUTPUT_MANIFEST"
    mv "$NEW_BUNDLE_MANIFEST" "$BUNDLE_MANIFEST"
    mv "$NEW_BUNDLE_OUTPUT_MANIFEST" "$BUNDLE_OUTPUT_MANIFEST"
    trap - EXIT INT TERM
fi

echo "$APP_BUNDLE"

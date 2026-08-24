#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
BRAND_ROOT="$REPO_ROOT/assets/brand"
PALETTE_ICON_ROOT="$APP_ROOT/Resources/PaletteIcons"
CONFIGURATION=${CONFIGURATION:-debug}
SWIFT_SCRATCH_PATH=${DIETER_SWIFT_SCRATCH_PATH:-$APP_ROOT/.build/dieter-local}
OUTPUT_ROOT="$APP_ROOT/build"
APP_BUNDLE="$OUTPUT_ROOT/Dieter.app"
BUNDLE_MANIFEST="$OUTPUT_ROOT/.Dieter.bundle-inputs"
BUNDLE_OUTPUT_MANIFEST="$OUTPUT_ROOT/.Dieter.bundle-outputs"

"$SCRIPT_DIR/sync-proto.sh" >&2
"$SCRIPT_DIR/swiftpm.sh" build -c "$CONFIGURATION" >&2
DIETER_BINARY="$SWIFT_SCRATCH_PATH/$CONFIGURATION/DieterMac"
if [ ! -x "$DIETER_BINARY" ]; then
    echo "DieterMac binary was not produced" >&2
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"
NEW_BUNDLE_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-mac-bundle.XXXXXX")
NEW_BUNDLE_OUTPUT_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-mac-bundle-output.XXXXXX")
trap 'rm -f "$NEW_BUNDLE_MANIFEST" "$NEW_BUNDLE_OUTPUT_MANIFEST"' EXIT INT TERM
stat -f '%N %Fm %z %i' \
    "$APP_ROOT/Resources/Info.plist" \
    "$BRAND_ROOT/assets/Dieter.icns" \
    "$BRAND_ROOT/assets/png/app-icon-dark-1024.png" \
    "$BRAND_ROOT/assets/png/favicon-32.png" \
    "$BRAND_ROOT/assets/fonts/Sora-Variable.ttf" \
    "$DIETER_BINARY" >"$NEW_BUNDLE_MANIFEST"
find "$PALETTE_ICON_ROOT" -type f | sort | xargs stat -f '%N %Fm %z %i' >>"$NEW_BUNDLE_MANIFEST"

BUNDLE_OUTPUTS_MATCH=0
if [ -f "$APP_BUNDLE/Contents/Info.plist" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/Dieter.icns" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/DieterFavicon.png" ] && \
    [ -d "$APP_BUNDLE/Contents/Resources/PaletteIcons" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf" ] && \
    [ -x "$APP_BUNDLE/Contents/MacOS/DieterMac" ]; then
    stat -f '%N %Fm %z %i' \
        "$APP_BUNDLE/Contents/Info.plist" \
        "$APP_BUNDLE/Contents/Resources/Dieter.icns" \
        "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png" \
        "$APP_BUNDLE/Contents/Resources/DieterFavicon.png" \
        "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf" \
        "$APP_BUNDLE/Contents/MacOS/DieterMac" >"$NEW_BUNDLE_OUTPUT_MANIFEST"
    find "$APP_BUNDLE/Contents/Resources/PaletteIcons" -type f | sort | xargs stat -f '%N %Fm %z %i' >>"$NEW_BUNDLE_OUTPUT_MANIFEST"
    if [ -f "$BUNDLE_OUTPUT_MANIFEST" ] && \
        cmp -s "$NEW_BUNDLE_OUTPUT_MANIFEST" "$BUNDLE_OUTPUT_MANIFEST"; then
        BUNDLE_OUTPUTS_MATCH=1
    fi
fi

if [ ! -f "$BUNDLE_MANIFEST" ] || \
    ! cmp -s "$NEW_BUNDLE_MANIFEST" "$BUNDLE_MANIFEST" || \
    [ "$BUNDLE_OUTPUTS_MATCH" -ne 1 ]; then
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Fonts" "$APP_BUNDLE/Contents/Resources/PaletteIcons"
    cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    cp "$BRAND_ROOT/assets/Dieter.icns" "$APP_BUNDLE/Contents/Resources/Dieter.icns"
    cp "$BRAND_ROOT/assets/png/app-icon-dark-1024.png" "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png"
    cp "$BRAND_ROOT/assets/png/favicon-32.png" "$APP_BUNDLE/Contents/Resources/DieterFavicon.png"
    cp "$BRAND_ROOT/assets/fonts/Sora-Variable.ttf" "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf"
    cp "$PALETTE_ICON_ROOT"/*.png "$APP_BUNDLE/Contents/Resources/PaletteIcons/"
    cp "$DIETER_BINARY" "$APP_BUNDLE/Contents/MacOS/DieterMac"
fi

codesign --force --deep --sign - "$APP_BUNDLE" >&2
stat -f '%N %Fm %z %i' \
    "$APP_BUNDLE/Contents/Info.plist" \
    "$APP_BUNDLE/Contents/Resources/Dieter.icns" \
    "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png" \
    "$APP_BUNDLE/Contents/Resources/DieterFavicon.png" \
    "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf" \
    "$APP_BUNDLE/Contents/MacOS/DieterMac" >"$NEW_BUNDLE_OUTPUT_MANIFEST"
find "$APP_BUNDLE/Contents/Resources/PaletteIcons" -type f | sort | xargs stat -f '%N %Fm %z %i' >>"$NEW_BUNDLE_OUTPUT_MANIFEST"
mv "$NEW_BUNDLE_MANIFEST" "$BUNDLE_MANIFEST"
mv "$NEW_BUNDLE_OUTPUT_MANIFEST" "$BUNDLE_OUTPUT_MANIFEST"
trap - EXIT INT TERM

echo "$APP_BUNDLE"

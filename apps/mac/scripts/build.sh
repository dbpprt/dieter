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
swift build \
    --package-path "$APP_ROOT" \
    --scratch-path "$SWIFT_SCRATCH_PATH" \
    --only-use-versions-from-resolved-file \
    --manifest-cache local \
    --disable-index-store \
    --product DieterMac \
    -c "$CONFIGURATION" >&2
DIETER_BINARY="$SWIFT_SCRATCH_PATH/$CONFIGURATION/DieterMac"
if [ ! -x "$DIETER_BINARY" ]; then
    echo "DieterMac binary was not produced" >&2
    exit 1
fi
WEBRTC_FRAMEWORK="$SWIFT_SCRATCH_PATH/$CONFIGURATION/WebRTC.framework"
WEBRTC_BINARY="$WEBRTC_FRAMEWORK/Versions/A/WebRTC"
WEBRTC_INFO_PLIST="$WEBRTC_FRAMEWORK/Versions/A/Resources/Info.plist"
if [ ! -x "$WEBRTC_BINARY" ] || [ ! -f "$WEBRTC_INFO_PLIST" ]; then
    echo "WebRTC.framework was not produced alongside DieterMac" >&2
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"
NEW_BUNDLE_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-mac-bundle.XXXXXX")
NEW_BUNDLE_OUTPUT_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-mac-bundle-output.XXXXXX")
trap 'rm -f "$NEW_BUNDLE_MANIFEST" "$NEW_BUNDLE_OUTPUT_MANIFEST"' EXIT INT TERM
stat -f '%N %Fm %z %i' \
    "$APP_ROOT/Resources/Info.plist" \
    "$APP_ROOT/Resources/DieterMonochrome.icns" \
    "$PALETTE_ICON_ROOT/monochrome.png" \
    "$APP_ROOT/Resources/DieterMonochromeFavicon.png" \
    "$BRAND_ROOT/assets/fonts/Sora-Variable.ttf" \
    "$DIETER_BINARY" \
    "$WEBRTC_BINARY" \
    "$WEBRTC_INFO_PLIST" >"$NEW_BUNDLE_MANIFEST"
find "$PALETTE_ICON_ROOT" -type f | sort | xargs stat -f '%N %Fm %z %i' >>"$NEW_BUNDLE_MANIFEST"

BUNDLE_OUTPUTS_MATCH=0
if [ -f "$APP_BUNDLE/Contents/Info.plist" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/Dieter.icns" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/DieterFavicon.png" ] && \
    [ -d "$APP_BUNDLE/Contents/Resources/PaletteIcons" ] && \
    [ -f "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf" ] && \
    [ -x "$APP_BUNDLE/Contents/MacOS/DieterMac" ] && \
    [ -x "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC" ] && \
    [ -f "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework/Versions/A/Resources/Info.plist" ]; then
    stat -f '%N %Fm %z %i' \
        "$APP_BUNDLE/Contents/Info.plist" \
        "$APP_BUNDLE/Contents/Resources/Dieter.icns" \
        "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png" \
        "$APP_BUNDLE/Contents/Resources/DieterFavicon.png" \
        "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf" \
        "$APP_BUNDLE/Contents/MacOS/DieterMac" \
        "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC" \
        "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework/Versions/A/Resources/Info.plist" >"$NEW_BUNDLE_OUTPUT_MANIFEST"
    find "$APP_BUNDLE/Contents/Resources/PaletteIcons" -type f | sort | xargs stat -f '%N %Fm %z %i' >>"$NEW_BUNDLE_OUTPUT_MANIFEST"
    if [ -f "$BUNDLE_OUTPUT_MANIFEST" ] && \
        cmp -s "$NEW_BUNDLE_OUTPUT_MANIFEST" "$BUNDLE_OUTPUT_MANIFEST"; then
        BUNDLE_OUTPUTS_MATCH=1
    fi
fi

if [ ! -f "$BUNDLE_MANIFEST" ] || \
    ! cmp -s "$NEW_BUNDLE_MANIFEST" "$BUNDLE_MANIFEST" || \
    [ "$BUNDLE_OUTPUTS_MATCH" -ne 1 ]; then
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks" "$APP_BUNDLE/Contents/Resources/Fonts" "$APP_BUNDLE/Contents/Resources/PaletteIcons"
    cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    cp "$APP_ROOT/Resources/DieterMonochrome.icns" "$APP_BUNDLE/Contents/Resources/Dieter.icns"
    cp "$PALETTE_ICON_ROOT/monochrome.png" "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png"
    cp "$APP_ROOT/Resources/DieterMonochromeFavicon.png" "$APP_BUNDLE/Contents/Resources/DieterFavicon.png"
    cp "$BRAND_ROOT/assets/fonts/Sora-Variable.ttf" "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf"
    cp "$PALETTE_ICON_ROOT"/*.png "$APP_BUNDLE/Contents/Resources/PaletteIcons/"
    cp "$DIETER_BINARY" "$APP_BUNDLE/Contents/MacOS/DieterMac"
    rm -rf "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework"
    ditto "$WEBRTC_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework"
fi

codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework" >&2
codesign --force --deep --sign - "$APP_BUNDLE" >&2
"$SCRIPT_DIR/verify-bundle.sh" "$APP_BUNDLE" >&2
stat -f '%N %Fm %z %i' \
    "$APP_BUNDLE/Contents/Info.plist" \
    "$APP_BUNDLE/Contents/Resources/Dieter.icns" \
    "$APP_BUNDLE/Contents/Resources/DieterAppIcon.png" \
    "$APP_BUNDLE/Contents/Resources/DieterFavicon.png" \
    "$APP_BUNDLE/Contents/Resources/Fonts/Sora-Variable.ttf" \
    "$APP_BUNDLE/Contents/MacOS/DieterMac" \
    "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC" \
    "$APP_BUNDLE/Contents/Frameworks/WebRTC.framework/Versions/A/Resources/Info.plist" >"$NEW_BUNDLE_OUTPUT_MANIFEST"
find "$APP_BUNDLE/Contents/Resources/PaletteIcons" -type f | sort | xargs stat -f '%N %Fm %z %i' >>"$NEW_BUNDLE_OUTPUT_MANIFEST"
mv "$NEW_BUNDLE_MANIFEST" "$BUNDLE_MANIFEST"
mv "$NEW_BUNDLE_OUTPUT_MANIFEST" "$BUNDLE_OUTPUT_MANIFEST"
trap - EXIT INT TERM

echo "$APP_BUNDLE"

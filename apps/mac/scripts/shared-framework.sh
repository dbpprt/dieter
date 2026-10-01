#!/bin/sh
# Assembles the shared core's DieterShared.xcframework into apps/mac/Frameworks
# when its inputs changed. The Mac package links it as a binary target.
#
# usage: shared-framework.sh [debug|release] [macos|all]
#   macos  the macOS slice only (Mac builds and tests)
#   all    macOS, iOS, and the iOS Simulator (iOS builds)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CORE_ROOT="$REPO_ROOT/apps/core"
CONFIGURATION=${1:-debug}
PLATFORMS=${2:-macos}
OUTPUT_DIR="$APP_ROOT/Frameworks"
FRAMEWORK="$OUTPUT_DIR/DieterShared.xcframework"
MANIFEST="$OUTPUT_DIR/.DieterShared.inputs"

case "$CONFIGURATION" in
debug) GRADLE_CONFIGURATION=Debug ;;
release) GRADLE_CONFIGURATION=Release ;;
*) echo "usage: $0 [debug|release] [macos|all]" >&2; exit 2 ;;
esac
case "$PLATFORMS" in
macos) TARGETS="MacosArm64" ;;
all) TARGETS="MacosArm64 IosArm64 IosSimulatorArm64" ;;
*) echo "usage: $0 [debug|release] [macos|all]" >&2; exit 2 ;;
esac

# Every tracked or unignored core file except the retired Swift harness.
inputs_digest() {
    (
        cd "$REPO_ROOT"
        git ls-files -co --exclude-standard -- apps/core | grep -v '^apps/core/harness/' | sort | while IFS= read -r file; do
            [ -f "$file" ] && shasum -a 256 "$file"
        done
        shasum -a 256 apps/mac/scripts/shared-framework.sh
    ) | shasum -a 256 | awk '{print $1}'
}

DIGEST=$(inputs_digest)
# An existing framework is current when its inputs match and it has every
# requested slice; a macOS build accepts a framework that also has iOS slices.
if [ -d "$FRAMEWORK" ] && [ -f "$MANIFEST" ]; then
    if grep -qx "inputs $DIGEST $CONFIGURATION" "$MANIFEST"; then
        current=1
        for target in $TARGETS; do
            grep -qx "slice $target" "$MANIFEST" || current=0
        done
        [ "$current" = 1 ] && exit 0
    fi
fi

if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
    JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    export JAVA_HOME
fi

set --
for target in $TARGETS; do
    set -- "$@" ":apple:link${GRADLE_CONFIGURATION}Framework${target}"
done
echo "Building DieterShared ($CONFIGURATION: $TARGETS)" >&2
"$CORE_ROOT/gradlew" --project-dir "$CORE_ROOT" --console=plain "$@" >&2

set --
for target in $TARGETS; do
    lower=$(printf '%s' "$target" | awk '{print tolower(substr($0,1,1)) substr($0,2)}')
    set -- "$@" -framework "$CORE_ROOT/apple/build/bin/$lower/${CONFIGURATION}Framework/DieterShared.framework"
done

mkdir -p "$OUTPUT_DIR"
STAGING=$(mktemp -d "$OUTPUT_DIR/.DieterShared.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT INT TERM
xcodebuild -create-xcframework "$@" -output "$STAGING/DieterShared.xcframework" >&2
{
    echo "inputs $DIGEST $CONFIGURATION"
    for target in $TARGETS; do echo "slice $target"; done
} >"$STAGING/manifest"
rm -rf "$FRAMEWORK"
mv "$STAGING/DieterShared.xcframework" "$FRAMEWORK"
mv "$STAGING/manifest" "$MANIFEST"

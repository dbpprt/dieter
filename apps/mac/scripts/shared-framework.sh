#!/bin/sh
# Assembles the shared core's DieterShared.xcframework into apps/mac/Frameworks
# when its inputs changed. The Mac package links it as a binary target.
#
# usage: shared-framework.sh [debug|release] [macos|ios-simulator|all]
#   macos  the macOS slice only (Mac builds and tests)
#   ios-simulator  macOS and the iOS Simulator (local iOS tests)
#   all    macOS, iOS device, and the iOS Simulator (release builds)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
# Direct framework preparation must respect consumers of the published binary.
if [ "${DIETER_APPLE_BUILD_LEASE:-}" != "$REPO_ROOT" ]; then
    exec python3 "$REPO_ROOT/scripts/native_build_lock.py" apple-build "$REPO_ROOT" "$0" "$@"
fi
# Serialize the shared binary publication across Mac/iOS and direct callers.
# The lock survives exec and is released by the OS even on interruption.
if [ "${DIETER_SHARED_FRAMEWORK_LEASE:-}" != "$REPO_ROOT" ]; then
    exec python3 "$REPO_ROOT/scripts/native_build_lock.py" shared-framework "$REPO_ROOT" "$0" "$@"
fi
CORE_ROOT="$REPO_ROOT/apps/core"
CONFIGURATION=${1:-debug}
PLATFORMS=${2:-macos}
OUTPUT_DIR="$APP_ROOT/Frameworks"
FRAMEWORK="$OUTPUT_DIR/DieterShared.xcframework"
MANIFEST="$OUTPUT_DIR/.DieterShared.inputs"

case "$CONFIGURATION" in
debug) GRADLE_CONFIGURATION=Debug ;;
release) GRADLE_CONFIGURATION=Release ;;
*) echo "usage: $0 [debug|release] [macos|ios-simulator|all]" >&2; exit 2 ;;
esac
case "$PLATFORMS" in
macos) TARGETS="MacosArm64" ;;
ios-simulator) TARGETS="MacosArm64 IosSimulatorArm64" ;;
all) TARGETS="MacosArm64 IosArm64 IosSimulatorArm64" ;;
*) echo "usage: $0 [debug|release] [macos|ios-simulator|all]" >&2; exit 2 ;;
esac

# Hash only production inputs, including the schema and selected toolchains.
# Test/documentation edits must not replace the binary target and rebuild Swift.
if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
    JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    export JAVA_HOME
fi
inputs_digest() {
    python3 - "$REPO_ROOT" <<'PYTHON'
import hashlib, os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
paths = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", "apps/core", "api/proto", "apps/mac/scripts/shared-framework.sh"], cwd=root).split(b"\0")
h = hashlib.sha256()
for raw in sorted(set(filter(None, paths))):
    path = raw.decode()
    if path.endswith(".md") or path.startswith("apps/core/testing/"):
        continue
    if "/src/" in path and path.split("/src/", 1)[1].split("/", 1)[0].endswith("Test"):
        continue
    file = root / path
    if file.is_file():
        h.update(raw + b"\0" + file.read_bytes())
java = str(pathlib.Path(os.environ["JAVA_HOME"]) / "bin/java") if os.environ.get("JAVA_HOME") else "java"
for argv in (["xcodebuild", "-version"], [java, "-version"]):
    h.update(subprocess.check_output(argv, stderr=subprocess.STDOUT))
for name in ("DEVELOPER_DIR", "JAVA_HOME", "GRADLE_OPTS", "JAVA_TOOL_OPTIONS"):
    h.update(name.encode() + b"\0" + os.environ.get(name, "").encode() + b"\0")
print(h.hexdigest())
PYTHON
}

DIGEST=$(inputs_digest)
# Preserve the existing configuration's slice superset when source changes.
# A Mac build after an iOS build must not discard the simulator slice and make
# the next iOS build replace an otherwise current binary again.
if [ -f "$MANIFEST" ] && grep -q " $CONFIGURATION$" "$MANIFEST"; then
    for target in MacosArm64 IosArm64 IosSimulatorArm64; do
        if grep -qx "slice $target" "$MANIFEST"; then
            case " $TARGETS " in *" $target "*) ;; *) TARGETS="$TARGETS $target" ;; esac
        fi
    done
fi
# xcodebuild records slice order in Info.plist. Canonicalize the union so
# callers asking for different subsets do not republish equivalent metadata.
REQUESTED_TARGETS="$TARGETS"
TARGETS=""
for target in MacosArm64 IosArm64 IosSimulatorArm64; do
    case " $REQUESTED_TARGETS " in *" $target "*) TARGETS="${TARGETS:+$TARGETS }$target" ;; esac
done
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
# An input-key refresh or Gradle UP-TO-DATE result can assemble identical bytes.
# Preserve timestamps so SwiftPM/Xcode keep their existing compiled modules.
if [ ! -d "$FRAMEWORK" ] || ! python3 "$REPO_ROOT/scripts/native_build_lock.py" --same-tree "$STAGING/DieterShared.xcframework" "$FRAMEWORK"; then
    rm -rf "$FRAMEWORK"
    mv "$STAGING/DieterShared.xcframework" "$FRAMEWORK"
fi
mv "$STAGING/manifest" "$MANIFEST"

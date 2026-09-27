#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CONFIGURATION=${CONFIGURATION:-debug}
SWIFT_SCRATCH_PATH=${DIETER_SWIFT_SCRATCH_PATH:-$APP_ROOT/.build/dieter-local}

# Check before compilation and again before packaging: an operator can open
# the app while SwiftPM is building. Direct script callers get the same guard.
python3 "$REPO_ROOT/scripts/mac_app_lifecycle.py" assert-stopped

"$SCRIPT_DIR/sync-proto.sh" >&2
set --
if [ -n "${DIETER_SWIFT_JOBS:-}" ]; then
    set -- --jobs "$DIETER_SWIFT_JOBS"
fi
swift build \
    "$@" \
    --package-path "$APP_ROOT" \
    --scratch-path "$SWIFT_SCRATCH_PATH" \
    --only-use-versions-from-resolved-file \
    --manifest-cache local \
    --disable-index-store \
    --product DieterMac \
    -c "$CONFIGURATION" >&2
python3 "$REPO_ROOT/scripts/mac_bundle.py" --products "$SWIFT_SCRATCH_PATH/$CONFIGURATION"

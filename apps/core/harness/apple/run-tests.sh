#!/bin/sh
# Runs the Swift adapter harness against a disposable isolated gateway and
# daemon. It never touches an operator's gateway, daemon, or DIETER_HOME.
set -eu

HARNESS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE=$(CDPATH= cd -- "$HARNESS/../.." && pwd)
REPO=$(CDPATH= cd -- "$CORE/../.." && pwd)
CONFIGURATION=${DIETER_SHARED_CONFIGURATION:-debug}

# The XCFramework from :apple and the Mac app's SwiftPM pins.
rm -rf "$HARNESS/DieterShared.xcframework"
cp -R "$CORE/apple/build/XCFrameworks/$CONFIGURATION/DieterShared.xcframework" "$HARNESS/DieterShared.xcframework"
[ -f "$HARNESS/Package.resolved" ] || cp "$REPO/apps/mac/Package.resolved" "$HARNESS/Package.resolved"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dieter-shared-harness.XXXXXX")
FIXTURE_PID=
cleanup() {
    [ -n "$FIXTURE_PID" ] && kill "$FIXTURE_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

(cd "$REPO" && "${GO:-go}" build -o "$WORK/isolated-gateway" ./scripts/isolated-gateway)
DIETER_HARNESS_RUNTIME_DIR="$REPO/internal/harness/runtime" \
    "$WORK/isolated-gateway" -addr 127.0.0.1:0 -home "$WORK/fixture" >"$WORK/stdout" 2>"$WORK/fixture.log" &
FIXTURE_PID=$!
tries=0
until grep -qx READY "$WORK/stdout"; do
    if ! kill -0 "$FIXTURE_PID" 2>/dev/null || [ "$tries" -ge 600 ]; then
        echo "the isolated gateway did not start:" >&2
        tail -50 "$WORK/fixture.log" >&2
        exit 1
    fi
    tries=$((tries + 1))
    sleep 0.1
done
for line in $(grep '^DIETER_ISOLATED_[A-Z_]*=' "$WORK/stdout"); do export "$line"; done

cd "$HARNESS"
swift test --only-use-versions-from-resolved-file "$@"

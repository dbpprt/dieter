#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
mkdir -p "$APP_ROOT/.build"
CAPTURE_DIR=$(mktemp -d "$APP_ROOT/.build/sidebar-ui-smoke.XXXXXX")
PREFERENCES_SUITE="com.dbpprt.dieter.sidebar-smoke.$(uuidgen | tr '[:upper:]' '[:lower:]')"
APP_PID=

cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; fi
    defaults delete "$PREFERENCES_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Dieter.app/Contents/MacOS/DieterMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Dieter.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
fi

run_phase() {
    PHASE=$1
    OUTPUT="$CAPTURE_DIR/$PHASE"
    mkdir -p "$OUTPUT"
    open -n -W "$APP_BUNDLE" --args --sidebar-ui-smoke "$PHASE" \
        --sidebar-preferences-suite "$PREFERENCES_SUITE" \
        --ui-smoke-output "$OUTPUT" >"$OUTPUT/app.log" 2>&1 &
    APP_PID=$!

    COUNT=0
    while [ ! -f "$OUTPUT/report.json" ] && [ "$COUNT" -lt 30 ]; do
        sleep 1
        COUNT=$((COUNT + 1))
    done
    if [ ! -f "$OUTPUT/report.json" ]; then
        echo "Sidebar UI smoke phase $PHASE timed out; see $OUTPUT/app.log" >&2
        exit 1
    fi
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=

    cat "$OUTPUT/report.json"
    printf '\n'
    if grep -q 'failed' "$OUTPUT/report.json"; then exit 1; fi
}

run_phase prepare
run_phase verify
echo "$CAPTURE_DIR"

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CAPTURE_DIR="$APP_ROOT/.build/island-ui-smoke"
PREFERENCES_SUITE="com.dbpprt.dieter.island-smoke.$(uuidgen | tr '[:upper:]' '[:lower:]')"
APP_PID=

cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; fi
    defaults delete "$PREFERENCES_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

rm -rf "$CAPTURE_DIR"
mkdir -p "$CAPTURE_DIR"

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Dieter.app/Contents/MacOS/DieterMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Dieter.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
fi

defaults write "$PREFERENCES_SUITE" DieterAppearance -string dark
open -n -W "$APP_BUNDLE" --args \
    --island-ui-smoke \
    --island-ui-smoke-output "$CAPTURE_DIR" \
    --dieter-state-root "$CAPTURE_DIR/state" \
    --appearance-defaults-suite "$PREFERENCES_SUITE" >"$CAPTURE_DIR/app.log" 2>&1 &
APP_PID=$!

COUNT=0
while [ ! -f "$CAPTURE_DIR/report.json" ] && [ "$COUNT" -lt 30 ]; do
    sleep 1
    COUNT=$((COUNT + 1))
done
if [ ! -f "$CAPTURE_DIR/report.json" ]; then
    echo "Island UI smoke run timed out; see $CAPTURE_DIR/app.log" >&2
    exit 1
fi

cat "$CAPTURE_DIR/report.json"
if grep -q 'failed' "$CAPTURE_DIR/report.json"; then exit 1; fi
echo "$CAPTURE_DIR"

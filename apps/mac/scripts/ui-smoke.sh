#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CAPTURE_DIR="$APP_ROOT/.build/ui-smoke"
mkdir -p "$CAPTURE_DIR"
rm -f "$CAPTURE_DIR/report.json"

if ! lsof -nP -iTCP:4242 -sTCP:LISTEN >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && go run ./cmd/nauclio serve >"$CAPTURE_DIR/server.log" 2>&1) &
    SERVER_PID=$!
    trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM
fi

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Nauclio.app/Contents/MacOS/NauclioMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Nauclio.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
fi
pkill -x NauclioMac 2>/dev/null || true
"$APP_BUNDLE/Contents/MacOS/NauclioMac" --ui-smoke --ui-smoke-output "$CAPTURE_DIR" >"$CAPTURE_DIR/app.log" 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi' EXIT INT TERM

COUNT=0
while [ ! -f "$CAPTURE_DIR/report.json" ] && [ "$COUNT" -lt 60 ]; do
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ ! -f "$CAPTURE_DIR/report.json" ]; then
    echo "Native UI smoke run timed out; see $CAPTURE_DIR/app.log" >&2
    exit 1
fi

cat "$CAPTURE_DIR/report.json"
if grep -q 'failed' "$CAPTURE_DIR/report.json"; then
    exit 1
fi

echo "$CAPTURE_DIR"

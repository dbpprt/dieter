#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CAPTURE_DIR="$APP_ROOT/.build/conversation-ui-smoke"
mkdir -p "$CAPTURE_DIR"
rm -f "$CAPTURE_DIR/report.json" "$CAPTURE_DIR/progress.log"

if ! lsof -nP -iTCP:4242 -sTCP:LISTEN >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && go run ./cmd/dieter serve >"$CAPTURE_DIR/server.log" 2>&1) &
    SERVER_PID=$!
    trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM
fi

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Dieter.app/Contents/MacOS/DieterMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Dieter.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
fi
pkill -x DieterMac 2>/dev/null || true
"$APP_BUNDLE/Contents/MacOS/DieterMac" --conversation-ui-smoke --ui-smoke-output "$CAPTURE_DIR" >"$CAPTURE_DIR/app.log" 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi' EXIT INT TERM

# When launched outside an interactive login context SwiftUI occasionally
# skips creating the initial window, which keeps the runner's task from
# firing. A reopen event (the Dock-click equivalent) reliably opens it.
COUNT=0
while [ ! -f "$CAPTURE_DIR/progress.log" ] && [ "$COUNT" -lt 10 ]; do
    sleep 1
    COUNT=$((COUNT + 1))
done
if [ ! -f "$CAPTURE_DIR/progress.log" ]; then
    open "$APP_BUNDLE"
fi

COUNT=0
while [ ! -f "$CAPTURE_DIR/report.json" ] && [ "$COUNT" -lt 90 ]; do
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ ! -f "$CAPTURE_DIR/report.json" ]; then
    echo "Conversation UI smoke run timed out; see $CAPTURE_DIR/app.log" >&2
    exit 1
fi

cat "$CAPTURE_DIR/report.json"
if grep -q 'failed' "$CAPTURE_DIR/report.json"; then
    exit 1
fi

echo "$CAPTURE_DIR"

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CAPTURE_DIR="$APP_ROOT/.build/conversation-ui-smoke"
PORT=${DIETER_CONVERSATION_SMOKE_PORT:-14247}
ADDRESS="127.0.0.1:$PORT"
ENDPOINT="http://$ADDRESS"
TOKEN_FILE="$CAPTURE_DIR/session-token"
GATEWAY_PID=
APP_PID=

cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; fi
    pkill -x DieterMac 2>/dev/null || true
    if [ -n "$GATEWAY_PID" ]; then kill "$GATEWAY_PID" 2>/dev/null || true; fi
    rm -f "$TOKEN_FILE" "$CAPTURE_DIR/gateway.env"
}
trap cleanup EXIT INT TERM

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Conversation UI smoke port $PORT is already in use; set DIETER_CONVERSATION_SMOKE_PORT to another alternate port." >&2
    exit 1
fi

rm -rf "$CAPTURE_DIR"
mkdir -p "$CAPTURE_DIR"
(cd "$REPO_ROOT" && go build -o "$CAPTURE_DIR/isolated-gateway" ./scripts/isolated-gateway)
"$CAPTURE_DIR/isolated-gateway" --addr "$ADDRESS" >"$CAPTURE_DIR/gateway.env" 2>"$CAPTURE_DIR/gateway.log" &
GATEWAY_PID=$!

COUNT=0
while ! grep -q '^READY$' "$CAPTURE_DIR/gateway.env" 2>/dev/null && [ "$COUNT" -lt 45 ]; do
    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
        echo "Isolated gateway stopped before becoming ready; see $CAPTURE_DIR/gateway.log" >&2
        exit 1
    fi
    sleep 1
    COUNT=$((COUNT + 1))
done
if ! grep -q '^READY$' "$CAPTURE_DIR/gateway.env" 2>/dev/null; then
    echo "Isolated gateway did not become ready; see $CAPTURE_DIR/gateway.log" >&2
    exit 1
fi

TOKEN=$(sed -n 's/^DIETER_ISOLATED_TOKEN=//p' "$CAPTURE_DIR/gateway.env")
if [ -z "$TOKEN" ]; then
    echo "Isolated gateway did not print a session token." >&2
    exit 1
fi
printf '%s' "$TOKEN" >"$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Dieter.app/Contents/MacOS/DieterMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Dieter.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
fi
pkill -x DieterMac 2>/dev/null || true
open -n -W "$APP_BUNDLE" --args --dieter-endpoint "$ENDPOINT" \
    --dieter-access-token-file "$TOKEN_FILE" \
    --conversation-ui-smoke --ui-smoke-output "$CAPTURE_DIR" >"$CAPTURE_DIR/app.log" 2>&1 &
APP_PID=$!

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

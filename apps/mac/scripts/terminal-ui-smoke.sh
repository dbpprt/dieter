#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
PORT=${DIETER_TERMINAL_SMOKE_PORT:-14244}
ADDRESS="127.0.0.1:$PORT"
ENDPOINT="http://$ADDRESS"
CAPTURE_DIR="$APP_ROOT/.build/terminal-ui-smoke"
TOKEN_FILE="$CAPTURE_DIR/session-token"
GATEWAY_PID=
APP_PID=

cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; fi
    if [ -n "$GATEWAY_PID" ]; then kill "$GATEWAY_PID" 2>/dev/null || true; fi
    rm -f "$TOKEN_FILE" "$CAPTURE_DIR/gateway.env"
}
trap cleanup EXIT INT TERM

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Terminal UI smoke port $PORT is already in use; set DIETER_TERMINAL_SMOKE_PORT to another alternate port." >&2
    exit 1
fi

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Dieter.app/Contents/MacOS/DieterMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Dieter.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
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

run_phase() {
    PHASE=$1
    REPORT=$2
    open -n -W "$APP_BUNDLE" --args --dieter-endpoint "$ENDPOINT" \
        --dieter-access-token-file "$TOKEN_FILE" \
        --terminal-ui-smoke "$PHASE" \
        --ui-smoke-output "$CAPTURE_DIR" >"$CAPTURE_DIR/app-$PHASE.log" 2>&1 &
    APP_PID=$!

    COUNT=0
    while [ ! -f "$CAPTURE_DIR/$REPORT" ] && [ "$COUNT" -lt 75 ]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "Mac app stopped during terminal smoke phase $PHASE; see $CAPTURE_DIR/app-$PHASE.log" >&2
            exit 1
        fi
        sleep 1
        COUNT=$((COUNT + 1))
    done
    if [ ! -f "$CAPTURE_DIR/$REPORT" ]; then
        echo "Terminal UI smoke phase $PHASE timed out; see $CAPTURE_DIR/app-$PHASE.log" >&2
        exit 1
    fi
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=
    if grep -q 'failed' "$CAPTURE_DIR/$REPORT"; then
        cat "$CAPTURE_DIR/$REPORT"
        exit 1
    fi
}

run_phase create create-report.json
# The first client is gone here. The isolated daemon and its PTY remain alive.
run_phase resume report.json

cat "$CAPTURE_DIR/report.json"
printf '\n%s\n' "$CAPTURE_DIR"

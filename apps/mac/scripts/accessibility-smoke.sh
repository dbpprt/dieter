#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CAPTURE_DIR="$APP_ROOT/.build/accessibility-smoke"
mkdir -p "$CAPTURE_DIR"

if ! lsof -nP -iTCP:4242 -sTCP:LISTEN >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && go run ./cmd/nauclio serve >"$CAPTURE_DIR/server.log" 2>&1) &
    SERVER_PID=$!
    COUNT=0
    while ! lsof -nP -iTCP:4242 -sTCP:LISTEN >/dev/null 2>&1; do
        sleep 1
        COUNT=$((COUNT + 1))
        if [ "$COUNT" -ge 30 ]; then echo "nauclio serve did not become ready" >&2; exit 1; fi
    done
fi
trap 'pkill -x NauclioMac 2>/dev/null || true; if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi' EXIT INT TERM

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x "$APP_ROOT/build/Nauclio.app/Contents/MacOS/NauclioMac" ]; then
    APP_BUNDLE="$APP_ROOT/build/Nauclio.app"
else
    APP_BUNDLE=$($SCRIPT_DIR/build.sh)
fi

pkill -x NauclioMac 2>/dev/null || true
sleep 1
open -n "$APP_BUNDLE"

COUNT=0
while ! osascript -e 'tell application "System Events" to tell process "Nauclio" to exists window 1' 2>/dev/null | grep -q true; do
    sleep 1
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge 30 ]; then echo "Nauclio window did not appear" >&2; exit 1; fi
done
sleep 2

POSITION=$(osascript -e 'tell application "System Events" to tell process "Nauclio" to get position of window 1' | tr ',' ' ')
set -- $POSITION
WINDOW_X=$1
WINDOW_Y=$2

click_at() {
    LABEL=$1
    X=$2
    Y=$3
    ATTEMPT=0
    until osascript - "$X" "$Y" <<'APPLESCRIPT'
on run argv
    set clickX to item 1 of argv as integer
    set clickY to item 2 of argv as integer
    tell application "Nauclio" to activate
    delay 0.2
    tell application "System Events" to click at {clickX, clickY}
end run
APPLESCRIPT
    do
        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -ge 3 ]; then return 1; fi
        sleep 1
    done
    sleep 2
    screencapture -x "$CAPTURE_DIR/$LABEL.png"
}

click_at "00-navigation-collapsed" $((WINDOW_X + 164)) $((WINDOW_Y + 64))
click_at "00-navigation-expanded" $((WINDOW_X + 29)) $((WINDOW_Y + 64))
click_at "01-global-chats" $((WINDOW_X + 80)) $((WINDOW_Y + 165))
click_at "02-standalone-chat" $((WINDOW_X + 390)) $((WINDOW_Y + 184))
click_at "03-project-files" $((WINDOW_X + 80)) $((WINDOW_Y + 271))
click_at "04-project-schedules" $((WINDOW_X + 80)) $((WINDOW_Y + 306))
click_at "05-board" $((WINDOW_X + 80)) $((WINDOW_Y + 237))
click_at "06-card-conversation" $((WINDOW_X + 360)) $((WINDOW_Y + 210))

echo "$CAPTURE_DIR"

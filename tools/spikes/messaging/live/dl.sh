#!/bin/sh
# dl.sh: run the working-tree dieter CLI against the isolated live-test daemon.
# LIVE_ROOT must point at the temp root (DIETER_HOME=$LIVE_ROOT/home).
set -eu
: "${LIVE_ROOT:?set LIVE_ROOT}"
REPO=$(cd "$(dirname "$0")/../../../.." && pwd)
unset DIETER_TURN_TOKEN DIETER_CARD_ID DIETER_HOME
export DIETER_HOME="$LIVE_ROOT/home"
exec "$REPO/bin/dieter" "$@"

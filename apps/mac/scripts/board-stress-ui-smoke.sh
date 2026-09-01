#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export DIETER_UI_SMOKE_GATEWAY_ARGUMENT="--board-stress-fixture"
export DIETER_UI_SMOKE_EXTRA_ARGUMENT="--board-stress-ui-smoke --lane-sort-ui-smoke"
export DIETER_UI_SMOKE_PORT="${DIETER_UI_SMOKE_PORT:-14246}"

exec "$SCRIPT_DIR/ui-smoke.sh"

#!/bin/sh
# Runs one macOS scenario matrix: mac-matrix.sh <label> <driver> <repeat> <provider...>
set -u
label=$1 driver=$2 repeat=$3
shift 3
SPIKE=/Users/dbpprt/Development/dieter/tools/spikes/workspaces/spike
ROOT=/Volumes/External/dieter-spike/mac.noindex/$label
FIX=/Volumes/External/dieter-spike/tree-dev
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID ANTHROPIC_API_KEY
mkdir -p "$ROOT"
for p in "$@"; do
    R=$ROOT/$p
    rm -rf "$R"
    mkdir -p "$R"
    /bin/cp -c -R "$FIX/small" "$R/source"
    echo "### provider $p driver $driver"
    "$SPIKE" run -root "$R" -source "$R/source" -assets "$FIX/assets" -provider "$p" -driver "$driver" \
        -repeat "$repeat" -claude-node-dir /Volumes/External/dieter-spike/node -out "$ROOT/results.jsonl" 2>&1
done
"$SPIKE" report -out "$ROOT/report.md" "$ROOT/results.jsonl"
echo "### done $label"

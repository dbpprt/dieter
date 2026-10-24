#!/bin/sh
# Runs one Linux scenario matrix on garuda: linux-matrix.sh <label> <driver> <repeat> <provider...>
set -u
label=$1 driver=$2 repeat=$3
shift 3
SPIKE=$HOME/dieter-spike/spike
L=$HOME/dieter-spike/linux
FIX=$L/fixtures
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID ANTHROPIC_API_KEY
mkdir -p "$FIX" "$L/$label"
if [ ! -d "$FIX/small/.git" ]; then
    "$SPIKE" fixture -dir "$FIX/small" -profile small -assets "$FIX/assets" -subvolume >/dev/null || exit 1
fi
for p in "$@"; do
    R=$L/$label/$p
    if [ -d "$R" ]; then
        chmod -R u+rwx "$R" 2>/dev/null
        rm -rf "$R"
    fi
    mkdir -p "$R"
    btrfs subvolume snapshot "$FIX/small" "$R/source" >/dev/null || exit 1
    echo "### provider $p driver $driver"
    "$SPIKE" run -root "$R" -source "$R/source" -assets "$FIX/assets" -provider "$p" -driver "$driver" -repeat "$repeat" \
        -claude-node-dir "$HOME/dieter-spike/node" -claude-creds "$HOME/dieter-spike/creds/claude.json" \
        -codex-auth "$HOME/dieter-spike/creds/codex-auth.json" -codex-bin "$HOME/dieter-spike/node/node_modules/.bin/codex" -codex-model "${SPIKE_CODEX_MODEL:-gpt-6-astra}" \
        -out "$L/$label/results.jsonl" 2>&1
done
"$SPIKE" report -out "$L/$label/report.md" "$L/$label/results.jsonl"
echo "### done $label"

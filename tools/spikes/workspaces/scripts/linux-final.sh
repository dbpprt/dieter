#!/bin/sh
# Final Linux runs: reruns after fixes, concurrency/fork/publish, toolchains.
set -u
SPIKE=$HOME/dieter-spike/spike
L=$HOME/dieter-spike/linux
FIX=$L/fixtures
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID ANTHROPIC_API_KEY
echo "### reruns"
$HOME/dieter-spike/linux-matrix.sh rerun-hydrate script 1 worktree-hydrate
R=$L/rerun-s19
if [ -d "$R" ]; then
    chmod -R u+rwx "$R"
    rm -rf "$R"
fi
mkdir -p "$R"
btrfs subvolume snapshot "$FIX/small" "$R/source" >/dev/null
"$SPIKE" run -root "$R" -source "$R/source" -assets "$FIX/assets" -provider overlay -driver script -scenarios S19 -out "$R/results.jsonl" 2>&1 | tail -2
echo "### concurrency"
R=$L/conc
if [ -d "$R" ]; then
    chmod -R u+rwx "$R"
    rm -rf "$R"
fi
mkdir -p "$R"
btrfs subvolume snapshot "$FIX/small" "$R/source" >/dev/null
SPIKE_DRIVERS=codex,codex,claude SPIKE_SUMMARY=$R/summary.json "$SPIKE" concurrency -root "$R" -source "$R/source" -assets "$FIX/assets" \
    -provider overlay -claude-node-dir "$HOME/dieter-spike/node" -claude-creds "$HOME/dieter-spike/creds/claude.json" \
    -codex-auth "$HOME/dieter-spike/creds/codex-auth.json" -codex-bin "$HOME/dieter-spike/node/node_modules/.bin/codex" -codex-model gpt-6-astra >"$R/conc.log" 2>&1
tail -3 "$R/conc.log"
echo "### e2 overlay"
sh $HOME/dieter-spike/e2-toolchains.sh $L/e2-overlay "$SPIKE" overlay 2>&1 | tail -20
echo "### e2 clone"
sh $HOME/dieter-spike/e2-toolchains.sh $L/e2-clone "$SPIKE" clone 2>&1 | tail -20
echo "### done final"

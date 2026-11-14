#!/bin/sh
# Re-runs after the EBUSY retry wrapper and the hydrate fix.
set -u
SPIKE=$HOME/dieter-spike/spike
L=$HOME/dieter-spike/linux
FIX=$L/fixtures
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID ANTHROPIC_API_KEY
echo "### concurrency (overlay, with retry)"
R=$L/conc2
if [ -d "$R" ]; then
    chmod -R u+rwx "$R"
    rm -rf "$R"
fi
mkdir -p "$R"
btrfs subvolume snapshot "$FIX/small" "$R/source" >/dev/null
SPIKE_DRIVERS=codex,codex,claude SPIKE_SUMMARY=$R/summary.json "$SPIKE" concurrency -root "$R" -source "$R/source" -assets "$FIX/assets" \
    -provider overlay -claude-node-dir "$HOME/dieter-spike/node" -claude-creds "$HOME/dieter-spike/creds/claude.json" \
    -codex-auth "$HOME/dieter-spike/creds/codex-auth.json" -codex-bin "$HOME/dieter-spike/node/node_modules/.bin/codex" -codex-model gpt-6-astra >"$R/conc.log" 2>&1
grep -c "overlay busy" "$R/conc.log" | sed 's/^/busy retries: /'
python3 -c "import json;d=json.load(open('$R/summary.json'));print('fork',d.get('forkMs'),d.get('forkTruth'),d.get('forkErr'));print('parent t2',d.get('parentTurn2Truth'));print('cross',[s['crossSessionPaths'] for s in d['sessions']]);print('merges',[(m['clean'],m['conflicts']) for m in d['mergePreview']])"
echo "### e2 overlay (with retry)"
sh $HOME/dieter-spike/e2-toolchains.sh $L/e2-overlay "$SPIKE" overlay 2>&1 | grep -v "overlay busy" | tail -16
echo "### e1 worktree-hydrate"
for f in small js huge; do
    R=$L/e1h/$f
    if [ -d "$R" ]; then
        chmod -R u+rwx "$R"
        rm -rf "$R"
    fi
    mkdir -p "$R"
    btrfs subvolume snapshot "$FIX/$f" "$R/source" >/dev/null
    "$SPIKE" e1 -root "$R" -source "$R/source" -fixture "$f" -providers worktree-hydrate -runs 3 -out "$L/e1/e1.jsonl" >/dev/null
done
python3 -I $HOME/dieter-spike/costs.py $L/e1/e1.jsonl /dev/null | grep -E "hydrate" | grep -v error
echo "### s19 rerun"
python3 -I $HOME/dieter-spike/summarize.py $L/rerun-s19/results.jsonl | grep -A3 "Git-scope misses"
echo "### done final2"

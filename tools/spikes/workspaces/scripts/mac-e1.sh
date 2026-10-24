#!/bin/sh
# E1 (view cost) and E6 (snapshot cost) on macOS fixtures.
set -u
SPIKE=/Users/dbpprt/Development/dieter/tools/spikes/workspaces/spike
FIX=/Volumes/External/dieter-spike/tree-dev
ROOT=/Volumes/External/dieter-spike/mac.noindex/e1
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
rm -rf "$ROOT"
mkdir -p "$ROOT"
for f in small js huge; do
    R=$ROOT/$f
    mkdir -p "$R"
    "$SPIKE" clone "$FIX/$f" "$R/source"
    provs=clone,clone-raw,clone-worktree,worktree-hydrate,worktree
    [ "$f" = small ] && provs=$provs,clone-cp
    "$SPIKE" e1 -root "$R" -source "$R/source" -fixture "$f" -providers "$provs" -runs 3 -out "$ROOT/e1.jsonl"
    "$SPIKE" snapcost -root "$R/snap" -source "$R/source" -fixture "$f" -provider clone -mods 0,10,100,1000 -runs 3 -out "$ROOT/snapcost.jsonl"
done
echo "### done e1"

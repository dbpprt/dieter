#!/bin/sh
# E1 (view cost) and E6 (snapshot cost) on Linux fixtures (btrfs subvolumes).
set -u
SPIKE=$HOME/dieter-spike/spike
FIX=$HOME/dieter-spike/linux/fixtures
ROOT=$HOME/dieter-spike/linux/e1
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
if [ -d "$ROOT" ]; then
    chmod -R u+rwx "$ROOT"
    rm -rf "$ROOT"
fi
mkdir -p "$ROOT" "$FIX"
for f in small js huge; do
    if [ ! -d "$FIX/$f/.git" ]; then
        t0=$(date +%s)
        "$SPIKE" fixture -dir "$FIX/$f" -profile "$f" -assets "$FIX/assets" -subvolume >/dev/null || exit 1
        echo "fixture $f built in $(($(date +%s) - t0))s"
    fi
    R=$ROOT/$f
    mkdir -p "$R"
    btrfs subvolume snapshot "$FIX/$f" "$R/source" >/dev/null
    "$SPIKE" e1 -root "$R" -source "$R/source" -fixture "$f" -providers overlay,btrfs,reflink,worktree-hydrate,worktree -runs 3 -out "$ROOT/e1.jsonl"
    for p in btrfs overlay; do
        "$SPIKE" snapcost -root "$R/snap-$p" -source "$R/source" -fixture "$f" -provider $p -mods 0,10,100,1000 -runs 3 -out "$ROOT/snapcost.jsonl"
    done
done
echo "### done e1"

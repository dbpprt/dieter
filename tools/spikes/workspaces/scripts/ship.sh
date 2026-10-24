#!/bin/sh
# ship.sh LOCAL REMOTE: copy a file to garuda in <64 KiB remote-exec chunks.
set -eu
local=$1 remote=$2
tmp=$(mktemp -d)
split -b 60000 "$local" "$tmp/part."
dieter --machine garuda remote exec --project dieter -- sh -c "mkdir -p \$(dirname $remote) && : > $remote.part" >/dev/null
for p in "$tmp"/part.*; do
    dieter --machine garuda remote exec --project dieter --stdin -- sh -c "cat >> $remote.part" <"$p" >/dev/null
done
dieter --machine garuda remote exec --project dieter -- sh -c "mv $remote.part $remote && wc -c < $remote"
rm -rf "$tmp"

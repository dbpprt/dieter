#!/bin/sh
# Stand-in for `dieter provider token --turn <role>`: prints the next token of
# a fixed sequence for one provider and counts how often OMP asked.
#   token-helper.sh <state-dir> <anthropic|codex>
set -eu
dir=$1 provider=$2
count_file="$dir/$provider.calls"
n=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
echo "$n" >"$count_file"
file="$dir/$provider.token.$n"
# After the last prepared token, keep returning it.
while [ ! -f "$file" ] && [ "$n" -gt 1 ]; do
    n=$((n - 1))
    file="$dir/$provider.token.$n"
done
cat "$file"

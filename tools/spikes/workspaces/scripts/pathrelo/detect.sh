#!/bin/bash
# detect.sh BASE : list files in ignored/untracked dirs of BASE that embed BASE's absolute path, plus absolute symlinks into BASE
B=$(cd "$1" && pwd -P)
t0=$(python3 -c 'import time;print(time.time())')
cd "$B"
IGN=$(git ls-files -z -o --directory 2>/dev/null | tr '\0' '\n')
nign=$(printf '%s\n' "$IGN" | grep -c .)
files=$(printf '%s\n' "$IGN" | grep . | tr '\n' '\0' | xargs -0 rg -l -F -uuu --no-messages -- "$B" 2>/dev/null)
links=$(printf '%s\n' "$IGN" | grep . | tr '\n' '\0' | xargs -0 -I{} find {} -type l -lname "$B/*" 2>/dev/null)
nf=$(printf '%s\n' "$IGN" | grep . | tr '\n' '\0' | xargs -0 -I{} find {} -type f 2>/dev/null | wc -l)
t1=$(python3 -c 'import time;print(time.time())')
nhit=$(printf '%s\n' "$files" | grep -c .)
echo "$B: ignored entries=$nign scanned files=$(echo $nf) hits=$nhit abs-symlinks=$(printf '%s\n' "$links" | grep -c .) time=$(python3 -c "print(round($t1-$t0,2))")s"
printf '%s\n' "$files" | grep . | awk -F/ '{ if (NF>2) print $1"/"$2"/"$3; else print $0 }' | sort | uniq -c | sort -rn | head -${2:-8} | sed 's/^/   /'

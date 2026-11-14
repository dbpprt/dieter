#!/bin/sh
# poll.sh LIVE_ROOT RUN [SECONDS]: every 2 s append claims and card states
# (JSON Lines) to RUN/poll.jsonl until SECONDS (default 720) elapse.
set -u
ROOT=${1:?LIVE_ROOT}
RUN=${2:?RUN}
LIMIT=${3:-720}
HERE=$(cd "$(dirname "$0")" && pwd)
export LIVE_ROOT=$ROOT
. "$ROOT/$RUN/ids.env"
END=$(($(date +%s) + LIMIT))
while [ "$(date +%s)" -lt "$END" ]; do
    T=$(date +%H:%M:%S)
    C=$("$HERE/dl.sh" channel claims --project "$PROJECT" --format json 2>&1 | tr -d '\n')
    SA=$("$HERE/dl.sh" card show "$A" 2>&1 | python3 -I -c 'import json,sys
try:
  d=json.load(sys.stdin); c=d.get("card",d); print(c.get("lane"), c.get("runtime"))
except Exception as e: print("err", e)')
    SB=$("$HERE/dl.sh" card show "$B" 2>&1 | python3 -I -c 'import json,sys
try:
  d=json.load(sys.stdin); c=d.get("card",d); print(c.get("lane"), c.get("runtime"))
except Exception as e: print("err", e)')
    printf '{"t":"%s","A":"%s","B":"%s","claims":%s}\n' "$T" "$SA" "$SB" "${C:-null}" >>"$DIR/poll.jsonl"
    sleep 2
done

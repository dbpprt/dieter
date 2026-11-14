#!/bin/sh
# dump-tools.sh LIVE_ROOT RUN CARD NAME: save the transcript and every tool
# payload of CARD under RUN/NAME-tools/ and print decoded inputs/outputs.
set -eu
ROOT=${1:?}
RUN=${2:?}
CARD=${3:?}
NAME=${4:?}
HERE=$(cd "$(dirname "$0")" && pwd)
export LIVE_ROOT=$ROOT
OUT="$ROOT/$RUN/$NAME-tools"
mkdir -p "$OUT"
"$HERE/dl.sh" card transcript "$CARD" >"$ROOT/$RUN/transcript-$NAME.json"
python3 -I -c '
import json,sys
d=json.load(open(sys.argv[1]))
for m in d["conversation"]["messages"]:
  for p in m.get("parts",[]):
    if p.get("toolCallId"): print(m["id"], p["toolCallId"])
' "$ROOT/$RUN/transcript-$NAME.json" | nl -w2 -s' ' | while read -r n msg call; do
    "$HERE/dl.sh" card tool-output --message "$msg" --tool-call "$call" "$CARD" >"$OUT/$n.json"
    echo "######## $n $msg $call"
    python3 -I "$HERE/toolout.py" "$OUT/$n.json" "${TAIL:-600}"
done

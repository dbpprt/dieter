#!/bin/sh
# setup-run.sh LIVE_ROOT RUN: fixture repo, project, board with channels on,
# and the Atrium pair cards (A claude-code, B codex) as Todo drafts.
set -eu
ROOT=${1:?LIVE_ROOT}
RUN=${2:?RUN}
HERE=$(cd "$(dirname "$0")" && pwd)
export LIVE_ROOT=$ROOT
DL="$HERE/dl.sh"
DIR="$ROOT/$RUN"
mkdir -p "$DIR"
CODEX_MODEL=$(sed -n 's/^model *= *"\(.*\)"/\1/p' "$ROOT/codex-home/config.toml")
if [ -z "${PROJECT:-}" ]; then
    node "$HERE/fixture.mjs" "$DIR/project"
    PROJECT=$("$DL" project open --name "atrium-$RUN" --board-name "Pair $RUN" --workflow direct --format id "$DIR/project")
    BOARD=$("$DL" board list --format json 2>/dev/null | python3 -I -c 'import json,sys
d=json.load(sys.stdin); bs=d if isinstance(d,list) else d.get("boards",d)
print([b["id"] for b in bs if b.get("projectId")==sys.argv[1] or b.get("project_id")==sys.argv[1]][0])' "$PROJECT")
    "$DL" channel settings --board "$BOARD" --set on
fi
TA="For each of src/module3.js, src/module4.js, src/module6.js and src/module7.js, one file at a time: append ' (reviewed)' to the comment on line 1, then run \`sleep 3 && echo checked\`. When all four are done, commit them with message 'A: review headers'. Commit only the files you changed yourself (git add <files>; never git add -A / . / commit -a)."
TB="Add the line \`export const MAX_TIER_3 = 39;\` at the end of src/module3.js, and append ' (owner: B)' to the comment on line 1 of src/module5.js. Then commit your changes with message 'B: tier cap and owner'. Commit only the files you changed yourself (git add <files>; never git add -A / . / commit -a)."
A=$("$DL" card create --project "$PROJECT" --board "$BOARD" --title "Review headers of modules 3, 4, 6, 7" --workspace project --lane todo --provider claude-code --model "${CLAUDE_MODEL:-sonnet}" --effort low --prompt "$TA" --format id)
B=$("$DL" card create --project "$PROJECT" --board "$BOARD" --title "Add MAX_TIER_3 and module5 owner" --workspace project --lane todo --provider codex --model "$CODEX_MODEL" --effort low --prompt "$TB" --format id)
printf 'PROJECT=%s\nBOARD=%s\nA=%s\nB=%s\nDIR=%s\n' "$PROJECT" "$BOARD" "$A" "$B" "$DIR" | tee "$DIR/ids.env"

#!/bin/sh
# deny-probe.sh LIVE_ROOT: H (claude-code) holds src/module2.js for ~45 s; W
# (codex) must use apply_patch on it, so the PreToolUse hook has to decide.
set -eu
ROOT=${1:?LIVE_ROOT}
RUN=deny
HERE=$(cd "$(dirname "$0")" && pwd)
export LIVE_ROOT=$ROOT
DL="$HERE/dl.sh"
DIR="$ROOT/$RUN"
mkdir -p "$DIR"
node "$HERE/fixture.mjs" "$DIR/project"
CODEX_MODEL=$(sed -n 's/^model *= *"\(.*\)"/\1/p' "$ROOT/codex-home/config.toml")
PROJECT=$("$DL" project open --name "deny-probe" --board-name "Deny" --workflow direct --format id "$DIR/project")
BOARD=$("$DL" board list --project "$PROJECT" --format ids | head -1)
"$DL" channel settings --board "$BOARD" --set on >/dev/null
H=$("$DL" card create --project "$PROJECT" --board "$BOARD" --title "Hold module2" --workspace project --lane todo --provider claude-code --model haiku --effort low --format id \
    --prompt "Run exactly this one shell command and nothing else: echo '// hold' >> src/module2.js && sleep 45 && echo held. Then reply with one line.")
W=$("$DL" card create --project "$PROJECT" --board "$BOARD" --title "Probe module2" --workspace project --lane todo --provider codex --model "$CODEX_MODEL" --effort low --format id \
    --prompt "Hook probe: do not run any shell commands. Use only your apply_patch tool to add the line '// probe' at the end of src/module2.js. Then reply with one line saying what happened.")
printf 'PROJECT=%s\nBOARD=%s\nA=%s\nB=%s\nDIR=%s\n' "$PROJECT" "$BOARD" "$H" "$W" "$DIR" | tee "$DIR/ids.env"
"$DL" card start "$H" >/dev/null
date -u +"start H %H:%M:%S"
i=0
until "$DL" channel claims --project "$PROJECT" --format json | grep -q module2.js; do
    i=$((i + 1))
    [ $i -gt 60 ] && {
        echo "no claim"
        exit 1
    }
    sleep 1
done
date -u +"H claimed module2 %H:%M:%S"
"$DL" card start "$W" >/dev/null
date -u +"start W %H:%M:%S"

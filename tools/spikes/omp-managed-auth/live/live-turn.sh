#!/usr/bin/env bash
# One real OMP ACP turn on this machine's own logins, the way the managed
# design runs it: a login-free OMP home, credentials only from the
# account-token.mjs `!command` helper, every chat role pinned by a Dieter
# overlay, and Dieter's launch flags. The project directory is a fresh temp
# dir outside any repository, so the turn carries almost no context.
#
#   live-turn.sh <omp> <bun-dir> <work-dir> <main-model> <advisor-model|off>
#
# Environment passed through to the helper: CLAUDE_CONFIG_DIR, CLAUDE_PROBE,
# CODEX_HOME, CODEX_BIN.
set -euo pipefail

OMP=${1:?omp executable}
BUN_DIR=${2:?bun dir}
WORK=${3:?work dir}
MAIN=${4:?main model selector}
ADVISOR=${5:?advisor model selector or off}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
home="$WORK/home" agent="$WORK/agent"
mkdir -p "$home" "$agent"
project=$(mktemp -d "${TMPDIR:-/tmp}/omp-live-project.XXXXXX")
NODE=$(command -v node)

cat >"$agent/models.yml" <<YAML
providers:
  anthropic:
    apiKey: "!'$NODE' '$HERE/account-token.mjs' claude"
  openai-codex:
    apiKey: "!'$NODE' '$HERE/account-token.mjs' codex"
YAML

{
    cat <<YAML
providers:
  streamFirstEventTimeoutSeconds: 1800
  streamIdleTimeoutSeconds: 1800
async:
  enabled: false
bash:
  autoBackground:
    enabled: false
eval:
  autoBackground:
    enabled: false
modelRoles:
YAML
    for role in default smol slow vision plan commit tiny memory task widget; do
        printf '  %s: %s\n' "$role" "$MAIN"
    done
    if [ "$ADVISOR" != off ]; then
        printf '  advisor: %s\nadvisor:\n  enabled: true\n  reviewMode: agent-end\n  syncBacklog: strict\n' "$ADVISOR"
    else
        printf 'advisor:\n  enabled: false\n'
    fi
} >"$WORK/overlay.yml"

status=0
(cd "$project" && env -i \
    HOME="$home" PATH="$BUN_DIR:$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin" TMPDIR="${TMPDIR:-/tmp}" \
    PI_CODING_AGENT_DIR="$agent" \
    TOKEN_HELPER_LOG="$WORK/helper.jsonl" \
    ${CLAUDE_CONFIG_DIR:+CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"} \
    ${CLAUDE_PROBE:+CLAUDE_PROBE="$CLAUDE_PROBE"} \
    ${CODEX_HOME:+CODEX_HOME="$CODEX_HOME"} \
    ${CODEX_BIN:+CODEX_BIN="$CODEX_BIN"} \
    "$NODE" "$HERE/../acp-probe.mjs" "$OMP" "$project" "$WORK/overlay.yml" "$MAIN" low "$WORK/acp.json" \
    </dev/null >"$WORK/stdout.txt" 2>"$WORK/stderr.txt") || status=$?
rmdir "$project" 2>/dev/null || true

{
    echo "main=$MAIN advisor=$ADVISOR exit=$status"
    "$NODE" -e '
      const fs = require("fs");
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const text = r.updates.filter(u => u.kind === "agent_message_chunk").map(u => u.text).join("");
      console.log("acp: status=" + r.status + " stop=" + (r.stopReason ?? "-") + " reply=" + JSON.stringify(text.slice(0, 200)) +
        " kinds=" + JSON.stringify([...new Set(r.updates.map(u => u.kind))]) + (r.error ? " error=" + r.error.slice(0, 400) : ""));
      const usage = r.updates.filter(u => u.kind === "usage_update");
      console.log("usage updates: " + usage.length);
    ' "$WORK/acp.json"
    echo "helper:"
    sed 's/^/  /' "$WORK/helper.jsonl" 2>/dev/null || echo "  (no helper calls)"
} | tee "$WORK/summary.txt"

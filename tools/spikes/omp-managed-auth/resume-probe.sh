#!/usr/bin/env bash
# L5 offline: does a stored OMP session take a new implementation model,
# advisor and provider on its next turn when the launch arguments stay the
# same (`omp acp --config <overlay>`)? Turn 1 runs on Claude; turn 2 loads the
# session with an overlay that names Codex as the implementation model and
# Claude Opus as the advisor, (a) by overlay only and (b) also through the ACP
# `model`/`thinking` options. Fake tokens, loopback upstream.
#
#   resume-probe.sh <omp-executable> <bun-dir> <work-dir>
set -euo pipefail
OMP=${1:?omp executable}
BUN_DIR=${2:?bun dir}
WORK=${3:?work dir}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
LOG="$WORK/upstream.jsonl"
: >"$LOG"
FAKE_UPSTREAM_BODIES="$WORK" node "$HERE/fake-upstream.mjs" "$PORT" "$LOG" 2>"$WORK/upstream.stderr" &
UPSTREAM=$!
trap 'kill $UPSTREAM 2>/dev/null || true' EXIT
sleep 0.5

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
EXP=$(($(date +%s) + 864000))
ANTHROPIC_FAKE="sk-ant-oat01-dieter-spike-$(openssl rand -hex 16)"
CODEX_FAKE="$(printf '{"alg":"none"}' | b64url).$(printf '{"exp":%s,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-dieter-spike"}}' "$EXP" | b64url).sig"

home="$WORK/home" agent="$WORK/agent" project="$WORK/project"
mkdir -p "$home" "$agent" "$project"
cat >"$agent/models.yml" <<YAML
providers:
  anthropic:
    baseUrl: http://127.0.0.1:$PORT
  openai-codex:
    baseUrl: http://127.0.0.1:$PORT/backend-api
YAML

overlay() { # <file> <main> <advisor|off>
    {
        printf 'modelRoles:\n'
        for role in default smol slow vision plan commit tiny memory task widget; do printf '  %s: %s\n' "$role" "$2"; done
        if [ "$3" != off ]; then
            printf '  advisor: %s\nadvisor:\n  enabled: true\n  reviewMode: agent-end\n  syncBacklog: strict\n' "$3"
        else
            printf 'advisor:\n  enabled: false\n'
        fi
    } >"$1"
}

turn() { # <name> <overlay> [load-id] [set]
    local name=$1 file=$2 load=${3:-} set=${4:-} start status=0
    start=$(wc -l <"$LOG")
    (cd "$project" && env -i HOME="$home" PATH="$BUN_DIR:/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
        PI_CODING_AGENT_DIR="$agent" PI_CODEX_WEBSOCKET=0 \
        ANTHROPIC_OAUTH_TOKEN="$ANTHROPIC_FAKE" OPENAI_CODEX_OAUTH_TOKEN="$CODEX_FAKE" \
        ACP_CONSTANT_ARGS=1 ACP_LOAD_SESSION="$load" ACP_SET="$set" \
        "$(command -v node)" "$HERE/acp-probe.mjs" "$OMP" "$project" "$file" unused unused "$WORK/$name.json" \
        </dev/null >"$WORK/$name.stdout" 2>"$WORK/$name.stderr") || status=$?
    sleep 1
    echo "== $name exit=$status load=${load:-new} set=${set:--}"
    tail -n +"$((start + 1))" "$LOG" | node -e '
      let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
        for (const line of s.split("\n").filter(Boolean)) {
          const r = JSON.parse(line);
          if (r.method === "POST") console.log("   ", r.path, r.model, "effort=" + (r.effort ?? "-"));
        }
      });'
    node -e '
      const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const text = r.updates.filter(u => u.kind === "agent_message_chunk").map(u => u.text).join("");
      const model = (r.configOptions ?? []).find(o => o.id === "model");
      console.log("    acp status=" + r.status + " stop=" + (r.stopReason ?? "-") + " reply=" + JSON.stringify(text) +
        " session=" + r.sessionId + " modelOption=" + (model?.current ?? "-") + (r.error ? " error=" + r.error.slice(0, 300) : ""));
    ' "$WORK/$name.json"
}

overlay "$WORK/overlay-1.yml" anthropic/claude-sonnet-5-5:low off
turn t1-claude "$WORK/overlay-1.yml" | tee "$WORK/summary.txt"
SESSION=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sessionId)' "$WORK/t1-claude.json")

overlay "$WORK/overlay-2.yml" openai-codex/gpt-6-sol:high anthropic/claude-opus-5-5
turn t2a-overlay-only "$WORK/overlay-2.yml" "$SESSION" | tee -a "$WORK/summary.txt"
turn t2b-overlay-and-option "$WORK/overlay-2.yml" "$SESSION" "model=openai-codex/gpt-6-sol,thinking=high" | tee -a "$WORK/summary.txt"

# Continuity: does the Codex request of turn 2 carry turn 1's Claude reply?
node -e '
  const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  const codex = lines.map(l => JSON.parse(l)).filter(x => x.path.endsWith("/codex/responses") && x.body?.model === "gpt-6-sol");
  const carried = codex.some(x => JSON.stringify(x.body.input ?? "").includes("ANTHROPIC-MAIN-OK"));
  console.log("history across the provider switch: " + (codex.length ? (carried ? "carried" : "missing") : "no codex main request"));
' "$WORK/bodies.jsonl" | tee -a "$WORK/summary.txt"

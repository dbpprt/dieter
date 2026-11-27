#!/usr/bin/env bash
# Mid-turn refresh probe: credentials come only from `models.yml` `apiKey:
# "!command"` (no env tokens). The first token of each provider is rejected
# with 401; OMP must rerun the helper and retry with the next token.
#
#   refresh-probe.sh <omp-executable> <bun-dir> <work-dir>
set -euo pipefail
OMP=${1:?omp executable}
BUN_DIR=${2:?bun dir}
WORK=${3:?work dir}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
STATE="$WORK/tokens"
mkdir -p "$STATE"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
EXP=$(($(date +%s) + 864000))
for n in 1 2; do
    printf 'sk-ant-oat01-dieter-spike-gen%s-%s' "$n" "$(openssl rand -hex 12)" >"$STATE/anthropic.token.$n"
    printf '%s.%s.sig' "$(printf '{"alg":"none"}' | b64url)" \
        "$(printf '{"exp":%s,"gen":%s,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-dieter-spike"}}' "$EXP" "$n" | b64url)" \
        >"$STATE/codex.token.$n"
done
sha() { shasum -a 256 "$1" | cut -c1-12; }
REJECT="$(sha "$STATE/anthropic.token.1"),$(sha "$STATE/codex.token.1")"
PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
LOG="$WORK/upstream.jsonl"
: >"$LOG"
FAKE_UPSTREAM_REJECT="$REJECT" node "$HERE/fake-upstream.mjs" "$PORT" "$LOG" 2>"$WORK/upstream.stderr" &
UPSTREAM=$!
trap 'kill $UPSTREAM 2>/dev/null || true' EXIT
sleep 0.5

home="$WORK/home" agent="$WORK/agent" project="$WORK/project"
mkdir -p "$home" "$agent" "$project"
cat >"$agent/models.yml" <<YAML
providers:
  anthropic:
    baseUrl: http://127.0.0.1:$PORT
    apiKey: "!'$HERE/token-helper.sh' '$STATE' anthropic"
  openai-codex:
    baseUrl: http://127.0.0.1:$PORT/backend-api
    apiKey: "!'$HERE/token-helper.sh' '$STATE' codex"
YAML
cat >"$WORK/overlay.yml" <<YAML
modelRoles:
  advisor: openai-codex/gpt-6-sol
$(for role in default smol slow vision plan commit tiny memory task widget; do printf '  %s: anthropic/claude-sonnet-5-5\n' "$role"; done)
advisor:
  enabled: true
  reviewMode: agent-end
  syncBacklog: strict
YAML
status=0
(cd "$project" && env -i HOME="$home" PATH="$BUN_DIR:/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    PI_CODING_AGENT_DIR="$agent" PI_CODEX_WEBSOCKET=0 \
    "$(command -v node)" "$HERE/acp-probe.mjs" "$OMP" "$project" "$WORK/overlay.yml" anthropic/claude-sonnet-5-5 high "$WORK/acp.json" \
    </dev/null >"$WORK/stdout.txt" 2>"$WORK/stderr.txt") || status=$?
sleep 1
{
    echo "exit $status; helper calls: anthropic=$(cat "$STATE/anthropic.calls" 2>/dev/null || echo 0) codex=$(cat "$STATE/codex.calls" 2>/dev/null || echo 0)"
    node -e '
    const fs = require("fs");
    const [log, state] = process.argv.slice(1);
    const crypto = require("crypto");
    const names = {};
    for (const f of fs.readdirSync(state).filter(f => f.includes(".token."))) {
      names[crypto.createHash("sha256").update(fs.readFileSync(state + "/" + f)).digest("hex").slice(0, 12)] = f;
    }
    for (const line of fs.readFileSync(log, "utf8").split("\n").filter(Boolean)) {
      const r = JSON.parse(line);
      if (r.method !== "POST") continue;
      console.log("  ", r.path, r.model, "token=" + (names[r.authorization?.sha256] ?? "?"));
    }
    const acp = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
    const text = acp.updates.filter(u => u.kind === "agent_message_chunk").map(u => u.text).join("");
    console.log("   acp: status=" + acp.status + " stop=" + (acp.stopReason ?? "-") + " reply=" + JSON.stringify(text) + (acp.error ? " error=" + acp.error : ""));
  ' "$LOG" "$STATE" "$WORK/acp.json"
} | tee "$WORK/summary.txt"

#!/usr/bin/env bash
# Offline probe: does OMP run its main role and its advisor role on two
# different subscription credentials that Dieter injects per process, with
# models chosen by Dieter instead of OMP's own config?
#
# Everything runs in a throwaway HOME and OMP agent dir with fake tokens. The
# fake upstream (fake-upstream.mjs) stands in for api.anthropic.com and
# chatgpt.com/backend-api, so no request carries a real credential.
#
#   probe.sh <omp-executable> <bun-dir> <work-dir>
set -euo pipefail

OMP=${1:?omp executable}
BUN_DIR=${2:?directory containing bun >= 1.4.4}
WORK=${3:?empty work directory}
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

# Fake credentials in the shapes OMP expects: an Anthropic OAuth access token
# (sk-ant-oat prefix selects Claude Code request shaping) and a ChatGPT access
# JWT whose claim carries the account id OMP sends as chatgpt-account-id.
ANTHROPIC_FAKE="sk-ant-oat01-dieter-spike-$(openssl rand -hex 16)"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
EXP=$(($(date +%s) + 864000))
CODEX_FAKE="$(printf '{"alg":"none","typ":"JWT"}' | b64url).$(printf '{"exp":%s,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-dieter-spike","chatgpt_plan_type":"pro"}}' "$EXP" | b64url).sig"
printf '%s' "$ANTHROPIC_FAKE" | shasum -a 256 | cut -c1-12 >"$WORK/anthropic-token.sha"
printf '%s' "$CODEX_FAKE" | shasum -a 256 | cut -c1-12 >"$WORK/codex-token.sha"

run_scenario() {
    local name=$1 mode=$2 main=$3 advisor=$4 user_advisor=${5:-} pin_roles=${6:-}
    local home="$WORK/$name/home" agent="$WORK/$name/agent" project="$WORK/$name/project"
    mkdir -p "$home" "$agent" "$project"
    # Route both subscription providers to the loopback upstream. A real turn
    # omits this file; it is the only difference from production routing.
    cat >"$agent/models.yml" <<YAML
providers:
  anthropic:
    baseUrl: http://127.0.0.1:$PORT
  openai-codex:
    baseUrl: http://127.0.0.1:$PORT/backend-api
YAML
    # Optional user-level OMP config that picks a different advisor, to check
    # that Dieter's per-turn overlay wins over OMP's own model configuration.
    if [ -n "$user_advisor" ]; then
        printf 'modelRoles:\n  advisor: %s\n  default: %s\n' "$user_advisor" "$user_advisor" >"$agent/config.yml"
    fi
    # The per-turn overlay Dieter would write: today's runtime settings
    # (ompRuntimeConfig) plus the advisor role, so OMP's config never picks.
    cat >"$WORK/$name/dieter-overlay.yml" <<YAML
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
  advisor: $advisor
$(if [ -n "$pin_roles" ]; then for role in default smol slow vision plan commit tiny memory task widget; do printf '  %s: %s\n' "$role" "$main"; done; fi)
advisor:
  enabled: true
  reviewMode: agent-end
  syncBacklog: strict
YAML
    echo "== $name ($mode): main=$main advisor=$advisor${user_advisor:+ user-config-advisor=$user_advisor}" | tee -a "$WORK/summary.txt"
    local start status
    start=$(wc -l <"$LOG")
    local env_args=(
        HOME="$home"
        PATH="$BUN_DIR:/usr/bin:/bin"
        TMPDIR="${TMPDIR:-/tmp}"
        PI_CODING_AGENT_DIR="$agent"
        PI_CODEX_WEBSOCKET=0
        ANTHROPIC_OAUTH_TOKEN="$ANTHROPIC_FAKE"
        OPENAI_CODEX_OAUTH_TOKEN="$CODEX_FAKE"
    )
    if [ "$mode" = print ]; then
        (cd "$project" && env -i "${env_args[@]}" "$OMP" -p "Reply with the single word OK." \
            --model "$main" --advisor --config "$WORK/$name/dieter-overlay.yml" --no-extensions \
            </dev/null >"$WORK/$name/stdout.txt" 2>"$WORK/$name/stderr.txt") && status=0 || status=$?
    else
        (cd "$project" && env -i "${env_args[@]}" "$(command -v node)" "$HERE/acp-probe.mjs" "$OMP" "$project" \
            "$WORK/$name/dieter-overlay.yml" "$main" high "$WORK/$name/acp.json" \
            </dev/null >"$WORK/$name/stdout.txt" 2>"$WORK/$name/stderr.txt") && status=0 || status=$?
    fi
    echo "exit $status" | tee -a "$WORK/summary.txt"
    sleep 1
    tail -n +"$((start + 1))" "$LOG" >"$WORK/$name/requests.jsonl"
    node -e '
    const fs = require("fs");
    const [file, aSha, cSha, main, advisor] = process.argv.slice(1);
    const id = (selector) => selector.split("/").pop();
    for (const line of fs.readFileSync(file, "utf8").split("\n").filter(Boolean)) {
      const r = JSON.parse(line);
      const sha = r.authorization?.sha256 ?? r.xApiKey?.sha256;
      const cred = sha === aSha ? "anthropic-token" : sha === cSha ? "codex-token" : sha ? "other" : "none";
      const role = r.model === id(main) ? "main" : r.model === id(advisor.split(":")[0]) ? "advisor" : r.model ? "unexpected" : "-";
      console.log(["  ", r.method, r.path, "role=" + role, r.model ?? "-", "effort=" + (r.effort ?? "-"), "cred=" + cred,
        r.chatgptAccountId ? "acct=" + r.chatgptAccountId : "", r.userAgent ?? ""].join("  "));
    }' "$WORK/$name/requests.jsonl" "$(cat "$WORK/anthropic-token.sha")" "$(cat "$WORK/codex-token.sha")" "$main" "$advisor" | tee -a "$WORK/summary.txt"
    if [ "$mode" = print ]; then
        echo "   reply: $(head -c 200 "$WORK/$name/stdout.txt")" | tee -a "$WORK/summary.txt"
    else
        node -e '
      const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const text = r.updates.filter(u => u.kind === "agent_message_chunk").map(u => u.text).join("");
      console.log("   acp: status=" + r.status + " stop=" + (r.stopReason ?? "-") + " reply=" + JSON.stringify(text) +
        " updates=" + JSON.stringify([...new Set(r.updates.map(u => u.kind))]) + (r.error ? " error=" + r.error : ""));
    ' "$WORK/$name/acp.json" | tee -a "$WORK/summary.txt"
    fi
}

run_scenario print-claude-main-codex-advisor print anthropic/claude-sonnet-5-5 openai-codex/gpt-6-sol
run_scenario print-codex-main-claude-advisor print openai-codex/gpt-6-sol anthropic/claude-opus-5-5
run_scenario acp-claude-main-codex-advisor acp anthropic/claude-opus-5-5 openai-codex/gpt-6-luna
run_scenario acp-codex-main-claude-advisor acp openai-codex/gpt-6-sol anthropic/claude-sonnet-5-5
run_scenario acp-overlay-beats-user-config acp openai-codex/gpt-6-sol anthropic/claude-opus-5-5 openai-codex/gpt-6-astra
run_scenario acp-pinned-roles-advisor-effort acp anthropic/claude-sonnet-5-5 openai-codex/gpt-6-sol:low "" pin

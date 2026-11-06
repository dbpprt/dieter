#!/bin/sh
# Phase D: an isolated development daemon with the spike clone view and turn
# snapshots enabled. Credentials: copied Codex home (refresh token neutered)
# and the current Claude access token only. phase-d-serve.sh PORT
set -eu
PD=/Volumes/External/dieter-spike/phase-d
unset DIETER_TURN_TOKEN DIETER_CARD_ID ANTHROPIC_API_KEY
export DIETER_HOME=$PD/home DIETER_SPIKE_WORKSPACE_VIEW=clone DIETER_SPIKE_TURN_SNAPSHOTS=1
export CODEX_HOME=$PD/codex-home CLAUDE_CONFIG_DIR=$PD/claude-config
mkdir -p "$DIETER_HOME" "$CLAUDE_CONFIG_DIR"
if [ ! -f "$CODEX_HOME/auth.json" ]; then
    mkdir -p "$CODEX_HOME"
    chmod 700 "$CODEX_HOME"
    cp /Volumes/External/dieter-spike/mac.noindex/codex/clone/codex-home/auth.json "$CODEX_HOME/auth.json"
    chmod 600 "$CODEX_HOME/auth.json"
    printf 'model = "gpt-6-astra"\nmodel_reasoning_effort = "low"\ncli_auth_credentials_store = "file"\n' >"$CODEX_HOME/config.toml"
fi
CLAUDE_CODE_OAUTH_TOKEN=$(perl -e 'alarm 25; exec @ARGV' security find-generic-password -s "Claude Code-credentials" -a "$USER" -w | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
export CLAUDE_CODE_OAUTH_TOKEN
exec /Volumes/External/dieter-spike/phase-d-bin/dieter serve --verbose --addr "127.0.0.1:$1"

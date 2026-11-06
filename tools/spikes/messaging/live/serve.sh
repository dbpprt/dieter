#!/bin/sh
# serve.sh LIVE_ROOT PORT: isolated working-tree daemon for the live
# agent-channels test. Temp HOME, DIETER_HOME, CODEX_HOME and CLAUDE_CONFIG_DIR;
# only the current Claude access token is passed (never the refresh token).
set -eu
ROOT=${1:?LIVE_ROOT}
PORT=${2:?PORT}
REPO=$(cd "$(dirname "$0")/../../../.." && pwd)
NODE_BIN=$(dirname "$(mise exec -- which node)")
# Read the access token while HOME is still the operator's (keychain search list).
CLAUDE_CODE_OAUTH_TOKEN=$(perl -e 'alarm 25; exec @ARGV' security find-generic-password -s "Claude Code-credentials" -a "$USER" -w | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
export CLAUDE_CODE_OAUTH_TOKEN
unset DIETER_TURN_TOKEN DIETER_CARD_ID ANTHROPIC_API_KEY OPENAI_API_KEY
export DIETER_HOME="$ROOT/home" HOME="$ROOT/user-home"
export CODEX_HOME="$ROOT/codex-home" CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DIETER_HARNESS_RUNTIME_DIR="$REPO/internal/harness/runtime"
export PATH="$REPO/bin:$NODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
echo "serve: dieter=$(command -v dieter) node=$(command -v node) HOME=$HOME DIETER_HOME=$DIETER_HOME"
exec "$REPO/bin/dieter" serve --verbose --addr "127.0.0.1:$PORT" >>"$ROOT/daemon.log" 2>&1

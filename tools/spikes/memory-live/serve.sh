#!/bin/sh
# serve.sh NAME PORT: an isolated working-tree daemon for the agent memory
# live test, on /tmp/dieter-mem-live/NAME. It keeps the operator's HOME so the
# accounts engine adopts the host's own Claude Code login (method host, auth
# {}): Claude Code alone reads and refreshes it. Codex is hidden behind an
# empty CODEX_HOME so no stale host login is adopted or refreshed.
set -eu
NAME=${1:?NAME}
PORT=${2:?PORT}
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
NODE_BIN=$(dirname "$(mise exec -- which node)")
for v in $(env | grep -o '^DIETER_[A-Z_]*') $(env | grep -o '^CLAUDE[A-Z_]*') ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY CODEX_API_KEY; do unset "$v" 2>/dev/null || true; done
mkdir -p /tmp/dieter-mem-live/no-codex
export DIETER_HOME=/tmp/dieter-mem-live/$NAME
export CODEX_HOME=/tmp/dieter-mem-live/no-codex
export DIETER_HARNESS_RUNTIME_DIR="$REPO/internal/harness/runtime"
export PATH="$REPO/bin:$NODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
echo "serve: $(command -v dieter) node=$(command -v node) DIETER_HOME=$DIETER_HOME"
exec "$REPO/bin/dieter" serve --verbose --addr "127.0.0.1:$PORT"

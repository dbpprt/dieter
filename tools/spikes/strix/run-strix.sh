#!/bin/sh
# Launch Strix headless the way a Dieter harness worker would:
#   - the state root stands in for DIETER_HOME/runtime/harness/strix/<session>
#   - cwd = state root, so strix_runs/ never lands in the project checkout
#   - HOME = state root/home, so ~/.strix (config, update cache) is isolated
#   - telemetry and update checks are off
#
# Usage: run-strix.sh SESSION [strix args...]
#   STRIX_BIN, SPIKE_ROOT, DOCKER_HOST, STRIX_LLM, LLM_API_BASE, LLM_API_KEY
#   may be overridden; defaults target the scripted fake model.
set -eu
session=$1
shift
SPIKE_ROOT=${SPIKE_ROOT:-/Volumes/External/strix-spike}
state="$SPIKE_ROOT/state/$session"
mkdir -p "$state/home"
cd "$state"

export HOME="$state/home"
export STRIX_TELEMETRY=0
export STRIX_NO_UPDATE_CHECK=1
export DOCKER_HOST=${DOCKER_HOST:-unix://$SPIKE_ROOT/colima/strix-spike/docker.sock}
if [ -z "${STRIX_LLM:-}" ]; then
    # The scripted model (fake-llm.mjs); a real model brings its own settings.
    export STRIX_LLM=openai/fake-model
    export STRIX_API_TYPE=chat_completions
    export LLM_API_BASE=${LLM_API_BASE:-http://127.0.0.1:47811/v1}
    export LLM_API_KEY=sk-spike-dummy-not-a-secret
    export STRIX_LLM_INPUT_COST_PER_MTOK=1
    export STRIX_LLM_OUTPUT_COST_PER_MTOK=4
fi

STRIX_BIN=${STRIX_BIN:-$SPIKE_ROOT/bin/strix-1.7.1-macos-arm64}
echo "spike: state=$state" >&2
start=$(date +%s)
set +e
"$STRIX_BIN" "$@"
code=$?
set -e
echo "spike: exit=$code seconds=$(($(date +%s) - start))" >&2
exit $code

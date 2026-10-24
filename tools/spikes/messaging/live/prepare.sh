#!/bin/sh
# prepare.sh LIVE_ROOT: temp homes for the live agent-channels test.
# Codex: copy of ~/.codex/auth.json with the refresh token neutered.
# Claude: a fresh CLAUDE_CONFIG_DIR (serve.sh passes only the access token).
set -eu
ROOT=${1:?LIVE_ROOT}
mkdir -p "$ROOT/home" "$ROOT/user-home" "$ROOT/claude-config" "$ROOT/codex-home"
chmod 700 "$ROOT" "$ROOT/codex-home" "$ROOT/claude-config" "$ROOT/user-home"
python3 -I - "$ROOT/codex-home/auth.json" <<'PY'
import json, os, sys
a = json.load(open(os.path.expanduser("~/.codex/auth.json")))
a["tokens"]["refresh_token"] = "spike-no-refresh"
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(a, f)
PY
MODEL=$(sed -n 's/^model *= *"\(.*\)"/\1/p' "$HOME/.codex/config.toml" | head -1)
printf 'model = "%s"\nmodel_reasoning_effort = "low"\ncli_auth_credentials_store = "file"\n' "$MODEL" >"$ROOT/codex-home/config.toml"
printf '[user]\n\tname = live-test\n\temail = live-test@example.invalid\n[init]\n\tdefaultBranch = main\n' >"$ROOT/user-home/.gitconfig"
# Login shells (Codex runs /bin/zsh -lc) rebuild PATH with path_helper, which
# puts /opt/homebrew/bin (an older released dieter) ahead of the daemon's PATH.
# ~/.zprofile runs after path_helper, so it restores the working-tree CLI.
REPO=$(cd "$(dirname "$0")/../../../.." && pwd)
# NO_PATH_FIX=1 leaves path_helper's order alone: the turn instructions name
# the daemon's binary by absolute path, which a verification run checks.
if [ -n "${NO_PATH_FIX:-}" ]; then
    echo "codex model: $MODEL (no PATH workaround)"
    exit 0
fi
printf 'export PATH="%s/bin:$PATH"\n' "$REPO" >"$ROOT/user-home/.zprofile"
# Claude Code's Bash is a non-interactive login zsh that sources ~/.zshenv but
# not ~/.zprofile, and path_helper runs after ~/.zshenv: only a function wins.
printf 'dieter() { "%s/bin/dieter" "$@"; }\n' "$REPO" >"$ROOT/user-home/.zshenv"
echo "codex model: $MODEL"

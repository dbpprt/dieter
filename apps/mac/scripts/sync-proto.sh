#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
python3 "$REPO_ROOT/scripts/sync_apple_proto.py"
if ! "$SCRIPT_DIR/generate-swift-proto.sh" --check; then
    "$SCRIPT_DIR/generate-swift-proto.sh"
fi

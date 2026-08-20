#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
SOURCE_PROTO="$REPO_ROOT/api/proto/nauclio/v1/nauclio.proto"
TARGET_PROTO="$APP_ROOT/Sources/NauclioAPI/nauclio.proto"

if ! cmp -s "$SOURCE_PROTO" "$TARGET_PROTO"; then
    cp "$SOURCE_PROTO" "$TARGET_PROTO"
    echo "Synced nauclio.proto"
fi

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
CHANGED=0

sync_proto() {
    SOURCE_PROTO=$1
    TARGET_PROTO=$2
    if ! cmp -s "$SOURCE_PROTO" "$TARGET_PROTO"; then
        cp "$SOURCE_PROTO" "$TARGET_PROTO"
        echo "Synced $(basename "$TARGET_PROTO")"
        CHANGED=1
    fi
}

sync_proto \
    "$REPO_ROOT/api/proto/nauclio/v1/nauclio.proto" \
    "$APP_ROOT/Sources/NauclioAPI/nauclio.proto"
sync_proto \
    "$REPO_ROOT/api/proto/nauclio/gateway/v1/gateway.proto" \
    "$APP_ROOT/Sources/NauclioAPI/gateway.proto"

if [ "$CHANGED" -eq 1 ] || ! "$SCRIPT_DIR/generate-swift-proto.sh" --check; then
    "$SCRIPT_DIR/generate-swift-proto.sh"
fi

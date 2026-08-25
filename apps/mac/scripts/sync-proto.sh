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

sync_dieter_proto() {
	SOURCE_PROTO=$1
	TARGET_PROTO=$2
	TEMPORARY=$(mktemp "${TMPDIR:-/tmp}/dieter-mac-proto.XXXXXX")
	trap 'rm -f "$TEMPORARY"' EXIT INT TERM
	# The Swift package keeps both schema inputs in one directory, while the
	# repository's authoritative protobuf tree uses its canonical import path.
	sed 's#import "dieter/gateway/v1/gateway.proto";#import "gateway.proto";#' "$SOURCE_PROTO" >"$TEMPORARY"
	if ! cmp -s "$TEMPORARY" "$TARGET_PROTO"; then
		cp "$TEMPORARY" "$TARGET_PROTO"
		echo "Synced $(basename "$TARGET_PROTO")"
		CHANGED=1
	fi
	rm -f "$TEMPORARY"
	trap - EXIT INT TERM
}

sync_dieter_proto \
    "$REPO_ROOT/api/proto/dieter/v1/dieter.proto" \
    "$APP_ROOT/Sources/DieterAPI/dieter.proto"
sync_proto \
    "$REPO_ROOT/api/proto/dieter/gateway/v1/gateway.proto" \
    "$APP_ROOT/Sources/DieterAPI/gateway.proto"

if [ "$CHANGED" -eq 1 ] || ! "$SCRIPT_DIR/generate-swift-proto.sh" --check; then
    "$SCRIPT_DIR/generate-swift-proto.sh"
fi

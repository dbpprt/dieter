#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SWIFT_SCRATCH_PATH=${NAUCLIO_SWIFT_SCRATCH_PATH:-$APP_ROOT/.build/nauclio-local}

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <build|test> [arguments...]" >&2
    exit 2
fi

COMMAND=$1
shift
set -- \
    "$COMMAND" \
    --package-path "$APP_ROOT" \
    --scratch-path "$SWIFT_SCRATCH_PATH" \
    --only-use-versions-from-resolved-file \
    --manifest-cache local \
    --disable-index-store \
    "$@"
exec swift "$@"

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GENERATED_DIR="$APP_ROOT/Sources/DieterAPI/Generated"
MANIFEST="$GENERATED_DIR/.inputs.sha256"

generated_files_exist() {
    [ -f "$GENERATED_DIR/gateway.grpc.swift" ] &&
        [ -f "$GENERATED_DIR/gateway.pb.swift" ] &&
        [ -f "$GENERATED_DIR/dieter.grpc.swift" ] &&
        [ -f "$GENERATED_DIR/dieter.pb.swift" ]
}

write_manifest() {
    DESTINATION=$1
    (
        cd "$APP_ROOT"
        INPUT_DIGEST=$(shasum -a 256 \
            Package.resolved \
            Sources/DieterAPI/gateway.proto \
            Sources/DieterAPI/dieter.proto \
            Sources/DieterAPI/grpc-swift-proto-generator-config.json | shasum -a 256 | awk '{print $1}')
        printf 'inputs  %s\n' "$INPUT_DIGEST"
        shasum -a 256 \
            Sources/DieterAPI/Generated/gateway.grpc.swift \
            Sources/DieterAPI/Generated/gateway.pb.swift \
            Sources/DieterAPI/Generated/dieter.grpc.swift \
            Sources/DieterAPI/Generated/dieter.pb.swift
    ) >"$DESTINATION"
}

if [ "${1:-}" = "--check" ]; then
    if [ ! -f "$MANIFEST" ] || ! generated_files_exist; then
        exit 1
    fi
    EXPECTED_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-swift-proto.XXXXXX")
    trap 'rm -f "$EXPECTED_MANIFEST"' EXIT INT TERM
    write_manifest "$EXPECTED_MANIFEST"
    cmp -s "$EXPECTED_MANIFEST" "$MANIFEST"
    exit
fi

if [ "$#" -ne 0 ]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

mkdir -p "$GENERATED_DIR"
rm -f \
    "$GENERATED_DIR/Sources_DieterAPI_gateway.grpc.swift" \
    "$GENERATED_DIR/Sources_DieterAPI_gateway.pb.swift" \
    "$GENERATED_DIR/Sources_DieterAPI_dieter.grpc.swift" \
    "$GENERATED_DIR/Sources_DieterAPI_dieter.pb.swift"
(
    cd "$APP_ROOT/Sources/DieterAPI"
    swift package \
        --package-path "$APP_ROOT" \
        --only-use-versions-from-resolved-file \
        --allow-writing-to-package-directory \
        generate-grpc-code-from-protos \
        --no-servers \
        --clients \
        --messages \
        --access-level public \
        --file-naming pathToUnderscores \
        --output-path Generated \
        -- \
        gateway.proto \
        dieter.proto
)

NEW_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-swift-proto.XXXXXX")
trap 'rm -f "$NEW_MANIFEST"' EXIT INT TERM
write_manifest "$NEW_MANIFEST"
mv "$NEW_MANIFEST" "$MANIFEST"
trap - EXIT INT TERM
echo "Generated cached Swift protobuf and gRPC sources"

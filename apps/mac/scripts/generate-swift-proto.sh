#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APP_ROOT/../.." && pwd)
GENERATED_DIR="$APP_ROOT/Sources/DieterAPI/Generated"
MANIFEST="$GENERATED_DIR/.inputs.sha256"
SWIFT_SCRATCH_PATH=${DIETER_SWIFT_SCRATCH_PATH:-$APP_ROOT/.build/dieter-local}

# The shared core's UI contract (messages only), copied by sync_apple_proto.py.
client_schemas() {
    (cd "$APP_ROOT/Sources/DieterAPI" && find client -name '*.proto' 2>/dev/null | sort)
}

client_outputs() {
    client_schemas | sed -e 's|/|_|g' -e 's|\.proto$|.pb.swift|'
}

generated_files_exist() {
    [ -f "$GENERATED_DIR/gateway.grpc.swift" ] &&
        [ -f "$GENERATED_DIR/gateway.pb.swift" ] &&
        [ -f "$GENERATED_DIR/dieter.grpc.swift" ] &&
        [ -f "$GENERATED_DIR/dieter.pb.swift" ] || return 1
    for output in $(client_outputs); do
        [ -f "$GENERATED_DIR/$output" ] || return 1
    done
}

write_manifest() {
    DESTINATION=$1
    (
        cd "$APP_ROOT"
        INPUT_DIGEST=$(
            {
                shasum -a 256 \
                    Package.resolved \
                    scripts/generate-swift-proto.sh \
                    ../../scripts/sync_apple_proto.py \
                    Sources/DieterAPI/gateway.proto \
                    Sources/DieterAPI/dieter.proto \
                    Sources/DieterAPI/grpc-swift-proto-generator-config.json
                for schema in $(client_schemas); do shasum -a 256 "Sources/DieterAPI/$schema"; done
            } | shasum -a 256 | awk '{print $1}'
        )
        printf 'inputs  %s\n' "$INPUT_DIGEST"
        shasum -a 256 \
            Sources/DieterAPI/Generated/gateway.grpc.swift \
            Sources/DieterAPI/Generated/gateway.pb.swift \
            Sources/DieterAPI/Generated/dieter.grpc.swift \
            Sources/DieterAPI/Generated/dieter.pb.swift
        for output in $(client_outputs); do shasum -a 256 "Sources/DieterAPI/Generated/$output"; done
    ) >"$DESTINATION"
}

if [ "${1:-}" = "--check" ]; then
    python3 "$REPO_ROOT/scripts/sync_apple_proto.py" --check
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

python3 "$REPO_ROOT/scripts/sync_apple_proto.py"
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
        --scratch-path "$SWIFT_SCRATCH_PATH" \
        --only-use-versions-from-resolved-file \
        --disable-index-store \
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
        dieter.proto \
        $(client_schemas)
)
# The client schema has no services, so its (empty) gRPC files are dropped.
rm -f "$GENERATED_DIR"/client_*.grpc.swift
# A client schema removed from the core leaves no stale generated file.
for generated in "$GENERATED_DIR"/client_*.pb.swift; do
    [ -e "$generated" ] || continue
    client_outputs | grep -qx "$(basename "$generated")" || rm -f "$generated"
done

NEW_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/dieter-swift-proto.XXXXXX")
trap 'rm -f "$NEW_MANIFEST"' EXIT INT TERM
write_manifest "$NEW_MANIFEST"
mv "$NEW_MANIFEST" "$MANIFEST"
trap - EXIT INT TERM
echo "Generated cached Swift protobuf and gRPC sources"

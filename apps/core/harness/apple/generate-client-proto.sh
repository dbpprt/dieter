#!/bin/sh
# Regenerates Sources/DieterMessages/client.pb.swift from the core's UI
# contract (model/src/commonMain/proto/dieter/client/v1/client.proto) with the
# swift-protobuf version pinned in Package.resolved. Requires protoc.
set -eu

HARNESS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE=$(CDPATH= cd -- "$HARNESS/../.." && pwd)
REPO=$(CDPATH= cd -- "$CORE/../.." && pwd)
SCRATCH="$HARNESS/.build/protoc-gen-swift"

cd "$HARNESS"
[ -f Package.resolved ] || cp "$REPO/apps/mac/Package.resolved" Package.resolved
swift package resolve --only-use-versions-from-resolved-file >/dev/null
swift build --package-path .build/checkouts/swift-protobuf --scratch-path "$SCRATCH" -c release --product protoc-gen-swift >/dev/null
protoc --plugin=protoc-gen-swift="$SCRATCH/release/protoc-gen-swift" \
    -I "$CORE/model/src/commonMain/proto" -I "$REPO/api/proto" \
    --swift_out="$HARNESS/Sources/DieterMessages" --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
    dieter/client/v1/client.proto

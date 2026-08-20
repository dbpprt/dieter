#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tool_root="$(mktemp -d /tmp/nauclio-protoc.XXXXXX)"
trap 'rm -rf "$tool_root"' EXIT

GOBIN="$tool_root" go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
GOBIN="$tool_root" go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
GOBIN="$tool_root" go install connectrpc.com/connect/cmd/protoc-gen-connect-go@v1.20.0
PATH="$tool_root:$PATH" protoc \
  --proto_path="$repo_root/api/proto" \
  --go_out="$repo_root" --go_opt=module=github.com/dbpprt/nauclio \
  --go-grpc_out="$repo_root" --go-grpc_opt=module=github.com/dbpprt/nauclio \
  --connect-go_out="$repo_root" --connect-go_opt=module=github.com/dbpprt/nauclio \
  "$repo_root/api/proto/nauclio/v1/nauclio.proto" \
  "$repo_root/api/proto/nauclio/gateway/v1/gateway.proto"

cp "$repo_root/api/proto/nauclio/v1/nauclio.proto" "$repo_root/apps/mac/Sources/NauclioAPI/nauclio.proto"
cp "$repo_root/api/proto/nauclio/gateway/v1/gateway.proto" "$repo_root/apps/mac/Sources/NauclioAPI/gateway.proto"

gofmt -w "$repo_root/internal/gen/nauclio"

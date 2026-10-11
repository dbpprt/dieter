#!/usr/bin/env bash
# Checks (default) or rewrites (--write) the formatting of the Apple clients'
# hand-written Swift with the pinned rules in apps/apple/.swift-format.
set -euo pipefail
cd "$(dirname "$0")/../../.."
mode="${1:---check}"
arguments=(--configuration apps/apple/.swift-format --recursive)
case "$mode" in
    --write) command=(format --in-place) ;;
    --check) command=(lint --strict) ;;
    *)
        echo "Usage: $0 [--check|--write]" >&2
        exit 2
        ;;
esac
# These roots deliberately exclude generated clients, binary artifacts and third_party.
xcrun swift-format "${command[@]}" "${arguments[@]}" \
    apps/apple/DieterKit/Package.swift \
    apps/apple/DieterKit/Sources/DieterTransport apps/apple/DieterKit/Sources/DieterPlatform \
    apps/apple/DieterKit/Tests \
    apps/apple/mac/Package.swift apps/apple/mac/Sources apps/apple/mac/Tests \
    apps/apple/ios/Host/Package.swift apps/apple/ios/Host/Sources \
    apps/apple/ios/App apps/apple/ios/Share

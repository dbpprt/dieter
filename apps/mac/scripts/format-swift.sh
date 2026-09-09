#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mode="${1:---check}"
arguments=(--configuration apps/mac/.swift-format --recursive)
case "$mode" in
    --write) command=(format --in-place) ;;
    --check) command=(lint --strict) ;;
    *) echo "Usage: $0 [--check|--write]" >&2; exit 2 ;;
esac
# These roots deliberately exclude generated clients, binary artifacts and Vendor.
xcrun swift-format "${command[@]}" "${arguments[@]}" \
    apps/mac/Package.swift \
    apps/mac/Sources/DieterCore apps/mac/Sources/DieterClient apps/mac/Sources/DieterMac \
    apps/mac/Tests apps/mac/Tools

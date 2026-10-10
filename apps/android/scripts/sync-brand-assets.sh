#!/usr/bin/env bash
set -euo pipefail

android_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$android_root/../.." && pwd)"
brand_root="$repository_root/assets/brand"
resource_root="$android_root/app/src/main/res"
work_root="$(mktemp -d /tmp/dieter-android-brand.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT

if ! command -v sips >/dev/null 2>&1; then
    echo "sips is required to regenerate the committed Android brand resources" >&2
    exit 1
fi

mkdir -p "$resource_root/drawable-nodpi"

# The themed-icon layer of the monochrome launcher icon.
sips -s format png "$brand_root/assets/svg/mark-mono-light.svg" \
    --out "$work_root/ic_dieter_monochrome-1024.png" >/dev/null
sips -z 1024 1024 "$work_root/ic_dieter_monochrome-1024.png" \
    --out "$resource_root/drawable-nodpi/ic_dieter_monochrome.png" >/dev/null

echo "Android brand resources synchronized from $brand_root"

#!/usr/bin/env bash
set -euo pipefail

android_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$android_root/../.." && pwd)"
brand_root="$repository_root/assets/brand"
resource_root="$android_root/app/src/main/res"
work_root="$(mktemp -d /tmp/nauclio-android-brand.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT

if ! command -v sips >/dev/null 2>&1; then
  echo "sips is required to regenerate the committed Android brand resources" >&2
  exit 1
fi

mkdir -p \
  "$resource_root/drawable-nodpi" \
  "$resource_root/mipmap-mdpi" \
  "$resource_root/mipmap-hdpi" \
  "$resource_root/mipmap-xhdpi" \
  "$resource_root/mipmap-xxhdpi" \
  "$resource_root/mipmap-xxxhdpi"

sips -s format png "$brand_root/assets/svg/mark.svg" \
  --out "$resource_root/drawable-nodpi/ic_nauclio_foreground.png" >/dev/null
sips -s format png "$brand_root/assets/svg/mark-mono-light.svg" \
  --out "$work_root/ic_nauclio_monochrome-1024.png" >/dev/null
sips -z 1024 1024 "$work_root/ic_nauclio_monochrome-1024.png" \
  --out "$resource_root/drawable-nodpi/ic_nauclio_monochrome.png" >/dev/null
sips -z 192 192 "$work_root/ic_nauclio_monochrome-1024.png" \
  --out "$resource_root/drawable-nodpi/ic_notification.png" >/dev/null

while read -r density pixels; do
  sips -z "$pixels" "$pixels" "$brand_root/assets/png/app-icon-dark-1024.png" \
    --out "$resource_root/mipmap-$density/ic_launcher.png" >/dev/null
done <<'SIZES'
mdpi 48
hdpi 72
xhdpi 96
xxhdpi 144
xxxhdpi 192
SIZES

echo "Android brand resources synchronized from $brand_root"

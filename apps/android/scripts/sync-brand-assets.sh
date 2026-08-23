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

mkdir -p \
  "$resource_root/drawable-nodpi" \
  "$resource_root/font" \
  "$resource_root/mipmap-mdpi" \
  "$resource_root/mipmap-hdpi" \
  "$resource_root/mipmap-xhdpi" \
  "$resource_root/mipmap-xxhdpi" \
  "$resource_root/mipmap-xxxhdpi"

sips -s format png "$brand_root/assets/svg/mark.svg" \
  --out "$resource_root/drawable-nodpi/ic_dieter_foreground.png" >/dev/null
sips -s format png "$brand_root/assets/svg/mark-mono-light.svg" \
  --out "$work_root/ic_dieter_monochrome-1024.png" >/dev/null
sips -z 1024 1024 "$work_root/ic_dieter_monochrome-1024.png" \
  --out "$resource_root/drawable-nodpi/ic_dieter_monochrome.png" >/dev/null
sips -z 192 192 "$work_root/ic_dieter_monochrome-1024.png" \
  --out "$resource_root/drawable-nodpi/ic_notification.png" >/dev/null

cp "$brand_root/assets/fonts/Sora-Variable.ttf" "$resource_root/font/sora_variable.ttf"

for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp "$brand_root/assets/android/mipmap-$density/ic_launcher.png" \
    "$resource_root/mipmap-$density/ic_launcher.png"
done

echo "Android brand resources synchronized from $brand_root"

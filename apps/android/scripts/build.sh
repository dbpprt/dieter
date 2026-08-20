#!/usr/bin/env bash
set -euo pipefail

android_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
java_root="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

if [[ ! -x "$sdk_root/platform-tools/adb" ]]; then
  echo "Android SDK not found at $sdk_root" >&2
  exit 1
fi
if [[ ! -x "$java_root/bin/java" ]]; then
  echo "JDK not found at $java_root" >&2
  exit 1
fi

ANDROID_HOME="$sdk_root" JAVA_HOME="$java_root" "$android_root/gradlew" \
  --project-dir "$android_root" :app:assembleDebug :app:testDebugUnitTest "$@"

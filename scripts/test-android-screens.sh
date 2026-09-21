#!/usr/bin/env bash
# Preserve the emulator-only contract and the operator's installed application.
set -euo pipefail
cd "$(dirname "$0")/.."
serial="${ANDROID_SERIAL:-emulator-5554}"
[[ "$serial" == emulator-* ]] || { echo 'Screen tests require the explicitly selected emulator.' >&2; exit 1; }
exec scripts/test-android-screens-fixture.sh "$serial" screenFixture

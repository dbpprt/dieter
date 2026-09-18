#!/usr/bin/env bash
# Install only the distinct screenfixture app on the explicitly named device.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && -n "$1" && "$1" != emulator-* ]] || {
    echo 'Usage: scripts/test-android-screens-device.sh EXACT_PHYSICAL_SERIAL' >&2
    exit 2
}
exec scripts/test-android-screens-fixture.sh "$1" screenFixture

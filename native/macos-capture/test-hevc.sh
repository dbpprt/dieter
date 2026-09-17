#!/usr/bin/env bash
# Hardware HEVC/RTP/native decoder checks without a GUI or an operator daemon.
set -euo pipefail
cd "$(dirname "$0")/../.."
HEVC_TEST_ROOT=$(mktemp -d /tmp/dieter-hevc-tests.XXXXXX)
trap 'rm -rf -- "$HEVC_TEST_ROOT"' EXIT
native/macos-capture/build.sh "$HEVC_TEST_ROOT/dieter-capture"
go build -o "$HEVC_TEST_ROOT/screens-fixture" ./scripts/screens-fixture
export DIETER_TEST_CAPTURE_HELPER="$HEVC_TEST_ROOT/dieter-capture"
export DIETER_TEST_HEVC_FRAMES="$HEVC_TEST_ROOT/frames.bin"
export DIETER_TEST_SCREEN_FIXTURE="$HEVC_TEST_ROOT/screens-fixture"
go test -race ./internal/remotedesktop -run 'TestHEVC|TestCapturePoolKeepsCodecs|TestNativeHelperHEVCRoundTrip|TestNativeHEVCAndH264' -count=1 -v
just mac test remoteDesktopHEVC

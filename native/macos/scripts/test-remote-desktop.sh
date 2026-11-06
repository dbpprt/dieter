#!/bin/sh
# Builds the release capture helper and runs the daemon's remote-desktop Go
# tests against it (formerly native/macos-capture/test.sh). The Swift unit
# tests are `swift test --package-path native/macos`.
#
#   native/macos/scripts/test-remote-desktop.sh [go test flags...]
#
# The Go package is ./internal/remotedesktop today; pass DIETER_GO_PACKAGE to
# point at it if it moves.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PACKAGE_DIR/../.." && pwd)
swift build --package-path "$PACKAGE_DIR" -c release --product dieter-capture
HELPER="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)/dieter-capture"
codesign --force --sign - "$HELPER"
cd "$REPO_ROOT"
DIETER_TEST_CAPTURE_HELPER="$HELPER" go test -race "${DIETER_GO_PACKAGE:-./internal/remotedesktop}" "$@"

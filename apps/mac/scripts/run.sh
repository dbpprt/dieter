#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_BUNDLE=$($SCRIPT_DIR/build.sh)
open "$APP_BUNDLE"

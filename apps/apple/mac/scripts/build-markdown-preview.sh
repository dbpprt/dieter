#!/bin/sh
# Builds the offline Markdown preview bundle (app.js, app.css, index.html,
# LICENSES.txt) from MarkdownPreview/ into Sources/DieterMacKit/Resources/MarkdownPreview,
# where DieterMacKit copies it as a resource. A fresh clone runs this before
# `swift build`; the bundle is not tracked. Pass --check to verify an existing
# bundle against the sources without writing.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREVIEW_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../MarkdownPreview" && pwd)
cd "$PREVIEW_DIR"
npm ci --ignore-scripts --no-audit --no-fund
if [ "${1:-}" = "--check" ]; then
    npm run --silent check
else
    npm run --silent build
fi

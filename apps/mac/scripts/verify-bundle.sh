#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <Dieter.app>" >&2
    exit 2
fi

APP_BUNDLE=$1
DIETER_BINARY="$APP_BUNDLE/Contents/MacOS/DieterMac"
WEBRTC_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/WebRTC.framework"
WEBRTC_BINARY="$WEBRTC_FRAMEWORK/Versions/A/WebRTC"

if [ ! -x "$DIETER_BINARY" ]; then
    echo "DieterMac executable is missing from $APP_BUNDLE" >&2
    exit 1
fi
if [ ! -x "$WEBRTC_BINARY" ]; then
    echo "WebRTC.framework is missing from $APP_BUNDLE" >&2
    exit 1
fi
for resource in \
    DieterMac_DieterMac.bundle/MarkdownPreview/index.html \
    DieterMac_DieterMac.bundle/MarkdownPreview/app.js \
    DieterMac_DieterMac.bundle/MarkdownPreview/app.css \
    DieterMac_DieterMac.bundle/MarkdownPreview/LICENSES.txt \
    DieterMac_DieterMac.bundle/MarkdownEditorLicenses.txt \
    Highlighter_Highlighter.bundle/highlight.min.js \
    Highlighter_Highlighter.bundle/atom-one-light.css \
    Highlighter_Highlighter.bundle/atom-one-dark.css; do
    if [ ! -f "$APP_BUNDLE/Contents/Resources/$resource" ]; then
        echo "Markdown resource is missing from $APP_BUNDLE: $resource" >&2
        exit 1
    fi
done
if ! otool -L "$DIETER_BINARY" | grep -Fq '@rpath/WebRTC.framework/WebRTC'; then
    echo "DieterMac does not link the expected WebRTC framework" >&2
    exit 1
fi
if ! otool -l "$DIETER_BINARY" | grep -Fq '@executable_path/../Frameworks'; then
    echo "DieterMac has no app-relative Frameworks runpath" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

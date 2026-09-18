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

bundle_resource_root() {
    if [ -d "$1/Contents/Resources" ]; then
        printf '%s\n' "$1/Contents/Resources"
    else
        printf '%s\n' "$1"
    fi
}

if [ ! -x "$DIETER_BINARY" ]; then
    echo "DieterMac executable is missing from $APP_BUNDLE" >&2
    exit 1
fi
if [ ! -x "$WEBRTC_BINARY" ]; then
    echo "WebRTC.framework is missing from $APP_BUNDLE" >&2
    exit 1
fi
MARKDOWN_BUNDLE="$APP_BUNDLE/Contents/Resources/DieterMac_DieterMac.bundle"
MARKDOWN_RESOURCES=$(bundle_resource_root "$MARKDOWN_BUNDLE")
for resource in \
    MarkdownPreview/index.html \
    MarkdownPreview/app.js \
    MarkdownPreview/app.css \
    MarkdownPreview/LICENSES.txt \
    MarkdownEditorLicenses.txt; do
    if [ ! -f "$MARKDOWN_RESOURCES/$resource" ]; then
        echo "Markdown resource is missing from $MARKDOWN_BUNDLE: $resource" >&2
        exit 1
    fi
done

HIGHLIGHTER_BUNDLE="$APP_BUNDLE/Contents/Resources/Highlighter_Highlighter.bundle"
HIGHLIGHTER_RESOURCES=$(bundle_resource_root "$HIGHLIGHTER_BUNDLE")
for resource in highlight.min.js atom-one-light.css atom-one-dark.css; do
    if [ ! -f "$HIGHLIGHTER_RESOURCES/$resource" ]; then
        echo "Markdown resource is missing from $HIGHLIGHTER_BUNDLE: $resource" >&2
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

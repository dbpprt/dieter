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
if ! otool -L "$DIETER_BINARY" | grep -Fq '@rpath/WebRTC.framework/WebRTC'; then
    echo "DieterMac does not link the expected WebRTC framework" >&2
    exit 1
fi
if ! otool -l "$DIETER_BINARY" | grep -Fq '@executable_path/../Frameworks'; then
    echo "DieterMac has no app-relative Frameworks runpath" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

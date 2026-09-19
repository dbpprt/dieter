#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/build/dieter-capture"}

for package in gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 json-glib-1.0 gio-unix-2.0 x11 xtst xrandr; do
    if ! pkg-config --exists "$package"; then
        echo "Missing Linux capture build dependency: $package" >&2
        exit 1
    fi
done

mkdir -p "$(dirname -- "$OUTPUT")"
cc -std=c17 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror -Wformat=2 -Wconversion \
    $(pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 json-glib-1.0 gio-unix-2.0 x11 xtst xrandr) \
    "$SCRIPT_DIR/dieter-capture.c" \
    $(pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 json-glib-1.0 gio-unix-2.0 x11 xtst xrandr) \
    -lm \
    -o "$OUTPUT"
chmod 0755 "$OUTPUT"
printf '%s\n' "$OUTPUT"

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:?output path is required}
TARGET_ARCH=${GOARCH:-}
case "$(uname -m)" in
    x86_64) native_arch=amd64 ;;
    aarch64|arm64) native_arch=arm64 ;;
    *) native_arch=unknown ;;
esac
if [ -n "$TARGET_ARCH" ] && [ "$TARGET_ARCH" != "$native_arch" ]; then
    echo "Linux capture helper must be built on its target architecture ($TARGET_ARCH requested on $native_arch)." >&2
    exit 1
fi

mkdir -p "$(dirname -- "$OUTPUT")"
OUTPUT=$(CDPATH= cd -- "$(dirname -- "$OUTPUT")" && pwd)/$(basename -- "$OUTPUT")

if command -v docker >/dev/null 2>&1; then
    host_uid=$(id -u)
    host_gid=$(id -g)
    docker run --rm \
        -e HOST_UID="$host_uid" -e HOST_GID="$host_gid" \
        -v "$SCRIPT_DIR:/src:ro" -v "$(dirname -- "$OUTPUT"):/out" \
        debian:12-slim /bin/sh -c '
            set -eu
            apt-get update >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                build-essential pkg-config libglib2.0-dev libgstreamer1.0-dev \
                libgstreamer-plugins-base1.0-dev libjson-glib-dev libx11-dev \
                libxtst-dev libxrandr-dev gstreamer1.0-plugins-base \
                gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly >/dev/null
            /src/build.sh "/out/'"$(basename -- "$OUTPUT")"'"
            capabilities="$("/out/'"$(basename -- "$OUTPUT")"'" --capabilities --synthetic true)"
            printf "%s" "$capabilities" | grep -q '"'"'H264'"'"'
            chown "$HOST_UID:$HOST_GID" "/out/'"$(basename -- "$OUTPUT")"'"
        '
elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "Docker is required in release CI to preserve the Debian 12 Linux helper ABI baseline." >&2
    exit 1
else
    "$SCRIPT_DIR/build.sh" "$OUTPUT" >/dev/null
    capabilities=$($OUTPUT --capabilities --synthetic true)
    printf '%s' "$capabilities" | grep -q '"H264"'
fi
printf '%s\n' "$OUTPUT"

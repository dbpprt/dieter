#!/bin/sh
set -eu

repository="dbpprt/dieter"
version="${DIETER_VERSION:-latest}"
install_directory="${DIETER_INSTALL_DIR:-}"

case "$(uname -s)" in
    Darwin) operating_system="darwin" ;;
    Linux) operating_system="linux" ;;
    *) echo "Dieter CLI releases support macOS and Linux; build from source on this platform." >&2; exit 1 ;;
esac

case "$(uname -m)" in
    arm64|aarch64) architecture="arm64" ;;
    x86_64|amd64) architecture="amd64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ "$operating_system" = "darwin" ] && [ "$architecture" != "arm64" ]; then
    echo "Published macOS daemon packages currently require Apple Silicon." >&2
    exit 1
fi

asset="dieter-${operating_system}-${architecture}"
if [ "$version" = "latest" ]; then
    download_url="https://github.com/${repository}/releases/latest/download/${asset}.tar.gz"
else
    case "$version" in v*) ;; *) version="v${version}" ;; esac
    download_url="https://github.com/${repository}/releases/download/${version}/${asset}.tar.gz"
fi

if [ -z "$install_directory" ]; then
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        install_directory="/usr/local/bin"
    else
        install_directory="${HOME}/.local/bin"
    fi
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/dieter-install.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT INT TERM

archive="${temporary_directory}/${asset}.tar.gz"
echo "Downloading ${download_url}"
curl --fail --location --silent --show-error "$download_url" --output "$archive"
tar -xzf "$archive" -C "$temporary_directory"
test -x "${temporary_directory}/${asset}/dieter"

mkdir -p "$install_directory"
install -m 0755 "${temporary_directory}/${asset}/dieter" "${install_directory}/dieter"
if [ -x "${temporary_directory}/${asset}/dieter-capture" ]; then
    install -m 0755 "${temporary_directory}/${asset}/dieter-capture" "${install_directory}/dieter-capture"
fi

echo "Installed Dieter CLI to ${install_directory}/dieter"
case ":${PATH}:" in
    *":${install_directory}:"*) ;;
    *) echo "Add ${install_directory} to PATH before invoking dieter." ;;
esac

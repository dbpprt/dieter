#!/bin/sh
set -eu

repository="dbpprt/dieter"
version="${DIETER_VERSION:-latest}"
install_directory="${DIETER_INSTALL_DIR:-}"
no_service="${DIETER_NO_SERVICE:-0}"

usage() {
    cat <<'EOF'
Install a signed Dieter CLI/daemon release.

Usage: install.sh [options]

Options:
  --version VERSION      Install VERSION instead of the latest release
  --install-dir DIR      Install executables into DIR
  --no-service           Do not install or refresh the Linux user service
  -h, --help             Show this help

Environment equivalents: DIETER_VERSION, DIETER_INSTALL_DIR,
DIETER_NO_SERVICE=1.

Supported release targets: Linux amd64/arm64 and Apple Silicon macOS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || {
                echo "--version requires a value." >&2
                exit 2
            }
            version="$2"
            shift 2
            ;;
        --install-dir)
            [ "$#" -ge 2 ] || {
                echo "--install-dir requires a value." >&2
                exit 2
            }
            install_directory="$2"
            shift 2
            ;;
        --no-service)
            no_service="1"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$version" ] || {
    echo "Release version must not be empty." >&2
    exit 2
}
[ "$no_service" = "0" ] || [ "$no_service" = "1" ] || {
    echo "DIETER_NO_SERVICE must be 0 or 1." >&2
    exit 2
}
case "$version" in
    latest) ;;
    v*) ;;
    *) version="v${version}" ;;
esac
case "$version" in
    *[!A-Za-z0-9._-]* | v)
        echo "Invalid release version: $version" >&2
        exit 2
        ;;
esac

case "$(uname -s)" in
    Darwin) operating_system="darwin" ;;
    Linux) operating_system="linux" ;;
    *)
        echo "Dieter CLI releases support macOS and Linux; build from source on this platform." >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    arm64 | aarch64) architecture="arm64" ;;
    x86_64 | amd64) architecture="amd64" ;;
    *)
        echo "Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

if [ "$operating_system" = "darwin" ] && [ "$architecture" != "arm64" ]; then
    echo "Published macOS daemon packages currently require Apple Silicon." >&2
    exit 1
fi

asset="dieter-${operating_system}-${architecture}"
if [ "$version" = "latest" ]; then
    download_url="https://github.com/${repository}/releases/latest/download/${asset}.tar.gz"
else
    download_url="https://github.com/${repository}/releases/download/${version}/${asset}.tar.gz"
fi

if [ -z "$install_directory" ]; then
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        install_directory="/usr/local/bin"
    else
        install_directory="${HOME}/.local/bin"
    fi
fi
[ -n "$install_directory" ] || {
    echo "Install directory must not be empty." >&2
    exit 2
}

for command_name in awk curl install mktemp tar; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "$command_name is required to install Dieter." >&2
        exit 1
    }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "sha256sum or shasum is required to verify Dieter." >&2
    exit 1
fi
if ! command -v cosign >/dev/null 2>&1; then
    echo "cosign is required to verify Dieter's signed release manifest." >&2
    echo "Install cosign from https://docs.sigstore.dev/cosign/system_config/installation/ and retry." >&2
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/dieter-install.XXXXXX")"
install_temp=""
capture_temp=""
privacy_install_temp=""
cleanup() {
    rm -rf "$temporary_directory"
    [ -z "$install_temp" ] || rm -f "$install_temp"
    [ -z "$capture_temp" ] || rm -f "$capture_temp"
    [ -z "$privacy_install_temp" ] || rm -rf "$privacy_install_temp"
}
trap cleanup EXIT INT TERM

archive="${temporary_directory}/${asset}.tar.gz"
checksums="${temporary_directory}/SHA256SUMS"
signature_bundle="${temporary_directory}/SHA256SUMS.sigstore.json"
echo "Downloading ${download_url}"
curl --fail --location --silent --show-error "$download_url" --output "$archive"
release_base="${download_url%/${asset}.tar.gz}"
curl --fail --location --silent --show-error "${release_base}/SHA256SUMS" --output "$checksums"
curl --fail --location --silent --show-error "${release_base}/SHA256SUMS.sigstore.json" --output "$signature_bundle"
cosign verify-blob \
    --bundle "$signature_bundle" \
    --certificate-identity-regexp '^https://github[.]com/dbpprt/dieter/[.]github/workflows/(release|release-coordinate)[.]yml@refs/heads/main$' \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$checksums" >/dev/null
expected_checksum="$(awk -v file="${asset}.tar.gz" '$2 == file || $2 == "*" file { print $1; found++ } END { if (found != 1) exit 1 }' "$checksums")" || {
    echo "Signed SHA256SUMS does not contain exactly one ${asset}.tar.gz entry." >&2
    exit 1
}
case "$expected_checksum" in
    *[!0-9a-fA-F]* | '')
        echo "Invalid SHA-256 checksum for ${asset}.tar.gz." >&2
        exit 1
        ;;
esac
if [ "${#expected_checksum}" -ne 64 ]; then
    echo "Invalid SHA-256 checksum length for ${asset}.tar.gz." >&2
    exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum="$(sha256sum "$archive" | awk '{print $1}')"
else
    actual_checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
fi
if [ "$actual_checksum" != "$expected_checksum" ]; then
    echo "Checksum verification failed for ${asset}.tar.gz." >&2
    exit 1
fi
tar -tzf "$archive" | while IFS= read -r entry; do
    case "$entry" in
        "$asset" | "$asset/" | "$asset/dieter" | "$asset/dieter-capture" | "$asset/LICENSE" | "$asset/VERSION" | "$asset/install.sh") ;;
        "$asset/DieterPrivacyHelper.app" | "$asset/DieterPrivacyHelper.app/" | "$asset/DieterPrivacyHelper.app/Contents" | "$asset/DieterPrivacyHelper.app/Contents/" | "$asset/DieterPrivacyHelper.app/Contents/Info.plist" | "$asset/DieterPrivacyHelper.app/Contents/MacOS" | "$asset/DieterPrivacyHelper.app/Contents/MacOS/" | "$asset/DieterPrivacyHelper.app/Contents/MacOS/dieter-privacy" | "$asset/DieterPrivacyHelper.app/Contents/Library" | "$asset/DieterPrivacyHelper.app/Contents/Library/" | "$asset/DieterPrivacyHelper.app/Contents/Library/LaunchDaemons" | "$asset/DieterPrivacyHelper.app/Contents/Library/LaunchDaemons/" | "$asset/DieterPrivacyHelper.app/Contents/Library/LaunchDaemons/com.dbpprt.dieter.privacy.plist" | "$asset/DieterPrivacyHelper.app/Contents/_CodeSignature" | "$asset/DieterPrivacyHelper.app/Contents/_CodeSignature/" | "$asset/DieterPrivacyHelper.app/Contents/_CodeSignature/CodeResources")
            [ "$operating_system" = "darwin" ] || {
                echo "Unexpected macOS helper in this release." >&2
                exit 1
            }
            ;;
        *)
            echo "Release archive contains an unexpected path: $entry" >&2
            exit 1
            ;;
    esac
done
tar -xzf "$archive" -C "$temporary_directory"
mkdir -p "$install_directory"
if [ "$operating_system" = "darwin" ]; then
    release_source="${temporary_directory}/${asset}"
    privacy_source="$release_source/DieterPrivacyHelper.app"
    for privacy_directory in "$privacy_source" "$privacy_source/Contents" "$privacy_source/Contents/MacOS" "$privacy_source/Contents/Library" "$privacy_source/Contents/Library/LaunchDaemons" "$privacy_source/Contents/_CodeSignature"; do
        test -d "$privacy_directory" && test ! -L "$privacy_directory"
    done
    for privacy_file in "$privacy_source/Contents/Info.plist" "$privacy_source/Contents/MacOS/dieter-privacy" "$privacy_source/Contents/Library/LaunchDaemons/com.dbpprt.dieter.privacy.plist" "$privacy_source/Contents/_CodeSignature/CodeResources"; do
        test -f "$privacy_file" && test ! -L "$privacy_file"
    done
    test -x "$privacy_source/Contents/MacOS/dieter-privacy"
    codesign --verify --deep --strict -R '=identifier "com.dbpprt.dieter.privacy" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "DS6N5L85E7"' "$privacy_source"
    for executable in dieter dieter-capture; do
        test -f "$release_source/$executable" && test ! -L "$release_source/$executable" && test -x "$release_source/$executable"
        if [ "$executable" = "dieter" ]; then
            executable_identifier="com.dbpprt.dieter.daemon"
        else
            executable_identifier="com.dbpprt.dieter.capture"
        fi
        codesign --verify --strict -R "=identifier \"$executable_identifier\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"DS6N5L85E7\"" "$release_source/$executable"
    done
    for install_target in "$install_directory/DieterPrivacyHelper.app" "$install_directory/dieter" "$install_directory/dieter-capture"; do
        if [ -e "$install_target" ] || [ -L "$install_target" ]; then
            echo "Dieter is already installed here. Use the managed Homebrew updater or an empty install directory." >&2
            exit 1
        fi
    done
    privacy_install_temp="$(mktemp -d "${install_directory}/.dieter-install.XXXXXX")"
    cp -R "$privacy_source" "$privacy_install_temp/DieterPrivacyHelper.app"
    install -m 0755 "$release_source/dieter" "$privacy_install_temp/dieter"
    install -m 0755 "$release_source/dieter-capture" "$privacy_install_temp/dieter-capture"
    mv "$privacy_install_temp/DieterPrivacyHelper.app" "$install_directory/DieterPrivacyHelper.app"
    mv "$privacy_install_temp/dieter" "$install_directory/dieter"
    mv "$privacy_install_temp/dieter-capture" "$install_directory/dieter-capture"
else
    test -f "${temporary_directory}/${asset}/dieter"
    test ! -L "${temporary_directory}/${asset}/dieter"
    test -x "${temporary_directory}/${asset}/dieter"
    if [ -e "${temporary_directory}/${asset}/dieter-capture" ]; then
        test -f "${temporary_directory}/${asset}/dieter-capture"
        test ! -L "${temporary_directory}/${asset}/dieter-capture"
        test -x "${temporary_directory}/${asset}/dieter-capture"
    else
        echo "The linux release is missing its native capture helper." >&2
        exit 1
    fi
    install_temp="$(mktemp "${install_directory}/.dieter.XXXXXX")"
    install -m 0755 "${temporary_directory}/${asset}/dieter" "$install_temp"
    mv -f "$install_temp" "${install_directory}/dieter"
    capture_temp="$(mktemp "${install_directory}/.dieter-capture.XXXXXX")"
    install -m 0755 "${temporary_directory}/${asset}/dieter-capture" "$capture_temp"
    mv -f "$capture_temp" "${install_directory}/dieter-capture"
fi

if [ -x "${install_directory}/dieter-capture" ]; then
    echo "Installed Dieter CLI and capture helper to ${install_directory}"
else
    echo "Installed Dieter CLI to ${install_directory}/dieter"
fi
case ":${PATH}:" in
    *":${install_directory}:"*) ;;
    *) echo "Add ${install_directory} to PATH before invoking dieter." ;;
esac

if [ "$operating_system" = "linux" ] && [ "$no_service" != "1" ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        "${install_directory}/dieter" daemon service install
    else
        echo "A systemd user manager is unavailable; run Dieter in foreground mode or install the service later."
    fi
elif [ "$operating_system" = "darwin" ]; then
    echo "This portable macOS install does not register a service."
    echo "For a managed daemon and native app, use Homebrew: brew install dbpprt/tap/dieter"
fi

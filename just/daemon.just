set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

binary := "bin/dieter"
target := "./cmd/dieter"
mac_package := "stage/dieter-darwin-arm64"

# List the daemon commands.
default:
    @just --justfile just/daemon.just --list

# Verify daemon build dependencies.
doctor:
    command -v go
    command -v install
    go version

# Install the native Linux capture build/runtime matrix on an Ubuntu CI runner.
linux-ci-dependencies:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Linux ]] || {
        echo "Linux CI dependency installation is restricted to GitHub Actions." >&2
        exit 1
    }
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        build-essential pkg-config ripgrep libglib2.0-dev libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev libjson-glib-dev libx11-dev \
        libxtst-dev libxrandr-dev gstreamer1.0-tools gstreamer1.0-x \
        gstreamer1.0-pipewire gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly xvfb x11-utils

# Build the daemon and CLI, optionally embedding a release tag.
build version="":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bin
    if [[ -n "{{ version }}" ]]; then
        go build -trimpath \
            -ldflags "-X github.com/dbpprt/dieter/internal/buildinfo.ReleaseVersion={{ version }}" \
            -o "{{ binary }}" "{{ target }}"
    else
        go build -trimpath -o "{{ binary }}" "{{ target }}"
    fi

# Test every Dieter package in the daemon command's dependency graph.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    packages=()
    while IFS= read -r package; do packages+=("$package"); done < <(
        go list -deps "{{ target }}" | rg '^github[.]com/dbpprt/dieter/'
    )
    go test "${packages[@]}"

# Build the Linux native helper and run its bounded protocol/lifecycle matrix.
linux-capture-test:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$(uname -s)" != Linux ]]; then
        echo "Linux capture tests skipped on $(uname -s)."
        exit 0
    fi
    temporary="$(mktemp -d "${TMPDIR:-/tmp}/dieter-linux-capture.XXXXXX")"
    xvfb_pid=""
    cleanup() {
        if [[ -n "$xvfb_pid" ]]; then
            kill "$xvfb_pid" >/dev/null 2>&1 || true
            wait "$xvfb_pid" >/dev/null 2>&1 || true
        fi
        rm -rf "$temporary"
    }
    trap cleanup EXIT
    native/linux-capture/build.sh "$temporary/dieter-capture" >/dev/null
    cc -std=c17 -O2 -Wall -Wextra -Werror native/linux-capture/x11-test-target.c \
        $(pkg-config --cflags --libs x11) -o "$temporary/x11-test-target"
    "$temporary/dieter-capture" --capabilities --synthetic true | python3 -m json.tool >/dev/null
    DIETER_TEST_CAPTURE_HELPER="$temporary/dieter-capture" go test ./internal/remotedesktop -count=1 -run \
        '^(TestLinuxNativeHelperCapabilities|TestLinuxNativeStartupAllowsPortalConsentDelay|TestNativeHelperBaselineUsesLowLatencyHardware|TestNativeHelperHardwareLifecycle|TestNativeHelperKeepsInputResponsiveUnderMediaBackpressure|TestNativeHelperWatchdogExitsWithoutDaemonHeartbeat|TestNativeMultiplexSharesEncoderAndIsolatesRenditions|TestNativeFourIndependentHardwareRenditions|TestNativeCancelledLifecyclePreservesExistingViewer|TestNativeConfigurationAndSlowEventsPreserveHeartbeat|TestNativeDelayedHeartbeatReplyPreservesActiveCapture|TestNativeHelperShutdownDuringFrameCreditsIsRecoverable|TestNativeHelperHighRefreshHardware)$$'
    xvfb="${DIETER_TEST_XVFB:-$(command -v Xvfb || true)}"
    if [[ -n "$xvfb" ]]; then
        display_number=93
        while [[ -e "/tmp/.X11-unix/X$display_number" ]]; do display_number=$((display_number + 1)); done
        "$xvfb" ":$display_number" -screen 0 1024x768x24 -nolisten tcp -ac >"$temporary/xvfb.log" 2>&1 &
        xvfb_pid=$!
        for _ in $(seq 1 50); do
            DISPLAY=":$display_number" xdpyinfo >/dev/null 2>&1 && break
            sleep 0.1
        done
        DISPLAY=":$display_number" XDG_SESSION_TYPE=x11 XAUTHORITY= \
            DIETER_TEST_CAPTURE_HELPER="$temporary/dieter-capture" DIETER_TEST_X11_TARGET="$temporary/x11-test-target" \
            go test ./internal/remotedesktop -count=1 -run '^TestLinuxNativeX11CaptureAndControl$$'
    else
        echo "Xvfb unavailable; isolated real X11 capture/control test skipped."
    fi

# Scan daemon/CLI dependencies with the release's pinned Go toolchain.
vulncheck:
    #!/usr/bin/env bash
    set -euo pipefail
    daemon_toolchain="$(sed -n 's/^go /go/p' go.mod)"
    GOTOOLCHAIN="$daemon_toolchain" go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./cmd/dieter

# Start a source daemon in the foreground without managing any existing service.
run:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v lsof >/dev/null && lsof -nP -iTCP:4242 -sTCP:LISTEN | rg -q .; then
        echo "Port 4242 already has a listener; refusing to start a second default daemon." >&2
        exit 1
    fi
    go run "{{ target }}" serve

# Install the daemon/CLI and native capture helper. Set capture=false for a
# deliberately headless source installation. PREFIX defaults to /usr/local.
install prefix="/usr/local" destdir="" capture="true": build
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "{{ capture }}" == true || "{{ capture }}" == false ]] || { echo "capture must be true or false" >&2; exit 1; }
    destination="{{ destdir }}{{ prefix }}/bin"
    install -d "$destination"
    install -m 0755 "{{ binary }}" "$destination/dieter"
    if [[ "{{ capture }}" == true ]]; then
        temporary="$(mktemp -d "${TMPDIR:-/tmp}/dieter-source-install.XXXXXX")"
        trap 'rm -rf "$temporary"' EXIT
        case "$(uname -s)" in
            Linux) native/linux-capture/build.sh "$temporary/dieter-capture" >/dev/null ;;
            Darwin) native/macos-capture/build.sh "$temporary/dieter-capture" >/dev/null ;;
            *) echo "No native capture helper is available on $(uname -s)." >&2; exit 1 ;;
        esac
        install -m 0755 "$temporary/dieter-capture" "$destination/dieter-capture"
    fi

# Cross-compile and archive one release target using GOOS, GOARCH, ASSET, and RELEASE_VERSION.
package-release:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GOOS:?GOOS is required}"
    : "${GOARCH:?GOARCH is required}"
    : "${ASSET:?ASSET is required}"
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    [[ "$ASSET" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe ASSET: $ASSET" >&2; exit 1; }
    package="stage/$ASSET"
    archive="dist/$ASSET.tar.gz"
    [[ ! -e "$package" && ! -e "$archive" ]] || { echo "Release output already exists: $ASSET" >&2; exit 1; }
    mkdir -p "$package" dist
    CGO_ENABLED=0 go build -trimpath \
        -ldflags "-s -w -X github.com/dbpprt/dieter/internal/buildinfo.ReleaseVersion=$RELEASE_VERSION" \
        -o "$package/dieter" "{{ target }}"
    if [[ "$GOOS" == linux ]]; then
        GOARCH="$GOARCH" native/linux-capture/build-release.sh "$package/dieter-capture"
    fi
    cp LICENSE "$package/LICENSE"
    cp scripts/install.sh "$package/install.sh"
    tar -C stage -czf "$archive" "$ASSET"
    echo "$archive"

# Execute a packaged Linux daemon on its target architecture.
smoke-release:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GOARCH:?GOARCH is required}"
    : "${ASSET:?ASSET is required}"
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    test -f "dist/$ASSET.tar.gz"
    smoke_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/dieter-release-smoke.XXXXXX")"
    trap 'rm -rf "$smoke_dir"' EXIT
    tar -xzf "dist/$ASSET.tar.gz" -C "$smoke_dir"
    test -x "$smoke_dir/$ASSET/dieter"
    test -x "$smoke_dir/$ASSET/dieter-capture"
    native_arch="$(uname -m)"
    if [[ "$GOARCH" == amd64 && "$native_arch" == x86_64 ]] || \
       [[ "$GOARCH" == arm64 && ("$native_arch" == aarch64 || "$native_arch" == arm64) ]]; then
        capabilities="$("$smoke_dir/$ASSET/dieter-capture" --capabilities --synthetic true)"
        rg -q '"H264"' <<<"$capabilities"
        actual="$($smoke_dir/$ASSET/dieter --version)"
    else
        actual="$(docker run --rm --platform linux/arm64 \
            -v "$smoke_dir/$ASSET:/artifact:ro" alpine:3.22 /artifact/dieter --version)"
    fi
    [[ "$actual" == "$RELEASE_VERSION" ]] || { echo "Release version mismatch: $actual" >&2; exit 1; }

# Smoke the static amd64 archive across representative Linux userlands.
distro-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    archive="dist/dieter-linux-amd64.tar.gz"
    test -f "$archive"
    smoke_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/dieter-distro-smoke.XXXXXX")"
    trap 'rm -rf "$smoke_dir"' EXIT
    tar -xzf "$archive" -C "$smoke_dir"
    for image in ubuntu:24.04 debian:12 fedora:42 archlinux:base alpine:3.22; do
        actual="$(docker run --rm -v "$smoke_dir/dieter-linux-amd64:/artifact:ro" "$image" /artifact/dieter --version)"
        [[ "$actual" == "$RELEASE_VERSION" ]] || { echo "$image returned $actual" >&2; exit 1; }
    done

# Build the Apple Silicon daemon plus native capture helper for release packaging.
package-macos:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$(uname -s)" == Darwin ]] || { echo "macOS packaging requires Darwin." >&2; exit 1; }
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    [[ ! -e "{{ mac_package }}" ]] || { echo "{{ mac_package }} already exists." >&2; exit 1; }
    mkdir -p "{{ mac_package }}" dist
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath \
        -ldflags "-s -w -X github.com/dbpprt/dieter/internal/buildinfo.ReleaseVersion=$RELEASE_VERSION" \
        -o "{{ mac_package }}/dieter" "{{ target }}"
    native/macos-capture/build.sh "{{ mac_package }}/dieter-capture"
    cp LICENSE "{{ mac_package }}/LICENSE"
    cp scripts/install.sh "{{ mac_package }}/install.sh"

# Run the signed daemon from a disposable fixed runtime before publishing it.
test-signed-runtime:
    DIETER_SIGNED_SERVICE_SOURCE="$PWD/{{ mac_package }}" go test ./internal/serviceruntime -run '^TestSignedServiceRuntimeSmoke$' -count=1 -v

# Sign and notarize the staged macOS daemon and capture helper.
[confirm]
sign-notarize-macos:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "This publishing recipe is CI-only." >&2; exit 1; }
    : "${CERTIFICATE_BASE64:?CERTIFICATE_BASE64 is required}"
    : "${CERTIFICATE_PASSWORD:?CERTIFICATE_PASSWORD is required}"
    : "${NOTARY_KEY_BASE64:?NOTARY_KEY_BASE64 is required}"
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
    : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
    test -x "{{ mac_package }}/dieter"
    test -x "{{ mac_package }}/dieter-capture"
    signing_keychain="$RUNNER_TEMP/dieter-daemon-signing.keychain-db"
    keychain_password="$(uuidgen)"
    certificate_path="$RUNNER_TEMP/developer-id.p12"
    notary_key_path="$RUNNER_TEMP/notary-key.p8"
    submission_path="$RUNNER_TEMP/Dieter-daemon-notarization.zip"
    original_keychains="$(security list-keychains -d user)"
    cleanup() {
        python3 -c 'import shlex, subprocess, sys; subprocess.run(["security", "list-keychains", "-d", "user", "-s", *shlex.split(sys.argv[1])], check=True)' "$original_keychains" || true
        security delete-keychain "$signing_keychain" >/dev/null 2>&1 || true
        rm -f "$certificate_path" "$notary_key_path" "$submission_path"
    }
    trap cleanup EXIT
    umask 077
    printf '%s' "$CERTIFICATE_BASE64" | base64 -D >"$certificate_path"
    printf '%s' "$NOTARY_KEY_BASE64" | base64 -D >"$notary_key_path"
    security create-keychain -p "$keychain_password" "$signing_keychain"
    security set-keychain-settings -lut 21600 "$signing_keychain"
    security unlock-keychain -p "$keychain_password" "$signing_keychain"
    security import "$certificate_path" -k "$signing_keychain" \
        -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$keychain_password" "$signing_keychain"
    python3 -c 'import shlex, subprocess, sys; subprocess.run(["security", "list-keychains", "-d", "user", "-s", sys.argv[2], *shlex.split(sys.argv[1])], check=True)' "$original_keychains" "$signing_keychain"
    identity="$(security find-identity -v -p codesigning "$signing_keychain" | \
        awk '/Developer ID Application/ {print $2; exit}')"
    test -n "$identity"
    codesign --force --options runtime --timestamp --identifier com.dbpprt.dieter.daemon \
        --keychain "$signing_keychain" --sign "$identity" "{{ mac_package }}/dieter"
    codesign --force --options runtime --timestamp --identifier com.dbpprt.dieter.capture \
        --keychain "$signing_keychain" --sign "$identity" "{{ mac_package }}/dieter-capture"
    codesign --verify --strict --verbose=2 "{{ mac_package }}/dieter"
    codesign --verify --strict --verbose=2 "{{ mac_package }}/dieter-capture"
    ditto -c -k --sequesterRsrc --keepParent "{{ mac_package }}" "$submission_path"
    python3 scripts/macos_notary_submit.py "$submission_path" --key "$notary_key_path" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"

# Build a versioned daemon installer without installing or starting any service.
installer-macos:
    python3 scripts/macos_daemon_installer.py build

# Sign, notarize, staple, and verify the staged daemon installer in GitHub Actions.
[confirm]
sign-notarize-installer-macos:
    python3 scripts/macos_daemon_installer.py sign

# Test installer payload/preflight safety and notarization acceptance handling.
installer-test:
    python3 -m unittest discover -s scripts -p 'macos_*_test.py'

# Archive the staged Apple Silicon daemon package.
archive-macos:
    test -x "{{ mac_package }}/dieter"
    test -x "{{ mac_package }}/dieter-capture"
    mkdir -p dist
    tar -C stage -czf dist/dieter-darwin-arm64.tar.gz dieter-darwin-arm64

# Remove only daemon build and staged release outputs.
[confirm]
clean:
    rm -rf "{{ binary }}" "{{ mac_package }}" dist/dieter-darwin-*.tar.gz dist/dieter-darwin-*.pkg dist/dieter-linux-*.tar.gz stage/dieter-linux-*

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

# Build the daemon and CLI, optionally embedding a release tag.
build version="":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bin
    if [[ -n "{{ version }}" ]]; then
        go build -trimpath \
            -ldflags "-X github.com/dbpprt/dieter/internal/cli.Version={{ version }}" \
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

# Start a source daemon in the foreground without managing any existing service.
run:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v lsof >/dev/null && lsof -nP -iTCP:4242 -sTCP:LISTEN | rg -q .; then
        echo "Port 4242 already has a listener; refusing to start a second default daemon." >&2
        exit 1
    fi
    go run "{{ target }}" serve

# Install the daemon/CLI binary. PREFIX defaults to /usr/local.
install prefix="/usr/local" destdir="": build
    install -d "{{ destdir }}{{ prefix }}/bin"
    install -m 0755 "{{ binary }}" "{{ destdir }}{{ prefix }}/bin/dieter"

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
        -ldflags "-s -w -X github.com/dbpprt/dieter/internal/cli.Version=$RELEASE_VERSION" \
        -o "$package/dieter" "{{ target }}"
    cp LICENSE "$package/LICENSE"
    cp scripts/install.sh "$package/install.sh"
    tar -C stage -czf "$archive" "$ASSET"
    echo "$archive"

# Build the Apple Silicon daemon plus native capture helper for release packaging.
package-macos:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$(uname -s)" == Darwin ]] || { echo "macOS packaging requires Darwin." >&2; exit 1; }
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    [[ ! -e "{{ mac_package }}" ]] || { echo "{{ mac_package }} already exists." >&2; exit 1; }
    mkdir -p "{{ mac_package }}" dist
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath \
        -ldflags "-s -w -X github.com/dbpprt/dieter/internal/cli.Version=$RELEASE_VERSION" \
        -o "{{ mac_package }}/dieter" "{{ target }}"
    native/macos-capture/build.sh "{{ mac_package }}/dieter-capture"
    cp LICENSE "{{ mac_package }}/LICENSE"
    cp scripts/install.sh "{{ mac_package }}/install.sh"

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
    cleanup() { security delete-keychain "$signing_keychain" >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    printf '%s' "$CERTIFICATE_BASE64" | base64 -D >"$certificate_path"
    printf '%s' "$NOTARY_KEY_BASE64" | base64 -D >"$notary_key_path"
    security create-keychain -p "$keychain_password" "$signing_keychain"
    security set-keychain-settings -lut 21600 "$signing_keychain"
    security unlock-keychain -p "$keychain_password" "$signing_keychain"
    security import "$certificate_path" -k "$signing_keychain" \
        -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$keychain_password" "$signing_keychain"
    identity="$(security find-identity -v -p codesigning "$signing_keychain" | \
        awk '/Developer ID Application/ {print $2; exit}')"
    test -n "$identity"
    codesign --force --options runtime --timestamp --identifier com.dbpprt.dieter.daemon \
        --sign "$identity" "{{ mac_package }}/dieter"
    codesign --force --options runtime --timestamp --identifier com.dbpprt.dieter.capture \
        --sign "$identity" "{{ mac_package }}/dieter-capture"
    codesign --verify --strict --verbose=2 "{{ mac_package }}/dieter"
    codesign --verify --strict --verbose=2 "{{ mac_package }}/dieter-capture"
    ditto -c -k --sequesterRsrc --keepParent "{{ mac_package }}" "$submission_path"
    xcrun notarytool submit "$submission_path" --key "$notary_key_path" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait

# Archive the staged Apple Silicon daemon package.
archive-macos:
    test -x "{{ mac_package }}/dieter"
    test -x "{{ mac_package }}/dieter-capture"
    mkdir -p dist
    tar -C stage -czf dist/dieter-darwin-arm64.tar.gz dieter-darwin-arm64

# Remove only daemon build and staged release outputs.
[confirm]
clean:
    rm -rf "{{ binary }}" "{{ mac_package }}" dist/dieter-darwin-*.tar.gz dist/dieter-linux-*.tar.gz stage/dieter-linux-*

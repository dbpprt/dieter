set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

app_root := "apps/mac"
app_bundle := app_root / "build/Dieter.app"
app_executable := app_bundle / "Contents/MacOS/DieterMac"
app_scratch := app_root / ".build/dieter-local"
test_scratch := app_root / ".build/dieter-tests"

# List the macOS commands.
default:
    @just --justfile just/mac.just --list

# Verify the macOS build and lifecycle tools.
doctor:
    test "$(uname -s)" = Darwin
    command -v swift
    command -v python3
    command -v xcodebuild
    command -v codesign
    command -v osascript
    command -v open
    command -v rg
    test -x /usr/sbin/screencapture
    swift --version
    xcode-select -p

# Show every Dieter app and active Swift build process without changing them.
status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Expected app: $PWD/{{ app_executable }}"
    found=0
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        found=1
        ps -p "$pid" -o pid=,ppid=,lstart=,stat=,rss=,command=
    done < <(pgrep -x DieterMac || true)
    if [[ "$found" -eq 0 ]]; then echo "No DieterMac process is running."; fi
    ps -axo pid=,ppid=,stat=,etime=,comm= | \
        rg 'swift-(frontend|driver|build|test|package)|swift (build|test)|(^|/)(clang|ld)( |$)' || true

# Build and package Dieter.app with the canonical SwiftPM cache.
build configuration="debug":
    #!/usr/bin/env bash
    set -euo pipefail
    release_version="${DIETER_RELEASE_VERSION:-$(just release pseudo-version)}"
    CONFIGURATION="{{ configuration }}" DIETER_RELEASE_VERSION="$release_version" \
        DIETER_SWIFT_SCRATCH_PATH="$PWD/{{ app_scratch }}" {{ app_root }}/scripts/build.sh

# Run Mac unit tests with an optional Swift Testing filter.
test filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    arguments=(
        test
        --package-path "{{ app_root }}"
        --scratch-path "$PWD/{{ test_scratch }}"
        --only-use-versions-from-resolved-file
        --manifest-cache local
        --disable-index-store
        --no-parallel
    )
    if [[ -n "${DIETER_SWIFT_JOBS:-}" ]]; then arguments+=(--jobs "$DIETER_SWIFT_JOBS"); fi
    if [[ -n "{{ filter }}" ]]; then arguments+=(--filter "{{ filter }}"); fi
    swift "${arguments[@]}"

# Format handwritten Swift; generated clients and vendored sources are excluded.
format:
    bash apps/mac/scripts/format-swift.sh --write

# Enforce the repository's handwritten Swift formatting policy.
format-check:
    bash apps/mac/scripts/format-swift.sh --check

# Test the bundled Markdown libraries and reject stale generated assets.
markdown-check:
    npm --prefix {{ app_root }}/MarkdownPreview ci
    npm --prefix {{ app_root }}/MarkdownPreview test
    npm --prefix {{ app_root }}/MarkdownPreview run check

# Verify generated clients, formatting, tests, and the debug bundle.
check:
    just mac lifecycle-test
    just mac format-check
    just mac proto-check
    just mac test
    just mac build

# Build and launch when stopped, or activate the existing packaged app unchanged.
run:
    python3 scripts/mac_app_lifecycle.py run

# Gracefully quit the packaged app and prove its process exited.
quit:
    python3 scripts/mac_app_lifecycle.py quit

# Test app lifecycle guards without launching apps or using a compiler.
lifecycle-test:
    python3 -m unittest discover -s scripts -p 'mac_*test.py'
    python3 -m unittest discover -s scripts -p 'sync_apple_proto_test.py'

# Verify the packaged app bundle and its signature.
verify:
    {{ app_root }}/scripts/verify-bundle.sh "$PWD/{{ app_bundle }}"
    codesign --verify --deep --strict --verbose=2 "$PWD/{{ app_bundle }}"

# Set release versions and restore the app's valid ad-hoc signature.
set-release-version:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    : "${BUILD_NUMBER:?BUILD_NUMBER is required}"
    plist="{{ app_bundle }}/Contents/Info.plist"
    test -f "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"
    /usr/libexec/PlistBuddy -c "Set :DieterReleaseVersion $RELEASE_VERSION" "$plist"
    codesign --force --sign - "{{ app_bundle }}/Contents/Frameworks/WebRTC.framework"
    codesign --force --deep --sign - "{{ app_bundle }}"
    just mac verify

# Sign, notarize, staple, and assess the release app on the GitHub macOS runner.
[confirm]
sign-notarize-release:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "This publishing recipe is CI-only." >&2; exit 1; }
    : "${CERTIFICATE_BASE64:?CERTIFICATE_BASE64 is required}"
    : "${CERTIFICATE_PASSWORD:?CERTIFICATE_PASSWORD is required}"
    : "${NOTARY_KEY_BASE64:?NOTARY_KEY_BASE64 is required}"
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
    : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
    signing_keychain="$RUNNER_TEMP/dieter-signing.keychain-db"
    keychain_password="$(uuidgen)"
    certificate_path="$RUNNER_TEMP/developer-id.p12"
    notary_key_path="$RUNNER_TEMP/notary-key.p8"
    submission_path="$RUNNER_TEMP/Dieter-notarization.zip"
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
    codesign --force --options runtime --timestamp --keychain "$signing_keychain" --sign "$identity" \
        "{{ app_bundle }}/Contents/Frameworks/WebRTC.framework"
    codesign --force --options runtime --timestamp --keychain "$signing_keychain" --sign "$identity" "{{ app_bundle }}"
    codesign --verify --deep --strict --verbose=2 "{{ app_bundle }}"
    ditto -c -k --sequesterRsrc --keepParent "{{ app_bundle }}" "$submission_path"
    python3 scripts/macos_notary_submit.py "$submission_path" --key "$notary_key_path" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
    xcrun stapler staple "{{ app_bundle }}"
    xcrun stapler validate "{{ app_bundle }}"
    spctl --assess --type execute --verbose=4 "{{ app_bundle }}"

# Verify, archive, extract, and reverify the macOS release app.
package-release:
    #!/usr/bin/env bash
    set -euo pipefail
    archive="dist/Dieter-macOS-arm64.zip"
    [[ ! -e "$archive" ]] || { echo "$archive already exists." >&2; exit 1; }
    mkdir -p dist
    just mac verify
    ditto -c -k --sequesterRsrc --keepParent "{{ app_bundle }}" "$archive"
    extracted_bundle="$(mktemp -d)"
    trap 'rm -rf "$extracted_bundle"' EXIT
    ditto -x -k "$archive" "$extracted_bundle"
    {{ app_root }}/scripts/verify-bundle.sh "$extracted_bundle/Dieter.app"
    release_version="$(/usr/libexec/PlistBuddy -c 'Print :DieterReleaseVersion' "$extracted_bundle/Dieter.app/Contents/Info.plist")"
    printf '%s\n' "$release_version" >"$archive.version"
    echo "$archive"

# Remove only the packaged macOS release archive.
[confirm]
clean-release:
    rm -f dist/Dieter-macOS-arm64.zip dist/Dieter-macOS-arm64.zip.version

# Check that the checked-in Swift protobuf clients match their inputs.
proto-check:
    DIETER_SWIFT_SCRATCH_PATH="$PWD/{{ app_scratch }}" {{ app_root }}/scripts/generate-swift-proto.sh --check

# Regenerate the checked-in Swift protobuf clients with the canonical cache.
proto-generate:
    DIETER_SWIFT_SCRATCH_PATH="$PWD/{{ app_scratch }}" {{ app_root }}/scripts/sync-proto.sh

# Exercise native hardware capture, input state and bounded backpressure.
screens-native-test:
    native/macos-capture/test.sh

# Exercise the complete gRPC/native WebRTC viewer with isolated synthetic pixels.
# Set DIETER_TEST_SCREEN_CAPTURE_REAL=1 for actual capture and owned-window input.
screens-test:
    native/macos-capture/test-viewer.sh

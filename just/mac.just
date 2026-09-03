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
    ps -axo pid=,ppid=,stat=,etime=,command= | \
        rg 'swift-(frontend|driver)|swift (build|test)|(^|/)(clang|ld)( |$)' || true

# Build and package Dieter.app with the canonical SwiftPM cache.
build configuration="debug":
    CONFIGURATION="{{ configuration }}" DIETER_SWIFT_SCRATCH_PATH="$PWD/{{ app_scratch }}" {{ app_root }}/scripts/build.sh

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
    if [[ -n "{{ filter }}" ]]; then arguments+=(--filter "{{ filter }}"); fi
    swift "${arguments[@]}"

# Verify generated clients, run tests, and package the debug app.
check:
    just mac proto-check
    just mac test
    just mac build

# Launch or activate exactly one packaged debug app.
run: build
    #!/usr/bin/env bash
    set -euo pipefail
    expected="$PWD/{{ app_executable }}"
    bundle="$PWD/{{ app_bundle }}"
    exact=0
    other=0
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command="$(ps -p "$pid" -o command=)"
        if [[ "$command" == "$expected"* ]]; then exact=$((exact + 1)); else other=$((other + 1)); fi
    done < <(pgrep -x DieterMac || true)
    if (( other > 0 || exact > 1 )); then
        echo "Refusing to launch: DieterMac processes not owned by this bundle are present." >&2
        just mac status >&2
        exit 1
    fi
    open "$bundle"
    for _ in {1..40}; do
        count=0
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            [[ "$(ps -p "$pid" -o command=)" == "$expected"* ]] && count=$((count + 1))
        done < <(pgrep -x DieterMac || true)
        [[ "$count" -eq 1 ]] && { echo "$expected"; exit 0; }
        sleep 0.25
    done
    echo "Dieter.app did not reach exactly one running process." >&2
    just mac status >&2
    exit 1

# Gracefully quit the packaged app and prove its process exited.
quit:
    #!/usr/bin/env bash
    set -euo pipefail
    expected="$PWD/{{ app_executable }}"
    bundle="$PWD/{{ app_bundle }}"
    exact=0
    other=0
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command="$(ps -p "$pid" -o command=)"
        if [[ "$command" == "$expected"* ]]; then exact=$((exact + 1)); else other=$((other + 1)); fi
    done < <(pgrep -x DieterMac || true)
    if (( other > 0 )); then
        echo "Refusing the app-level quit event because another DieterMac bundle is running." >&2
        just mac status >&2
        exit 1
    fi
    if (( exact == 0 )); then echo "The packaged Dieter app is not running."; exit 0; fi
    osascript -e "tell application \"$bundle\" to quit"
    for _ in {1..40}; do
        remaining=0
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            [[ "$(ps -p "$pid" -o command=)" == "$expected"* ]] && remaining=$((remaining + 1))
        done < <(pgrep -x DieterMac || true)
        [[ "$remaining" -eq 0 ]] && { echo "Dieter exited cleanly."; exit 0; }
        sleep 0.25
    done
    echo "Dieter did not exit after its quit event; preserving the process for diagnosis." >&2
    just mac status >&2
    exit 1

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
    codesign --force --options runtime --timestamp --sign "$identity" \
        "{{ app_bundle }}/Contents/Frameworks/WebRTC.framework"
    codesign --force --options runtime --timestamp --sign "$identity" "{{ app_bundle }}"
    codesign --verify --deep --strict --verbose=2 "{{ app_bundle }}"
    ditto -c -k --sequesterRsrc --keepParent "{{ app_bundle }}" "$submission_path"
    xcrun notarytool submit "$submission_path" --key "$notary_key_path" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
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
    echo "$archive"

# Remove only the packaged macOS release archive.
[confirm]
clean-release:
    rm -f dist/Dieter-macOS-arm64.zip

# Check that the checked-in Swift protobuf clients match their inputs.
proto-check:
    DIETER_SWIFT_SCRATCH_PATH="$PWD/{{ app_scratch }}" {{ app_root }}/scripts/generate-swift-proto.sh --check

# Regenerate the checked-in Swift protobuf clients with the canonical cache.
proto-generate:
    DIETER_SWIFT_SCRATCH_PATH="$PWD/{{ app_scratch }}" {{ app_root }}/scripts/sync-proto.sh

# Run one safe packaged-app smoke suite: core, board, conversation, machine, sidebar, terminal, island, or workspace.
smoke suite="core": build
    just mac _smoke "{{ suite }}"

# Run every packaged-app smoke suite sequentially with one build.
smoke-all: build
    #!/usr/bin/env bash
    set -euo pipefail
    for suite in core board conversation machine sidebar terminal island workspace; do
        just mac _smoke "$suite"
    done

[private]
_smoke suite:
    swift run \
        --package-path "{{ app_root }}" \
        --scratch-path "$PWD/{{ app_scratch }}" \
        --only-use-versions-from-resolved-file \
        --manifest-cache local \
        --disable-index-store \
        DieterMacSmokeDriver \
        --suite "{{ suite }}" \
        --app "$PWD/{{ app_executable }}" \
        --output-root "$PWD/{{ app_root }}/.build/smoke"

# Remove disposable harness runtimes from retained smoke evidence.
[confirm]
prune-smoke-runtimes:
    find "{{ app_root }}/.build/smoke" -type d -path '*/fixture-home/dieter/runtime' -prune -exec rm -rf -- {} +

# Remove only the pre-Just SwiftPM cache; preserve both canonical caches and smoke evidence.
[confirm]
clean-legacy-cache:
    rm -rf \
        "{{ app_root }}/.build/arm64-apple-macosx" \
        "{{ app_root }}/.build/artifacts" \
        "{{ app_root }}/.build/checkouts" \
        "{{ app_root }}/.build/plugins" \
        "{{ app_root }}/.build/repositories" \
        "{{ app_root }}/.build/debug" \
        "{{ app_root }}/.build/.lock" \
        "{{ app_root }}/.build/build.db" \
        "{{ app_root }}/.build/debug.yaml" \
        "{{ app_root }}/.build/plugin-tools.yaml" \
        "{{ app_root }}/.build/workspace-state.json"

# Remove only smoke evidence and old smoke fixtures, never compilation caches.
[confirm]
clean-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf \
        "{{ app_root }}/.build/smoke" \
        "{{ app_root }}/.build/smoke-tools" \
        "{{ app_root }}/.build/accessibility-smoke" \
        "{{ app_root }}/.build/conversation-ui-smoke" \
        "{{ app_root }}/.build/island-ui-smoke" \
        "{{ app_root }}/.build/machine-ui-smoke" \
        "{{ app_root }}/.build/terminal-ui-smoke" \
        "{{ app_root }}/.build/ui-smoke" \
        "{{ app_root }}/.build/workspace-ui-smoke"
    find "{{ app_root }}/.build" -maxdepth 1 -type d -name 'sidebar-ui-smoke.*' -exec rm -rf -- {} +

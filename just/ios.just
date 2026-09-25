set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Verify Xcode and the iOS Simulator SDK.
doctor:
    xcodebuild -version
    xcrun --sdk iphonesimulator --show-sdk-version
    xcrun simctl list devices available

# Build the native iPhone/iPad app for Simulator without signing credentials.
build:
    xcodebuild -skipPackagePluginValidation -project apps/ios/DieterIOS.xcodeproj -scheme DieterIOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apps/ios/.build/DerivedData build-for-testing CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES

# Compile the native iPhone/iPad app for physical devices, without signing.
build-device:
    xcodebuild -skipPackagePluginValidation -project apps/ios/DieterIOS.xcodeproj -scheme DieterIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath apps/ios/.build/DerivedData build CODE_SIGNING_ALLOWED=NO

# Validate the dedicated iOS signing inputs without importing or uploading them.
signing-config:
    python3 scripts/ios_release.py signing-config

# Verify a versioned device archive locally without Apple signing credentials.
[positional-arguments]
archive-unsigned version build:
    python3 scripts/ios_release.py archive-unsigned "$@"

# Sign and export in CI; pass --upload explicitly to submit to App Store Connect.
[confirm]
[positional-arguments]
testflight version build *args:
    python3 scripts/ios_release.py testflight "$@"

# GitHub workflow entry point; untrusted version input stays in quoted arguments.
[confirm]
testflight-ci:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "TestFlight signing runs only in CI." >&2; exit 1; }
    : "${IOS_VERSION:?IOS_VERSION is required}"
    : "${IOS_BUILD_NUMBER:?IOS_BUILD_NUMBER is required}"
    args=(testflight "$IOS_VERSION" "$IOS_BUILD_NUMBER")
    case "${IOS_UPLOAD:-false}" in
        true) args+=(--upload) ;;
        false) ;;
        *) echo "IOS_UPLOAD must be true or false." >&2; exit 1 ;;
    esac
    python3 scripts/ios_release.py "${args[@]}"

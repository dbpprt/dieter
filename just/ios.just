set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Verify Xcode, the iOS Simulator SDK, and the Java runtime that builds the shared core.
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild -version
    xcrun --sdk iphonesimulator --show-sdk-version
    xcrun simctl list devices available
    # shared-framework.sh falls back to Android Studio's bundled JBR.
    java_home="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
    "$java_home/bin/java" -version

# Build the native iPhone/iPad app for Simulator without signing credentials.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${DIETER_APPLE_BUILD_LEASE:-}" != "$PWD" ]]; then
        exec python3 scripts/native_build_lock.py apple-build "$PWD" just ios build
    fi
    release_version="${DIETER_RELEASE_VERSION:-$(just release pseudo-version)}"
    # The app links the shared core; only its arm64 simulator slice is built.
    apps/mac/scripts/shared-framework.sh debug ios-simulator
    # A test plan from an earlier architecture set would leave the runner two to choose from.
    rm -f apps/ios/.build/DerivedData/Build/Products/*iphonesimulator*.xctestrun
    xcodebuild -skipPackagePluginValidation -project apps/ios/DieterIOS.xcodeproj -scheme DieterIOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apps/ios/.build/DerivedData build-for-testing ARCHS=arm64 CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES "DIETER_RELEASE_VERSION=$release_version"

# Compile the native iPhone/iPad app for physical devices, without signing.
build-device:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${DIETER_APPLE_BUILD_LEASE:-}" != "$PWD" ]]; then
        exec python3 scripts/native_build_lock.py apple-build "$PWD" just ios build-device
    fi
    release_version="${DIETER_RELEASE_VERSION:-$(just release pseudo-version)}"
    apps/mac/scripts/shared-framework.sh release all
    xcodebuild -skipPackagePluginValidation -project apps/ios/DieterIOS.xcodeproj -scheme DieterIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath apps/ios/.build/DerivedData build CODE_SIGNING_ALLOWED=NO "DIETER_RELEASE_VERSION=$release_version"

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

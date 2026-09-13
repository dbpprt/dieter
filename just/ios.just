set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Verify Xcode and the iOS Simulator SDK.
doctor:
    xcodebuild -version
    xcrun --sdk iphonesimulator --show-sdk-version
    xcrun simctl list devices available

# Build the native iPhone/iPad app for Simulator without signing credentials.
build:
    xcodebuild -project apps/ios/DieterIOS.xcodeproj -scheme DieterIOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apps/ios/.build/DerivedData build-for-testing CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES

# Compile the native iPhone/iPad app for physical devices, without signing.
build-device:
    xcodebuild -project apps/ios/DieterIOS.xcodeproj -scheme DieterIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath apps/ios/.build/DerivedData build CODE_SIGNING_ALLOWED=NO

# Run remote-node journeys against an isolated gateway in an owned simulator.
smoke device="iPhone 17 Pro":
    python3 apps/ios/Scripts/smoke.py --device '{{ device }}'

# Run the same remote-node journeys with iPad navigation.
smoke-ipad:
    just ios smoke 'iPad Pro 11-inch (M5)'

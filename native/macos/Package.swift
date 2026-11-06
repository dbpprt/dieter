// swift-tools-version: 6.2

import PackageDescription

// The daemon's macOS helpers and the remote-desktop protocol pieces the Apple
// clients share with them. `swift build -c release` builds the helpers;
// scripts/package-privacy-helper.sh assembles DieterPrivacyHelper.app.
let helperFrameworks: [LinkerSetting] = [
    "AppKit", "CoreGraphics", "CoreMedia", "CoreVideo", "Foundation", "IOKit", "Security",
    "ServiceManagement", "SystemConfiguration", "ScreenCaptureKit", "VideoToolbox",
].map { .linkedFramework($0) }

// The root privacy helper links only what it needs; serviceruntime's package
// smoke test rejects ScreenCaptureKit, VideoToolbox and AppKit in it.
let privacyFrameworks: [LinkerSetting] = [
    "Foundation", "IOKit", "Security", "ServiceManagement", "SystemConfiguration",
].map { .linkedFramework($0) }

let package = Package(
    name: "DieterNative",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // The screen key map and clipboard content shared by the capture helper
        // and the Apple clients (apps/apple/DieterKit), on macOS and iOS.
        .library(name: "RemoteDesktopProtocol", targets: ["RemoteDesktopProtocol"]),
        // Distribution identity generated from config/identity.json.
        .library(name: "DieterIdentity", targets: ["DieterIdentity"]),
        .executable(name: "dieter-capture", targets: ["dieter-capture"]),
        .executable(name: "dieter-privacy", targets: ["dieter-privacy"]),
        // A fixture window that receives injected input in screen tests.
        .executable(name: "InputTarget", targets: ["InputTarget"]),
    ],
    targets: [
        .target(name: "DieterIdentity"),
        .target(name: "RemoteDesktopProtocol"),
        // Creates CoreGraphics virtual displays through private Objective-C API;
        // it relies on ARC ownership of the created displays.
        .target(name: "VirtualDisplayBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        // The root privacy helper's socket protocol, shared by both helpers.
        .target(
            name: "PrivacyHIDProtocol",
            dependencies: ["DieterIdentity"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "dieter-capture",
            dependencies: ["RemoteDesktopProtocol", "VirtualDisplayBridge", "PrivacyHIDProtocol", "DieterIdentity"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: helperFrameworks),
        .executableTarget(
            name: "dieter-privacy",
            dependencies: ["PrivacyHIDProtocol", "DieterIdentity"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Development helpers trust the exact capture build they were
                // packaged with; release builds require Developer ID signatures.
                .define("DIETER_PRIVACY_DEVELOPMENT", .when(configuration: .debug)),
            ],
            linkerSettings: privacyFrameworks),
        .executableTarget(
            name: "InputTarget",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(
            name: "DieterNativeTests",
            dependencies: ["dieter-capture", "dieter-privacy", "PrivacyHIDProtocol", "RemoteDesktopProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]),
    ]
)

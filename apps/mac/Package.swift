// swift-tools-version: 6.2

import PackageDescription
import Foundation

// The iOS app (apps/ios) links the shared Compose UI and the Apple adapters the Mac
// app also uses. Its graph is selected with DIETER_SWIFT_PACKAGE=ios and keeps a
// separate scratch directory because it is a different dependency graph.
let package =
    ProcessInfo.processInfo.environment["DIETER_SWIFT_PACKAGE"] == "ios"
    ? Package(
        name: "DieterIOS",
        platforms: [.iOS(.v18)],
        products: [.library(name: "DieterIOS", targets: ["DieterIOS"])],
        dependencies: [
            .package(url: "https://github.com/apple/swift-certificates.git", from: "1.14.0"),
            .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
            .package(path: "Vendor/grpc-swift-nio-transport"),
            .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
            .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
        ],
        targets: [
            .binaryTarget(name: "DieterShared", path: "Frameworks/DieterMobile.xcframework"),
            .binaryTarget(
                name: "WebRTC",
                url: "https://github.com/stasel/WebRTC/releases/download/151.0.1/WebRTC-M151.xcframework.zip",
                checksum: "6f3f5693383ce65763190c46ca9f2c4325c34b83681acb9db30f01488e15f1e0"),
            .target(
                name: "DieterAPI", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
                path: "Sources/DieterAPI/Generated",
                exclude: ["gateway.grpc.swift", "dieter.grpc.swift", ".inputs.sha256"],
                sources: ["dieter.pb.swift", "gateway.pb.swift", "client_client.pb.swift"]),
            .target(
                name: "DieterTransport",
                dependencies: [
                    "WebRTC", "DieterAPI",
                    .product(name: "X509", package: "swift-certificates"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                ],
                sources: [
                    "DaemonCertificatePinning.swift", "DieterTransportTarget.swift", "ControlRTCBridge.swift",
                    "RemoteDesktopKeyMap.swift", "ScreenClipboardContent.swift",
                ]),
            .target(
                name: "SharedCore",
                dependencies: [
                    "DieterShared", "DieterTransport", "DieterAPI", "WebRTC",
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                ],
                sources: [
                    "CoreRpcBridge.swift", "CorePlatformServices.swift", "CoreKeychainSecureStore.swift",
                    "CoreControlChannels.swift", "Screens/CoreScreenMedia.swift", "Screens/IOSScreenVideoView.swift",
                    "Screens/IOSScreenInputView.swift", "Screens/ScreenCursorState.swift", "DieterTaskSleep.swift",
                    "Screens/CoreUIPasteboardClipboard.swift", "Screens/RemoteDesktopDecoderFactory.swift",
                    "Screens/RemoteDesktopHEVCDecoder.swift", "Screens/RemoteDesktopReferenceDependencies.swift",
                ]),
            .target(
                name: "DieterIOS",
                dependencies: [
                    "SharedCore", "DieterShared", "DieterAPI", "WebRTC",
                    .product(name: "SwiftTerm", package: "SwiftTerm"),
                ]),
        ]
    )
    : Package(
        name: "DieterMac",
        platforms: [.macOS(.v26)],
        products: [.executable(name: "DieterMac", targets: ["DieterMac"])],
        dependencies: [
            .package(url: "https://github.com/apple/swift-certificates.git", from: "1.14.0"),
            .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
            // Vendored from 2.9.0 with duration-based Task.sleep calls replaced by
            // nanosecond sleeps to avoid Swift #81771 on current macOS runtimes.
            .package(path: "Vendor/grpc-swift-nio-transport"),
            .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
            .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
            .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
            .package(path: "Vendor/swift-markdown-engine"),
        ],
        targets: [
            // The native transport pieces both clients share: the WebRTC control
            // channel, daemon certificate pinning, and gRPC resolver targets, and
            // the screen key map and clipboard content the capture helper
            // (native/macos-capture) also compiles by path.
            .target(
                name: "DieterTransport",
                dependencies: [
                    "WebRTC", "DieterAPI",
                    .product(name: "X509", package: "swift-certificates"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                ]),
            // The shared Kotlin core (apps/core), assembled into Frameworks/ by
            // fastlane/lib/dieter/platforms/framework.rb; Mac and iOS build/test lanes
            // refresh it when the core changes.
            .binaryTarget(name: "DieterShared", path: "Frameworks/DieterShared.xcframework"),
            // The apps' side of the shared core: the native transport and platform
            // services they inject, the command/slice client they observe, the
            // feature models both apps present, and the screen media engine.
            .target(
                name: "SharedCore",
                dependencies: [
                    "DieterShared", "DieterAPI", "DieterTransport", "WebRTC",
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                ]),
            .testTarget(
                name: "SharedCoreTests",
                dependencies: [
                    "SharedCore", "DieterShared", "DieterTransport", "DieterAPI",
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                ]),
            .target(
                name: "DieterAPI",
                dependencies: [
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                ],
                exclude: [
                    "gateway.proto",
                    "dieter.proto",
                    // The shared core's UI contract, copied by scripts/sync_apple_proto.py.
                    "client",
                    "grpc-swift-proto-generator-config.json",
                    "Generated/.inputs.sha256",
                ]
            ),
            .executableTarget(
                name: "DieterMac",
                dependencies: [
                    "DieterAPI", "SharedCore", "DieterShared", "DieterTransport",
                    // The gRPC client modules serve only the DEBUG UI smoke
                    // fixtures (Testing/SmokeFixtureClient.swift); SwiftPM cannot
                    // scope a dependency to one configuration.
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                    .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                    .product(name: "SwiftTerm", package: "SwiftTerm"),
                    .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                    .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
                    "WebRTC",
                ],
                resources: [.copy("Resources/MarkdownPreview"), .copy("Resources/MarkdownEditorLicenses.txt")],
                swiftSettings: [
                    .define("DIETER_UI_SMOKE", .when(configuration: .debug))
                ],
                linkerSettings: [
                    .unsafeFlags([
                        "-Xlinker", "-rpath",
                        "-Xlinker", "@executable_path/../Frameworks",
                    ])
                ]
            ),
            // The upstream 151.0.0 and 151.0.1 tags share a manifest whose
            // 151.0.0 asset URL was removed. Pin the surviving, byte-identical
            // 151.0.1 release asset directly so clean SwiftPM builds stay valid.
            .binaryTarget(
                name: "WebRTC",
                url: "https://github.com/stasel/WebRTC/releases/download/151.0.1/WebRTC-M151.xcframework.zip",
                checksum: "6f3f5693383ce65763190c46ca9f2c4325c34b83681acb9db30f01488e15f1e0"
            ),
            .testTarget(
                name: "DieterMacTests",
                dependencies: [
                    "DieterMac", "SharedCore", "DieterShared", "DieterTransport",
                    .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                    "DieterAPI",
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "SwiftTerm", package: "SwiftTerm"),
                ]
            ),
        ]
    )

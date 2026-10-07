// swift-tools-version: 6.2

import PackageDescription
import Foundation

// Portable iOS policies compile their production sources and the real Kotlin
// rules, without linking the Mac app, UIKit surfaces, WebRTC or gRPC transport.
// Keep a separate scratch directory because this is a different dependency graph.
let package =
    ProcessInfo.processInfo.environment["DIETER_SWIFT_TEST_SCOPE"] == "compose-spike"
    ? Package(
        name: "DieterComposeSpike",
        platforms: [.iOS(.v18)],
        products: [.library(name: "DieterComposeHost", targets: ["DieterComposeHost"])],
        dependencies: [
            .package(url: "https://github.com/apple/swift-certificates.git", from: "1.14.0"),
            .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
            .package(path: "Vendor/grpc-swift-nio-transport"),
        ],
        targets: [
            .binaryTarget(name: "DieterShared", path: "Frameworks/DieterComposeSpike.xcframework"),
            .target(
                name: "DieterTransport",
                dependencies: [
                    .product(name: "X509", package: "swift-certificates"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                ], sources: ["DaemonCertificatePinning.swift", "DieterTransportTarget.swift"]),
            .target(
                name: "SharedCore",
                dependencies: [
                    "DieterShared", "DieterTransport",
                    .product(name: "GRPCCore", package: "grpc-swift-2"),
                    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                ], sources: ["CoreRpcBridge.swift", "CorePlatformServices.swift", "CoreKeychainSecureStore.swift"]),
            .target(name: "DieterComposeHost", dependencies: ["SharedCore", "DieterShared"]),
        ]
    )
    : ProcessInfo.processInfo.environment["DIETER_SWIFT_TEST_SCOPE"] == "ios-policy"
        ? Package(
            name: "DieterIOSPolicy",
            platforms: [.macOS(.v26)],
            dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0")],
            targets: [
                .binaryTarget(name: "DieterShared", path: "Frameworks/DieterShared.xcframework"),
                .target(
                    name: "DieterAPI", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
                    path: "Sources/DieterAPI/Generated",
                    exclude: ["gateway.grpc.swift", "dieter.grpc.swift", ".inputs.sha256"],
                    sources: ["dieter.pb.swift", "gateway.pb.swift", "client_client.pb.swift"]),
                .target(
                    name: "SharedCore", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
                    path: "Sources/SharedCore", sources: ["SharedRulesSupport.swift"]),
                .target(
                    name: "DieterIOS", dependencies: ["SharedCore", "DieterShared", "DieterAPI"],
                    path: "Sources/DieterIOS",
                    sources: ["Model/IOSAttachments.swift", "Model/IOSConversationScroll.swift"]),
                .testTarget(
                    name: "DieterIOSTests", dependencies: ["DieterIOS", "DieterAPI"],
                    path: "Tests/DieterIOSTests", exclude: ["IOSCoreAdapterTests.swift"]),
            ]
        )
        : Package(
            name: "DieterMac",
            platforms: [.macOS(.v26), .iOS(.v18)],
            products: [
                // The application and its hosted native tests share this one framework.
                // Explicit linkage keeps Xcode from separately promoting transitive
                // automatic products (including Crypto/X509) into incomplete frameworks.
                .library(name: "DieterIOS", type: .dynamic, targets: ["DieterIOS"]),
                .executable(name: "DieterMac", targets: ["DieterMac"]),
            ],
            dependencies: [
                .package(url: "https://github.com/apple/swift-certificates.git", from: "1.14.0"),
                .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
                // Vendored from 2.9.0 with duration-based Task.sleep calls replaced by
                // nanosecond sleeps to avoid Swift #81771 on current macOS runtimes.
                .package(path: "Vendor/grpc-swift-nio-transport"),
                .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
                .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
                .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
                .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
                .package(path: "Vendor/swift-markdown-engine"),
            ],
            targets: [
                // The iOS app's sources: a presentation-only client of the shared
                // core.
                .target(
                    name: "DieterIOS",
                    dependencies: [
                        "SharedCore", "DieterShared", "DieterAPI",
                        // Message initializers from encoded rule results extend SwiftProtobuf's `Message`.
                        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                        .product(name: "SwiftTerm", package: "SwiftTerm"),
                        .product(name: "Textual", package: "textual"),
                        "WebRTC",
                    ]
                ),
                .testTarget(
                    name: "DieterIOSTests",
                    dependencies: [
                        "DieterIOS", "SharedCore", "DieterAPI",
                    ]),
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

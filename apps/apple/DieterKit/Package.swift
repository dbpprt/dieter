// swift-tools-version: 6.2

import PackageDescription

// The Apple clients' shared layer, for macOS (apps/apple/mac) and iOS
// (apps/apple/ios/Host): the Kotlin core framework, the generated API, the
// native transport, and the platform services both apps inject into the core.
let package = Package(
    name: "DieterKit",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        // The shared Kotlin core (apps/kotlin): :core:apple on macOS and :ui
        // (which exports the same façade) on iOS, both named DieterCore.
        .library(name: "DieterCore", targets: ["DieterCore"]),
        .library(name: "WebRTC", targets: ["WebRTC"]),
        .library(name: "DieterAPI", targets: ["DieterAPI"]),
        .library(name: "DieterAPIGRPC", targets: ["DieterAPIGRPC"]),
        .library(name: "DieterClientAPI", targets: ["DieterClientAPI"]),
        .library(name: "DieterTransport", targets: ["DieterTransport"]),
        .library(name: "DieterPlatform", targets: ["DieterPlatform"]),
    ],
    dependencies: [
        .package(path: "../../../native/macos"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        // Vendored from 2.11.0 with duration-based Task.sleep calls replaced by
        // nanosecond sleeps to avoid Swift #81771 (see its PATCHES.md).
        .package(path: "../../../third_party/grpc-swift-nio-transport"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        // Assembled from apps/kotlin by `gradlew link…Framework…` and
        // `xcodebuild -create-xcframework` (see apps/apple/README.md).
        .binaryTarget(name: "DieterCore", path: "../Frameworks/DieterCore.xcframework"),
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip",
            checksum: "cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe"
        ),
        // The network API's generated SwiftProtobuf messages (dieter.v1 and
        // the gateway; scripts/generate-swift-proto.sh).
        .target(
            name: "DieterAPI",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        // The core's generated client contract (Protos/client): the commands,
        // slices and rows the apps exchange with the core. Its messages embed
        // dieter.v1 values, but a file that imports only this module cannot
        // name dieter.v1 types, which keeps the Mac's API boundary checked.
        .target(
            name: "DieterClientAPI",
            dependencies: ["DieterAPI", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        // Generated grpc-swift v2 clients: the relay tunnel and the Mac tests' fixture client.
        .target(
            name: "DieterAPIGRPC",
            dependencies: [
                "DieterAPI",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        // The native transport: the WebRTC control channel, relay tunnels,
        // roster-pinned mutual TLS, and gRPC resolver targets. It re-exports
        // the screen key map and clipboard content shared with the capture
        // helper (native/macos).
        .target(
            name: "DieterTransport",
            dependencies: [
                "WebRTC", "DieterAPI", "DieterAPIGRPC",
                .product(name: "RemoteDesktopProtocol", package: "macos"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        // The apps' side of the core: the RPC bridge, relay tunnels, the
        // device key, platform services, Keychain store, control channels, and
        // the WebRTC screen media engine, which draws through each app's renderer.
        .target(
            name: "DieterPlatform",
            dependencies: [
                "DieterCore", "DieterAPI", "DieterClientAPI", "DieterTransport", "WebRTC",
                .product(name: "DieterIdentity", package: "macos"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "DieterPlatformTests",
            dependencies: [
                "DieterPlatform", "DieterCore", "DieterTransport", "DieterClientAPI", "DieterAPI", "DieterAPIGRPC",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
    ]
)

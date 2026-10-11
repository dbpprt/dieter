// swift-tools-version: 6.2

import PackageDescription

// The macOS app's library: Dieter.xcodeproj builds the app around the
// DieterMacKit product (embedding WebRTC.framework and the resource bundles,
// and signing), and the tests import it. Build the shared Kotlin framework and
// the Markdown preview bundle first (see apps/apple/README.md).
let package = Package(
    name: "DieterMac",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DieterMacKit", targets: ["DieterMacKit"])],
    dependencies: [
        .package(path: "../DieterKit"),
        .package(path: "../../../native/macos"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(path: "../../../third_party/grpc-swift-nio-transport"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
        .package(path: "../../../third_party/swift-markdown-engine"),
    ],
    targets: [
        // The Mac app's presentation (App/, DesignSystem/, Features/) over the
        // core's client contract (DieterClientAPI), and its protocol adapters
        // (Adapters/): the command/slice client, the keyed delta folds, and the
        // code that names the network API (DieterAPI). scripts/check-api-boundary.sh
        // fails on network API use outside Adapters/ not in api-boundary-allowlist.txt.
        .target(
            name: "DieterMacKit",
            dependencies: [
                .product(name: "DieterCore", package: "DieterKit"),
                .product(name: "DieterAPI", package: "DieterKit"),
                .product(name: "DieterClientAPI", package: "DieterKit"),
                .product(name: "DieterTransport", package: "DieterKit"),
                .product(name: "DieterPlatform", package: "DieterKit"),
                .product(name: "WebRTC", package: "DieterKit"),
                .product(name: "DieterIdentity", package: "macos"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
            ],
            // MarkdownPreview is built by scripts/build-markdown-preview.sh.
            resources: [.copy("Resources/MarkdownPreview"), .copy("Resources/MarkdownEditorLicenses.txt")],
            swiftSettings: [
                // The in-app Maestro flow runner (Sources/DieterMacKit/Testing).
                .define("DIETER_E2E", .when(configuration: .debug))
            ]
        ),
        // The doubles and fixtures the Mac tests share: the core's feature
        // surfaces over RPC fakes, slice fixtures, a plain gRPC client to
        // disposable fixture daemons, and the package's own directory for tests
        // that scan its sources. It lives beside the tests and only
        // DieterMacTests depends on it, so it never reaches the app; its
        // declarations are `package`, like the core adapters they script.
        .target(
            name: "DieterMacTestSupport",
            dependencies: [
                "DieterMacKit",
                .product(name: "DieterCore", package: "DieterKit"),
                .product(name: "DieterAPI", package: "DieterKit"),
                .product(name: "DieterClientAPI", package: "DieterKit"),
                .product(name: "DieterAPIGRPC", package: "DieterKit"),
                .product(name: "DieterTransport", package: "DieterKit"),
                .product(name: "DieterPlatform", package: "DieterKit"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/DieterMacTestSupport"
        ),
        .testTarget(
            name: "DieterMacTests",
            dependencies: [
                "DieterMacKit",
                "DieterMacTestSupport",
                .product(name: "DieterCore", package: "DieterKit"),
                .product(name: "DieterAPI", package: "DieterKit"),
                .product(name: "DieterClientAPI", package: "DieterKit"),
                .product(name: "DieterTransport", package: "DieterKit"),
                .product(name: "DieterPlatform", package: "DieterKit"),
                .product(name: "DieterIdentity", package: "macos"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)

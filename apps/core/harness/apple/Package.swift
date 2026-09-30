// swift-tools-version: 6.2
// Adapter harness: the shared KMP core (DieterShared) linked into Swift, with
// grpc-swift as the native transport extension and SwiftProtobuf for the
// dieter.v1 models and the dieter.client.v1 UI contract.
import PackageDescription

let package = Package(
    name: "CoreHarness",
    platforms: [.macOS(.v26), .iOS(.v18)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        // The Mac app's vendored transport (nanosecond sleeps for Swift #81771).
        .package(path: "../../../mac/Vendor/grpc-swift-nio-transport"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        .binaryTarget(name: "DieterShared", path: "DieterShared.xcframework"),
        .target(name: "DieterMessages", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(
            name: "CoreBridge",
            dependencies: [
                "DieterShared", "DieterMessages",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ]
        ),
        .testTarget(name: "CoreBridgeTests", dependencies: ["CoreBridge", "DieterMessages"]),
    ]
)

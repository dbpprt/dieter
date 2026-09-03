// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DieterMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DieterMac", targets: ["DieterMac"]),
        .executable(name: "DieterMacSmokeDriver", targets: ["DieterMacSmokeDriver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        // Vendored from 2.9.0 with duration-based Task.sleep calls replaced by
        // nanosecond sleeps to avoid Swift #81771 on current macOS runtimes.
        .package(path: "Vendor/grpc-swift-nio-transport"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.1"),
    ],
    targets: [
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
                "grpc-swift-proto-generator-config.json",
                "Generated/.inputs.sha256",
            ]
        ),
        .executableTarget(
            name: "DieterMac",
            dependencies: [
                "DieterAPI",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "WebRTC",
            ],
            swiftSettings: [
                .define("DIETER_UI_SMOKE", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "DieterMacSmokeDriver",
            path: "Tools/DieterMacSmokeDriver"
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
                "DieterMac",
                "DieterAPI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)

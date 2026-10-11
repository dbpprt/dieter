// swift-tools-version: 6.2

import PackageDescription

// The iOS app's Swift host for the shared Compose UI (apps/kotlin/ui), linked
// by Dieter.xcodeproj: the UIKit navigation shell, SwiftTerm terminals, the
// native pickers, and the Share extension handoff.
let package = Package(
    name: "DieterIOSHost",
    platforms: [.iOS(.v18)],
    products: [.library(name: "DieterIOS", targets: ["DieterIOS"])],
    dependencies: [
        .package(path: "../../DieterKit"),
        .package(path: "../../../../native/macos"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        .target(
            name: "DieterIOS",
            dependencies: [
                .product(name: "DieterCore", package: "DieterKit"),
                .product(name: "DieterAPI", package: "DieterKit"),
                .product(name: "DieterClientAPI", package: "DieterKit"),
                .product(name: "DieterPlatform", package: "DieterKit"),
                .product(name: "WebRTC", package: "DieterKit"),
                .product(name: "DieterIdentity", package: "macos"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        )
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OPN.Common",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Common", targets: ["Common"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "Common",
            dependencies: [
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
            ]
        ),
        .testTarget(name: "CommonTests", dependencies: ["Common"]),
    ],
    swiftLanguageModes: [.v6]
)

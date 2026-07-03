// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OPN.Common",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Common", targets: ["Common"]),
    ],
    dependencies: [
        .package(path: "../GFN.CloudMatch"),
        .package(path: "../GFN.GDN"),
        .package(path: "../GFN.NetworkTest"),
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "Common",
            dependencies: [
                .product(name: "CloudMatch", package: "GFN.CloudMatch"),
                .product(name: "GDN", package: "GFN.GDN"),
                .product(name: "NetworkTest", package: "GFN.NetworkTest"),
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
            ]
        ),
        .testTarget(name: "CommonTests", dependencies: ["Common"]),
    ],
    swiftLanguageModes: [.v6]
)

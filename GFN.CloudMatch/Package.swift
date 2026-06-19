// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.CloudMatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudMatch", targets: ["CloudMatch"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "CloudMatch",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "CloudMatchTests", dependencies: ["CloudMatch"]),
    ],
    swiftLanguageModes: [.v6]
)

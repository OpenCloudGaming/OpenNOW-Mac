// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.NVST",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NVST", targets: ["NVST"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "NVST",
            dependencies: [
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
            ]
        ),
        .testTarget(name: "NVSTTests", dependencies: ["NVST"]),
    ],
    swiftLanguageModes: [.v6]
)

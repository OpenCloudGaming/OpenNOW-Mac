// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.Ragnarok",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Ragnarok", targets: ["Ragnarok"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "Ragnarok",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "RagnarokTests", dependencies: ["Ragnarok"]),
    ],
    swiftLanguageModes: [.v6]
)

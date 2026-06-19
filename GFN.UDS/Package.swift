// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.UDS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UDS", targets: ["UDS"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "UDS",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "UDSTests", dependencies: ["UDS"]),
    ],
    swiftLanguageModes: [.v6]
)

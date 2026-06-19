// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.LCARS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LCARS", targets: ["LCARS"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "LCARS",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "LCARSTests", dependencies: ["LCARS"]),
    ],
    swiftLanguageModes: [.v6]
)

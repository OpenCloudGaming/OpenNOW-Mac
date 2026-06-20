// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.GDN",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GDN", targets: ["GDN"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "GDN",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "GDNTests", dependencies: ["GDN"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.Starfleet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Starfleet", targets: ["Starfleet"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "Starfleet",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "StarfleetTests", dependencies: ["Starfleet"]),
    ],
    swiftLanguageModes: [.v6]
)

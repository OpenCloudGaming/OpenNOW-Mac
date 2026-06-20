// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OPN.Auth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWAuth", targets: ["OpenNOWAuth"]),
    ],
    dependencies: [
        .package(path: "../GFN.Jarvis"),
        .package(path: "../GFN.Starfleet"),
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "OpenNOWAuth",
            dependencies: [
                .product(name: "Jarvis", package: "GFN.Jarvis"),
                .product(name: "Starfleet", package: "GFN.Starfleet"),
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

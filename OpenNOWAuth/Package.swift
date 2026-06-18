// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OPN.OpenNOWAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWAuth", targets: ["OpenNOWAuth"]),
    ],
    dependencies: [
        .package(path: "../Jarvis"),
        .package(path: "../Starfleet"),
        .package(path: "../OpenNOWTelemetry"),
    ],
    targets: [
        .target(
            name: "OpenNOWAuth",
            dependencies: [
                "Jarvis",
                "Starfleet",
                "OpenNOWTelemetry",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

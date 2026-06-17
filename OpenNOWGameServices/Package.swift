// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OpenNOWGameServices",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWGameServices", targets: ["OpenNOWGameServices"]),
    ],
    dependencies: [
        .package(path: "../Common"),
        .package(path: "../Jarvis"),
        .package(path: "../OpenNOWTelemetry"),
    ],
    targets: [
        .target(
            name: "OpenNOWGameServices",
            dependencies: [
                "Common",
                "Jarvis",
                "OpenNOWTelemetry",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

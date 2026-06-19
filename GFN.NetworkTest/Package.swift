// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.NetworkTest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetworkTest", targets: ["NetworkTest"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "NetworkTest",
            dependencies: [.product(name: "OpenNOWTelemetry", package: "OPN.Telemetry")]
        ),
        .testTarget(name: "NetworkTestTests", dependencies: ["NetworkTest"]),
    ],
    swiftLanguageModes: [.v6]
)

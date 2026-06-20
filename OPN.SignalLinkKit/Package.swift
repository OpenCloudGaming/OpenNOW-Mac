// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OPN.SignalLinkKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SignalLinkKit", targets: ["SignalLinkKit"]),
    ],
    dependencies: [
        .package(path: "../OPN.Telemetry"),
    ],
    targets: [
        .target(
            name: "SignalLinkKit",
            dependencies: [
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
            ],
            path: "Sources/SignalLinkKit"
        ),
    ],
    swiftLanguageModes: [.v6]
)

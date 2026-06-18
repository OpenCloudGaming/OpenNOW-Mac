// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OPN.OpenNOWTelemetry",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWTelemetry", targets: ["OpenNOWTelemetry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.17.1"),
    ],
    targets: [
        .target(
            name: "OpenNOWTelemetry",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

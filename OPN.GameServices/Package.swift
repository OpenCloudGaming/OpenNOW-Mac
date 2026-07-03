// swift-tools-version: 6.3

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let webRTCFrameworkSearchPath = packageRoot
    .appendingPathComponent("..")
    .standardizedFileURL
    .path

let package = Package(
    name: "OPN.GameServices",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWGameServices", targets: ["OpenNOWGameServices"]),
    ],
    dependencies: [
        .package(path: "../GFN.CloudMatch"),
        .package(path: "../GFN.LCARS"),
        .package(path: "../GFN.UDS"),
        .package(path: "../OPN.Common"),
        .package(path: "../GFN.Jarvis"),
        .package(path: "../OPN.Telemetry"),
        .package(path: "../OPN.SignalLinkKit"),
        .package(path: "../OPN.WebRTC.Media"),
    ],
    targets: [
        .target(
            name: "OpenNOWGameServices",
            dependencies: [
                .product(name: "CloudMatch", package: "GFN.CloudMatch"),
                .product(name: "LCARS", package: "GFN.LCARS"),
                .product(name: "UDS", package: "GFN.UDS"),
                .product(name: "Common", package: "OPN.Common"),
                .product(name: "Jarvis", package: "GFN.Jarvis"),
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
                .product(name: "SignalLinkKit", package: "OPN.SignalLinkKit"),
                .product(name: "WebRTCMedia", package: "OPN.WebRTC.Media"),
            ],
            swiftSettings: [
                .unsafeFlags(["-F", webRTCFrameworkSearchPath, "-Xcc", "-Wno-incomplete-umbrella"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F", webRTCFrameworkSearchPath, "-framework", "WebRTC", "-Xlinker", "-rpath", "-Xlinker", webRTCFrameworkSearchPath]),
            ]
        ),
        .testTarget(
            name: "OpenNOWGameServicesTests",
            dependencies: [
                "OpenNOWGameServices",
                .product(name: "WebRTCMedia", package: "OPN.WebRTC.Media"),
            ],
            swiftSettings: [
                .unsafeFlags(["-F", webRTCFrameworkSearchPath, "-Xcc", "-Wno-incomplete-umbrella"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F", webRTCFrameworkSearchPath, "-framework", "WebRTC", "-Xlinker", "-rpath", "-Xlinker", webRTCFrameworkSearchPath]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

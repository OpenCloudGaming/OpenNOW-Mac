// swift-tools-version: 6.3

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let webRTCFrameworkSearchPath = packageRoot
    .appendingPathComponent("..")
    .standardizedFileURL
    .path

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
        .package(path: "../SignalLinkKit"),
        .package(path: "../WebRTC.Media"),
    ],
    targets: [
        .target(
            name: "OpenNOWGameServices",
            dependencies: [
                "Common",
                "Jarvis",
                "OpenNOWTelemetry",
                "SignalLinkKit",
                .product(name: "WebRTCMedia", package: "WebRTC.Media"),
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

// swift-tools-version: 6.3

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let webRTCFrameworkSearchPath = packageRoot
    .appendingPathComponent("..")
    .standardizedFileURL
    .path

let package = Package(
    name: "OPN.WebRTC.Media",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WebRTC.Media", targets: ["WebRTCMedia"]),
        .library(name: "WebRTCMedia", targets: ["WebRTCMedia"]),
    ],
    dependencies: [
        .package(path: "../GFN.NVST"),
        .package(path: "../OPN.Design"),
    ],
    targets: [
        .target(
            name: "WebRTCMedia",
            dependencies: [
                .product(name: "NVST", package: "GFN.NVST"),
                .product(name: "OpenNOWDesignSystem", package: "OPN.Design"),
            ],
            swiftSettings: [
                .unsafeFlags(["-F", webRTCFrameworkSearchPath, "-Xcc", "-Wno-incomplete-umbrella"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F", webRTCFrameworkSearchPath, "-framework", "WebRTC"]),
            ]
        ),
        .testTarget(
            name: "WebRTCMediaTests",
            dependencies: ["WebRTCMedia"],
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

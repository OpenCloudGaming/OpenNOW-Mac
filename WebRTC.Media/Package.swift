// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "WebRTC.Media",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WebRTC.Media", targets: ["WebRTCMedia"]),
        .library(name: "WebRTCMedia", targets: ["WebRTCMedia"]),
    ],
    targets: [
        .target(name: "WebRTCMedia"),
        .testTarget(name: "WebRTCMediaTests", dependencies: ["WebRTCMedia"]),
    ],
    swiftLanguageModes: [.v6]
)

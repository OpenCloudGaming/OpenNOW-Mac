// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OPN.Twitch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWTwitch", targets: ["OpenNOWTwitch"]),
    ],
    targets: [
        .target(name: "OpenNOWTwitch"),
        .testTarget(name: "OpenNOWTwitchTests", dependencies: ["OpenNOWTwitch"]),
    ],
    swiftLanguageModes: [.v6]
)

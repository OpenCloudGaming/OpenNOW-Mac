// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NesAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NesAuth", targets: ["NesAuth"]),
    ],
    targets: [
        .target(name: "NesAuth"),
        .testTarget(name: "NesAuthTests", dependencies: ["NesAuth"]),
    ],
    swiftLanguageModes: [.v6]
)

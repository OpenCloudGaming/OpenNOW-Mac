// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.CloudMatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudMatch", targets: ["CloudMatch"]),
    ],
    targets: [
        .target(name: "CloudMatch"),
        .testTarget(name: "CloudMatchTests", dependencies: ["CloudMatch"]),
    ],
    swiftLanguageModes: [.v6]
)

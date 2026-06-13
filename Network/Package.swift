// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Network",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWNetwork", targets: ["OpenNOWNetwork"]),
    ],
    targets: [
        .target(name: "OpenNOWNetwork", path: "Sources/Network"),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenNOWNetwork",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWNetwork", targets: ["OpenNOWNetwork"]),
    ],
    targets: [
        .target(name: "OpenNOWNetwork"),
    ],
    swiftLanguageModes: [.v6]
)

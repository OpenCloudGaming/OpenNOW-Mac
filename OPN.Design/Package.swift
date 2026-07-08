// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OPN.Design",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWDesignSystem", targets: ["OpenNOWDesignSystem"]),
    ],
    targets: [
        .target(name: "OpenNOWDesignSystem"),
    ],
    swiftLanguageModes: [.v6]
)

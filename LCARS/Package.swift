// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LCARS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LCARS", targets: ["LCARS"]),
    ],
    targets: [
        .target(name: "LCARS"),
        .testTarget(name: "LCARSTests", dependencies: ["LCARS"]),
    ],
    swiftLanguageModes: [.v6]
)

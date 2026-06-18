// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OPN.Common",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Common", targets: ["Common"]),
    ],
    targets: [
        .target(name: "Common"),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFNErrorMapping",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GFNErrorMapping", targets: ["GFNErrorMapping"]),
    ],
    targets: [
        .target(name: "GFNErrorMapping"),
    ],
    swiftLanguageModes: [.v6]
)

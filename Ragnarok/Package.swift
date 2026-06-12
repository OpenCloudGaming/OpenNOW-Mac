// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Ragnarok",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Ragnarok", targets: ["Ragnarok"]),
    ],
    targets: [
        .target(name: "Ragnarok"),
        .testTarget(name: "RagnarokTests", dependencies: ["Ragnarok"]),
    ],
    swiftLanguageModes: [.v6]
)

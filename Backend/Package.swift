// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Backend",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Backend", targets: ["Backend"]),
    ],
    targets: [
        .target(name: "Backend"),
    ],
    swiftLanguageModes: [.v6]
)

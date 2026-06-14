// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UDS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UDS", targets: ["UDS"]),
    ],
    targets: [
        .target(name: "UDS"),
        .testTarget(name: "UDSTests", dependencies: ["UDS"]),
    ],
    swiftLanguageModes: [.v6]
)

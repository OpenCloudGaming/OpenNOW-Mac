// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "InputProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InputProtocol", targets: ["InputProtocol"]),
    ],
    targets: [
        .target(name: "InputProtocol"),
    ],
    swiftLanguageModes: [.v6]
)

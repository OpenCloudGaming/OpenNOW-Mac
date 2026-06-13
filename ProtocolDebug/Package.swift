// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProtocolDebug",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProtocolDebug", targets: ["ProtocolDebug"]),
    ],
    targets: [
        .target(name: "ProtocolDebug"),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StreamingClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StreamingClient", targets: ["StreamingClient"]),
    ],
    targets: [
        .target(name: "StreamingClient"),
    ],
    swiftLanguageModes: [.v6]
)

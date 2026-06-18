// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.GDN",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GDN", targets: ["GDN"]),
    ],
    targets: [
        .target(name: "GDN"),
        .testTarget(name: "GDNTests", dependencies: ["GDN"]),
    ],
    swiftLanguageModes: [.v6]
)

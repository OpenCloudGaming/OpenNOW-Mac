// swift-tools-version: 6.0
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Jarvis", targets: ["Jarvis"]),
    ],
    targets: [
        .target(name: "Jarvis"),
        .testTarget(name: "JarvisTests", dependencies: ["Jarvis"]),
    ],
    swiftLanguageModes: [.v6]
)

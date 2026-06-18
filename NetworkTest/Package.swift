// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GFN.NetworkTest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetworkTest", targets: ["NetworkTest"]),
    ],
    targets: [
        .target(name: "NetworkTest"),
        .testTarget(name: "NetworkTestTests", dependencies: ["NetworkTest"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Starfleet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Starfleet", targets: ["Starfleet"]),
    ],
    targets: [
        .target(name: "Starfleet"),
        .testTarget(name: "StarfleetTests", dependencies: ["Starfleet"]),
    ],
    swiftLanguageModes: [.v6]
)

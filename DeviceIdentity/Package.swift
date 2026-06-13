// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DeviceIdentity",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceIdentity", targets: ["DeviceIdentity"]),
    ],
    targets: [
        .target(name: "DeviceIdentity"),
    ],
    swiftLanguageModes: [.v6]
)

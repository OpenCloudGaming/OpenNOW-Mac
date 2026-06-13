// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppPreferenceStorage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppPreferenceStorage", targets: ["AppPreferenceStorage"]),
    ],
    targets: [
        .target(name: "AppPreferenceStorage"),
    ],
    swiftLanguageModes: [.v6]
)

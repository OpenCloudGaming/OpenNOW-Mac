// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppPreferences",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppPreferences", targets: ["AppPreferences"]),
    ],
    dependencies: [
        .package(path: "../DeviceIdentity"),
        .package(path: "../ProtocolDebug"),
    ],
    targets: [
        .target(
            name: "AppPreferences",
            dependencies: ["DeviceIdentity", "ProtocolDebug"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

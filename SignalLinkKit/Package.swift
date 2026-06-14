// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SignalLinkKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SignalLinkKit", targets: ["SignalLinkKit"]),
    ],
    targets: [
        .target(name: "SignalLinkKit", path: "Sources/SignalLinkKit"),
    ],
    swiftLanguageModes: [.v6]
)

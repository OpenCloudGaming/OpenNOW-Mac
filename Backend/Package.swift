// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Backend",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Backend", targets: ["Backend"]),
    ],
    dependencies: [
        .package(path: "../Common"),
        .package(path: "../SignalLinkKit"),
        .package(path: "../Jarvis"),
        .package(path: "../Starfleet"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.17.1"),
    ],
    targets: [
        .target(
            name: "Backend",
            dependencies: [
                "Common",
                .product(name: "SignalLinkKit", package: "SignalLinkKit"),
                .product(name: "Jarvis", package: "Jarvis"),
                .product(name: "Starfleet", package: "Starfleet"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            swiftSettings: [
                .unsafeFlags(["-F", "../third_party/webrtc-official"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F", "../third_party/webrtc-official", "-framework", "WebRTC"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

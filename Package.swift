// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "MacForceNow",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MacForceNow", targets: ["MacForceNow"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.18.0")
    ],
    targets: [
        .target(
            name: "MacForceNow",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: ".",
            exclude: [
                "AGENTS.md",
                "LICENSE",
                "README.md",
                "MacForceNowApp.swift",
                "OPN/Stream/WebRTCMediaStreamSurface.swift",
                "MacForceNow.xcodeproj",
                "Resources",
                "Tests",
                "View",
                "ViewModel",
                "WebRTC.framework",
                "build",
                "scripts",
                "tools",
                "vendor"
            ],
            sources: [
                "Model",
                "OPN",
                "GFN"
            ],
            swiftSettings: [
                .unsafeFlags(["-F", packageRoot, "-Xcc", "-Wno-incomplete-umbrella"])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", packageRoot, "-framework", "WebRTC", "-Xlinker", "-rpath", "-Xlinker", packageRoot])
            ]
        ),
        .testTarget(
            name: "MacForceNowTests",
            dependencies: ["MacForceNow"],
            path: "Tests",
            swiftSettings: [
                .unsafeFlags(["-F", packageRoot, "-Xcc", "-Wno-incomplete-umbrella"])
            ]
        )
    ]
)

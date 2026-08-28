// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "OpenNOW",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenNOW", targets: ["OpenNOW"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.18.0")
    ],
    targets: [
        .target(
            name: "OpenNOW",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: ".",
            exclude: [
                "DerivedData",
                "AGENTS.md",
                "CHANGELOG.md",
                "DESIGN.md",
                "LICENSE",
                "README.md",
                "release-please-config.json",
                "OpenNOW-Info.plist",
                "OpenNOW.entitlements",
                "OpenNOWApp.swift",
                "OpenNOW.xcodeproj",
                "RemoteCoOp",
                "Resources",
                "Tests",
                "docs",
                "View/.DS_Store",
                "View/Assets.xcassets",
                "WebRTC.framework",
                "build",
                "scripts",
                "tools",
            ],
            sources: [
                "App",
                "Model",
                "OPN",
                "GFN",
                "View",
                "ViewModel"
            ],
            resources: [
                .process("View/Assets.xcassets")
            ],
            swiftSettings: [
                .unsafeFlags(["-F", packageRoot, "-Xcc", "-Wno-incomplete-umbrella"])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", packageRoot, "-framework", "WebRTC", "-Xlinker", "-rpath", "-Xlinker", packageRoot])
            ]
        ),
        .testTarget(
            name: "OpenNOWTests",
            dependencies: ["OpenNOW"],
            path: "Tests",
            // Read through `#filePath`, not `Bundle.module`, so they must not be bundled — but they
            // do have to be declared, or every build warns about unhandled files.
            exclude: ["GFN/NVST/Fixtures"],
            swiftSettings: [
                .unsafeFlags(["-F", packageRoot, "-Xcc", "-Wno-incomplete-umbrella"])
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)

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
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.18.0"),
        // Layering lint (see docs/MVVMMigrationPlan.md). Ships SwiftLint as a prebuilt binary
        // artifact rather than building it from source, so resolving costs seconds, not minutes.
        // Wired as a *command* plugin only — deliberately not attached to the OpenNOW target as a
        // build tool plugin, because this package builds through both SwiftPM and the Xcode app
        // target and a build tool plugin would run on every build of both.
        //
        //   swift package plugin --allow-writing-to-package-directory swiftlint lint \
        //     --strict App GFN Model OPN View ViewModel Tests
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.65.1"),
        // Hosted signaling (see RemoteCoOp/hosted-signaling-plan.md). Pinned exactly, like Sentry:
        // this carries the signaling for a live session, and an unattended minor bump is not
        // something to discover mid-stream.
        .package(url: "https://github.com/ably/ably-cocoa.git", exact: "1.3.0")
    ],
    targets: [
        .target(
            name: "OpenNOW",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Ably", package: "ably-cocoa")
            ],
            path: ".",
            exclude: [
                "DerivedData",
                "AGENTS.md",
                "CHANGELOG.md",
                "CHANGELOG-legacy.md",
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

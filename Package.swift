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
                .product(name: "Sentry", package: "sentry-cocoa"),
                "MacForceNowNativeGeronimoShim"
            ],
            path: ".",
            exclude: [
                "AGENTS.md",
                "CHANGELOG.md",
                "DESIGN.md",
                "LICENSE",
                "README.md",
                "release-please-config.json",
                "MacForceNow-Info.plist",
                "MacForceNow.entitlements",
                "MacForceNowApp.swift",
                "MacForceNow.xcodeproj",
                "OPN/NativeGeronimo",
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
                "vendor"
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
        .target(
            name: "MacForceNowNativeGeronimoShim",
            path: "OPN/NativeGeronimo",
            sources: ["NativeNVSTGeronimoShim.mm"],
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "MacForceNowTests",
            dependencies: ["MacForceNow"],
            path: "Tests",
            swiftSettings: [
                .unsafeFlags(["-F", packageRoot, "-Xcc", "-Wno-incomplete-umbrella"])
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(packageRoot)/vendor/gfn-runtime/Frameworks"])
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)

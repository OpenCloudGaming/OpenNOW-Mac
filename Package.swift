// swift-tools-version: 6.0

import PackageDescription

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
        // Vendored, patched Quiver (QUIC + HTTP/3 + WebTransport) for the browser Co-Op egress.
        // See Vendor/Quiver/VENDORING.md.
        .package(path: "Vendor/Quiver"),
        // Hosted signaling (see RemoteCoOp/hosted-signaling-plan.md). Pinned exactly, like Sentry:
        // this carries the signaling for a live session, and an unattended minor bump is not
        // something to discover mid-stream.
        .package(url: "https://github.com/ably/ably-cocoa.git", exact: "1.4.0")
    ],
    targets: [
        // The native NVST bundle's protocol libraries (milestone 4), built as *static* frameworks
        // so nothing has to be embedded or re-signed at runtime. Derivation and pins in
        // Resources/Licenses/THIRD_PARTY_NOTICES.md.
        .binaryTarget(name: "OpenSSL", path: "Vendor/OpenSSL.xcframework"),
        .binaryTarget(name: "usrsctp", path: "Vendor/usrsctp.xcframework"),
        .target(
            name: "OpenNOW",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Ably", package: "ably-cocoa"),
                .product(name: "HTTP3", package: "Quiver"),
                .product(name: "QUIC", package: "Quiver"),
                .product(name: "QUICCrypto", package: "Quiver"),
                "OpenSSL",
                "usrsctp"
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
                "OPNApp.swift",
                "OpenNOW.xcodeproj",
                "Benchmarks",
                "RemoteCoOp",
                "Resources",
                "Tests",
                "docs",
                "Vendor",
                "View/Assets.xcassets",
                "build",
                "scripts",
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
            cSettings: [
                // OpenSSL's own headers include each other as `<openssl/...>`, so the directory
                // that *contains* `openssl/` has to be on the include path — a binary target only
                // contributes its framework search path, which is not enough.
                .headerSearchPath("Vendor/OpenSSL.xcframework/macos-arm64/OpenSSL.framework/Headers"),
                .headerSearchPath("Vendor/usrsctp.xcframework/macos-arm64/usrsctp.framework/Headers"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"])
            ]
        ),
        .testTarget(
            name: "OpenNOWTests",
            dependencies: ["OpenNOW", "OpenSSL", "usrsctp"],
            path: "Tests",
            cSettings: [
                .headerSearchPath("../Vendor/OpenSSL.xcframework/macos-arm64/OpenSSL.framework/Headers"),
                .headerSearchPath("../Vendor/usrsctp.xcframework/macos-arm64/usrsctp.framework/Headers"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"])
            ]
        ),
        // Benchmark harnesses that ran inside the test suite as env-gated, never-failing "@Tests".
        // They measure what tests deliberately do not assert on, so they live in a runnable tool
        // instead: `swift run OpenNOWBenchmarks catalog|stream-preferences|relay-conversion`.
        // `-enable-testing` lets the audits reach the module's internal types, exactly as @testable
        // did from the test target.
        .executableTarget(
            name: "OpenNOWBenchmarks",
            dependencies: ["OpenNOW", "OpenSSL", "usrsctp"],
            path: "Benchmarks",
            cSettings: [
                .headerSearchPath("../Vendor/OpenSSL.xcframework/macos-arm64/OpenSSL.framework/Headers"),
                .headerSearchPath("../Vendor/usrsctp.xcframework/macos-arm64/usrsctp.framework/Headers"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"]),
                .unsafeFlags(["-enable-testing"])
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)

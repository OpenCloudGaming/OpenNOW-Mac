// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OpenNOWWorkspace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenNOWWorkspace", targets: ["OpenNOWWorkspace"]),
    ],
    dependencies: [
        .package(path: "GFN.CloudMatch"),
        .package(path: "GFN.GDN"),
        .package(path: "GFN.Jarvis"),
        .package(path: "GFN.LCARS"),
        .package(path: "GFN.NesAuth"),
        .package(path: "GFN.NetworkTest"),
        .package(path: "GFN.Starfleet"),
        .package(path: "GFN.UDS"),
        .package(path: "OPN.Auth"),
        .package(path: "OPN.Common"),
        .package(path: "OPN.Design"),
        .package(path: "OPN.GameServices"),
        .package(path: "OPN.SignalLinkKit"),
        .package(path: "OPN.Telemetry"),
        .package(path: "OPN.Twitch"),
        .package(path: "OPN.WebRTC.Media"),
    ],
    targets: [
        .target(
            name: "OpenNOWWorkspace",
            dependencies: [
                .product(name: "CloudMatch", package: "GFN.CloudMatch"),
                .product(name: "GDN", package: "GFN.GDN"),
                .product(name: "Jarvis", package: "GFN.Jarvis"),
                .product(name: "LCARS", package: "GFN.LCARS"),
                .product(name: "NesAuth", package: "GFN.NesAuth"),
                .product(name: "NetworkTest", package: "GFN.NetworkTest"),
                .product(name: "Starfleet", package: "GFN.Starfleet"),
                .product(name: "UDS", package: "GFN.UDS"),
                .product(name: "OpenNOWAuth", package: "OPN.Auth"),
                .product(name: "Common", package: "OPN.Common"),
                .product(name: "OpenNOWDesignSystem", package: "OPN.Design"),
                .product(name: "OpenNOWGameServices", package: "OPN.GameServices"),
                .product(name: "SignalLinkKit", package: "OPN.SignalLinkKit"),
                .product(name: "OpenNOWTelemetry", package: "OPN.Telemetry"),
                .product(name: "OpenNOWTwitch", package: "OPN.Twitch"),
                .product(name: "WebRTCMedia", package: "OPN.WebRTC.Media"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

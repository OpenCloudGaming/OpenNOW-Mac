// swift-tools-version: 6.2
//
// Vendored, slimmed Quiver — see VENDORING.md.
//
// Differences from upstream (d3b0cdc56b57775adebd771558245913b4a7e728):
//   * Only the library products the app consumes; tests, examples, benchmarks and the DocC plugin
//     are removed to keep the committed tree small.
//   * QUICCrypto is exposed as a library product, and its `package` access was lifted to `public`,
//     so an external package can build a TLS provider (upstream is internal-use only).

import PackageDescription

let package = Package(
    name: "Quiver",

    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],

    products: [
        .library(name: "QUIC", targets: ["QUIC"]),
        .library(name: "QUICCore", targets: ["QUICCore"]),
        .library(name: "QPACK", targets: ["QPACK"]),
        .library(name: "HTTP3", targets: ["HTTP3"]),
        .library(name: "QUICCrypto", targets: ["QUICCrypto"]),
    ],

    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.92.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.5.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.9.1"),
    ],

    targets: [
        .target(
            name: "QUICCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/QUICCore"
        ),
        .target(
            name: "QUICCrypto",
            dependencies: [
                "QUICCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Sources/QUICCrypto"
        ),
        .target(
            name: "NIOUDPTransport",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/NIOUDPTransport"
        ),
        .target(
            name: "QUICConnection",
            dependencies: [
                "QUICCore",
                "QUICCrypto",
                "QUICStream",
                "QUICRecovery",
                "QUICTransport",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/QUICConnection"
        ),
        .target(
            name: "QUICStream",
            dependencies: [
                "QUICCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/QUICStream"
        ),
        .target(
            name: "QUICRecovery",
            dependencies: ["QUICCore"],
            path: "Sources/QUICRecovery"
        ),
        .target(
            name: "QUICTransport",
            dependencies: [
                "QUICCore",
                "NIOUDPTransport",
            ],
            path: "Sources/QUICTransport"
        ),
        .target(
            name: "QUIC",
            dependencies: [
                "QUICCore",
                "QUICCrypto",
                "QUICConnection",
                "QUICStream",
                "QUICRecovery",
                "QUICTransport",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/QUIC"
        ),
        .target(
            name: "QPACK",
            dependencies: [],
            path: "Sources/QPACK"
        ),
        .target(
            name: "HTTP3",
            dependencies: [
                "QUIC",
                "QPACK",
                "QUICCore",
                "QUICStream",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/HTTP3"
        ),
    ]
)

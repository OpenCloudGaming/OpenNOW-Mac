# OpenNOW

OpenNOW is a native macOS cloud gaming client for browsing, launching, streaming, and recording GeForce NOW sessions.

## Current State

The repository contains a SwiftUI app target plus service, protocol, authentication, streaming, telemetry, and a root Swift package for tests. The visible frontend lives under `View` and includes:

- OAuth sign-in and branded loading surfaces
- Catalog home with a six-image hero rotation, game rails, search, filters, and detail panels
- Persistent favorites and library rails for quick game access across restarts
- Store ownership picker and launch/session overlays
- Native WebRTC streaming with input, microphone, audio, video enhancement, and diagnostics paths
- Local gameplay recordings with saved metadata and a recordings browser
- Settings for account, connections, gameplay, server location, upscaling, system, and diagnostics

## Project Layout

- `Model` - persisted SwiftData models, DTOs, stream value types, Twitch realtime models, and catalog value objects
- `View` - SwiftUI/AppKit views, stream host views, design primitives, asset catalogs, and bundled resources
- `ViewModel` - observable UI state and presentation coordination for login, catalog, controller catalog, and recordings
- `OPN` - app entry/configuration, authentication, catalog/session services, native WebRTC, telemetry, Twitch, preferences, logging, and app infrastructure
- `GFN` - protocol-specific GeForce NOW clients and wire types, including CloudMatch, GDN, Jarvis, LCARS, NesAuth, NetworkTest, NVST, Starfleet, and UDS
- `Tests` - root SwiftPM test target covering the package-exposed production logic

## Packages

The root `Package.swift` exposes a testable `OpenNOW` library target over non-app-entry production logic from `Model`, `OPN`, and `GFN`. The Xcode app target compiles all five production directories, including `View` and `ViewModel`.

## Building

Build the macOS app from the repository root:

```sh
xcodebuild build -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO
```

## Testing

Run package tests from the repository root so SwiftPM uses one shared `.build` graph:

```sh
swift test --scratch-path .build/shared
```

Useful focused checks:

```sh
swift test --scratch-path .build/shared --filter WebRTCStreamRecording
```

```sh
swift test --scratch-path .build/shared --filter OpenNOWGameServicesTests
```

Avoid package-local build directories during normal development. Use the root package and shared scratch path so generated SwiftPM state stays in one place and large binary artifacts such as `sentry-cocoa` are not duplicated.

To audit generated SwiftPM disk usage:

```sh
scripts/report-spm-build-size.sh
```

To remove generated SwiftPM build caches and reclaim disk space:

```sh
scripts/clean-spm-builds.sh
```

Performance audit entry points are documented under `scripts/perf-audit/PERFORMANCE_AUDIT.md`.

## Contributing

Use conventional commit prefixes such as `fix:`, `feat:`, `docs:`, `test:`, `refactor:`, `style:`, and `chore:`. Keep changes focused and verify the relevant package tests or app build before submitting changes.

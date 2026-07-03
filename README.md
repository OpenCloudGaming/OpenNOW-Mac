# OpenNOW

OpenNOW is a native macOS cloud gaming client for browsing, launching, streaming, and recording GeForce NOW sessions.

## Current State

The repository contains a SwiftUI app target plus service, protocol, authentication, streaming, telemetry, and shared package modules. The visible frontend lives under `OpenNOW/Views` and includes:

- OAuth sign-in and branded loading surfaces
- Catalog home with a six-image hero rotation, game rails, search, filters, and detail panels
- Persistent favorites and library rails for quick game access across restarts
- Store ownership picker and launch/session overlays
- Native WebRTC streaming with input, microphone, audio, video enhancement, and diagnostics paths
- Local gameplay recordings with saved metadata and a recordings browser
- Settings for account, connections, gameplay, server location, upscaling, system, and diagnostics

## Project Layout

- `OpenNOW` - SwiftUI macOS app, views, view models, resources, and app services
- `OPN.GameServices` - GeForce NOW catalog, library, launch, session, and store ownership services
- `OPN.WebRTC.Media` - native WebRTC transport, stream surface, rendering, audio, input, and recording code
- `OPN.Common` - shared stream preferences and common utilities
- `OPN.Auth` - authentication/session support
- `OPN.Telemetry` - local logging and Sentry-backed telemetry
- `OPN.SignalLinkKit` - signaling support
- `GFN.*` packages - protocol-specific GeForce NOW service modules

## Packages

- `GFN.CloudMatch`
- `GFN.GDN`
- `GFN.Jarvis`
- `GFN.LCARS`
- `GFN.NesAuth`
- `GFN.NetworkTest`
- `GFN.Starfleet`
- `GFN.UDS`
- `OPN.Auth`
- `OPN.Common`
- `OPN.GameServices`
- `OPN.SignalLinkKit`
- `OPN.Telemetry`
- `OPN.WebRTC.Media`

## Building

Build the macOS app from the repository root:

```sh
xcodebuild build -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO
```

## Testing

Build packages from the repository root so SwiftPM uses one shared `.build` graph for all local packages:

```sh
swift build
```

Useful focused checks:

```sh
swift test --package-path OPN.GameServices
```

```sh
swift test --package-path OPN.WebRTC.Media --filter WebRTCStreamRecording
```

Avoid running `swift build` from each package directory during normal development. Each package-local build creates a separate `.build` tree and can duplicate large binary artifacts such as `sentry-cocoa`. Focused `swift test --package-path ...` commands are still useful when validating one package; run the cleanup script afterward if disk usage grows.

To remove generated SwiftPM build caches and reclaim disk space:

```sh
scripts/clean-spm-builds.sh
```

Performance audit entry points are documented under `scripts/perf-audit/PERFORMANCE_AUDIT.md`.

## Contributing

Use conventional commit prefixes such as `fix:`, `feat:`, `docs:`, `test:`, `refactor:`, `style:`, and `chore:`. Keep changes focused and verify the relevant package tests or app build before submitting changes.

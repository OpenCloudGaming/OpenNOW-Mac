OpenNOW is a native macOS cloud gaming client for launching and streaming GeForce NOW sessions.

## Current State

The repository contains a SwiftUI app target plus service, protocol, authentication, streaming, telemetry, and shared package modules. The visible frontend lives under `OpenNOW/Views` and includes:

- OAuth sign-in and branded loading surfaces
- Catalog hero carousel, game rails, search, filters, and detail panels
- Store ownership picker and launch/session overlays
- Settings for account, connections, gameplay, server location, upscaling, system, and diagnostics

## Packages

- `GFN.CloudMatch`
- `GFN.GDN`
- `GFN.Jarvis`
- `GFN.LCARS`
- `GFN.NesAuth`
- `GFN.NetworkTest`
- `GFN.Ragnarok`
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
xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug -derivedDataPath build/DerivedData build
```

## Testing

Run package tests from an individual package directory:

```sh
swift test
```

## Contributing

Open issues for bugs or feature requests and submit pull requests for improvements.

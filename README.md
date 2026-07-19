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

## Steam Controller Support (Experimental)

OpenNOW can read Valve Steam Controllers directly over HID, bypassing Steam. The pipeline is:

1. `OPN/Stream/SteamControllerHIDMonitor.swift` matches devices by vendor ID `0x28de` and product ID (see below), opens them via IOKit HID, disables the firmware's built-in keyboard/mouse emulation ("lizard mode") with periodic heartbeats, and streams raw input reports.
2. `OPN/Stream/SteamControllerReport.swift` parses each report into a `SteamControllerInputSnapshot` (buttons, triggers, sticks, and trackpads).
3. Snapshots feed the in-app test screen (Settings → Steam Controller Test) and, during streaming, `NativeWebRTCGamepadMonitor`, which forwards a standard gamepad subset (face buttons, D-pad, bumpers, triggers, sticks, select/start) to the GeForce NOW session. Steam/QAM, back grips, and trackpads are parsed and shown in the test screen but are not forwarded to the stream.

### Supported hardware

| Product ID | Device |
|---|---|
| `0x1102` | Steam Controller (2015), wired |
| `0x1142` | Steam Controller (2015) wireless dongle |
| `0x1302` | Steam Controller (2026, "Triton"), wired |
| `0x1303` | Steam Controller (2026), Bluetooth LE |
| `0x1304` | Steam Controller (2026) 2.4 GHz dongle ("Proteus") |
| `0x1305` | Steam Controller (2026) dongle variant ("Nereid") |

### Report formats and mappings

The parser understands three report layouts, with bit/byte mappings verified against Valve's contributions to SDL's HIDAPI drivers:

- **Legacy (2015)** — `ValveInReport_t`-framed packets; buttons across three bytes, trackpads double as stick/D-pad emulation. Reference: [`SDL_hidapi_steam.c`](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam.c).
- **Triton (2026)** — report IDs `0x42` (wired/dongle state), `0x45` (BLE state), and `0x47` (timestamped state; inserts a 16-bit trackpad timestamp before the pad fields, shifting them by 2 bytes). A 32-bit button mask includes the Steam button (`0x0001_0000`), Quick Access (`0x0000_0010`), four back grips, trackpad touch/click bits, and per-pad X/Y plus pressure. Reference: [`SDL_hidapi_steam_triton.c`](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam_triton.c).
- **Deck state** — report ID `0x09`, the Steam Deck-style 64-bit button mask with pads at fixed offsets; used when a device speaks the deck packet format. Reference: [`SDL_hidapi_steamdeck.c`](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steamdeck.c).

Struct layouts for all three formats are documented in SDL's [`controller_structs.h`](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_structs.h). Axis values normalize to `-1...1` (`Int16` full scale), triggers and pad pressure to `0...1`. Parsing is covered by `Tests/Stream/SteamControllerReportTests.swift`.

Note: Steam grabs the physical controller exclusively while it is running — quit Steam before testing.

## Project Layout

- `Model` - persisted SwiftData models, DTOs, stream value types, Twitch realtime models, and catalog value objects
- `OpenNOWApp.swift` - macOS app entry point and application delegate
- `Resources` - bundled images, fonts, and store icon assets
- `View` - SwiftUI/AppKit views, stream host views, design primitives, and asset catalogs
- `ViewModel` - observable UI state and presentation coordination for login, catalog, controller catalog, and recordings
- `OPN` - authentication, catalog/session services, native WebRTC, telemetry, Twitch, preferences, logging, and app infrastructure
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

# OpenNOW

OpenNOW is a native macOS cloud gaming client built for players who want a fast desktop app instead of a browser wrapper. It combines AppKit, Objective-C++, and WebRTC to deliver account sign-in, game discovery, low-latency streaming, stream tuning, recording, and diagnostics in one Mac-first experience.

## Why OpenNOW

- Native Mac feel: AppKit UI, crisp keyboard/mouse handling, menu-driven controls, and no web shell overhead.
- Stream quality control: tune region, codec, bitrate, frame rate, HDR, prefiltering, and recovery behavior before launch.
- Visual enhancement pipeline: local Spatial, MetalFX, and Temporal upscaling paths with sharpness, denoise, and session diagnostics.
- Built for real play sessions: recording, microphone support, anti-AFK, stats HUD, Discord Rich Presence, and fast access to stream controls.
- Actionable diagnostics: end-session reports, protocol captures, quality events, logs, and health summaries make troubleshooting repeatable.

## Key Features

- Native AppKit interface with browser-based OAuth sign-in, persistent sessions, and account switching.
- Game catalog and library browsing with a focused launch flow for cloud streams.
- Native WebRTC streaming with video, game audio, microphone, clipboard, keyboard, mouse, and gamepad support.
- Per-game stream profiles for resolution, FPS, codec, bitrate, region, color, and enhancement preferences.
- Local upscaling and cleanup controls including Spatial, MetalFX, Temporal reconstruction, denoise, sharpness, and prefilter options.
- MP4 stream recording with system audio, microphone capture, recent recording shortcuts, and Movies folder output.
- Live stats overlay for latency, bitrate, packet loss, FPS, codec, dropped frames, and enhancement state.
- End-session health reports with launch timing, network metrics, stream stats, events, recovery details, and video enhancement diagnostics.
- Discord Rich Presence integration for sharing active game and stream profile details.
- Sentry Native crash reporting support for production diagnostics.

## Requirements

- macOS with AppKit/Cocoa support
- `clang++` with C++20 and Objective-C ARC support
- `cmake` for building Sentry Native
- Apple Command Line Tools or Xcode toolchain
- `WebRTC.framework` or `WebRTC.xcframework` in `third_party/webrtc-official`

## Sentry Native

Install the latest Sentry Native release before building with crash reporting enabled:

```sh
scripts/install-sentry-native.sh
```

The installer writes the SDK to `third_party/sentry-native/install`. To send a one-time verification message during launch, run with `OPN_SENTRY_VERIFY=1`.

## Build & Run

```sh
make
make run
```

Build artifacts are written to `build/OpenNOW`.

`make run` enables `OPN_INFO_LOGS=1` by default so runtime logs are printed in the terminal.

## Clean

```sh
make clean
```

## Repository Layout

- `src/main.mm` - app entry point
- `src/OPNAppDelegate.*` - app lifecycle and navigation
- `src/auth/` - OAuth and session handling
- `src/games/` - catalog, library, and launch logic
- `src/streaming/` - WebRTC stream session and UI
- `src/views/` - native AppKit views
- `src/common/` - shared types and helpers
- `assets/` - artwork and icons

## Contributing

Open issues for bugs or feature requests and submit pull requests for improvements.

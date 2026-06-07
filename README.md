# OpenNOW

OpenNOW is a native macOS cloud gaming client built with AppKit, Objective-C++, and WebRTC. It gives you a desktop-first way to sign in, browse games, and launch cloud streams without using a browser wrapper.

## Features

- Native Mac interface with OAuth sign-in, persistent sessions, and account switching.
- Game catalog, library browsing, and a focused cloud-stream launch flow.
- Native WebRTC streaming with keyboard, mouse, gamepad, audio, microphone, and clipboard support.
- Stream tuning for resolution, FPS, codec, bitrate, region, HDR, and recovery behavior.
- Local upscaling, MP4 recording, stats HUD, Discord Rich Presence, and end-session diagnostics.

## Requirements

- macOS with AppKit/Cocoa support
- `clang++` with C++20 and Objective-C ARC support
- `cmake` for building Sentry Native
- Apple Command Line Tools or Xcode toolchain
- `WebRTC.framework` or `WebRTC.xcframework` in `third_party/webrtc-official`

## Optional Sentry Support

Install Sentry Native before building if you want crash reporting enabled:

```sh
scripts/install-sentry-native.sh
```

The installer writes the SDK to `third_party/sentry-native/install`.

Sentry metrics are enabled with Sentry Native when Sentry support is available. To send the built-in verification event, structured log, and sample metrics, run:

```sh
OPN_SENTRY_VERIFY=1 make run
```

Set `OPN_DISABLE_SENTRY_METRICS=1` to disable metrics without disabling crash reporting or logs.

Runtime metrics cover app lifecycle, auth refresh and login outcomes, screen transitions, HTTP response outcomes, game launch decisions, stream launch duration, stream duration, recovery attempts, remote stop outcomes, and sampled stream quality gauges.

## Build & Run

```sh
make
make run
```

Debug build artifacts are written to `build/debug/OpenNOW`.

`make run` enables `OPN_INFO_LOGS=1` by default so runtime logs are printed in the terminal.

For optimized builds, use:

```sh
make release
```

Release artifacts are written to `build/release/OpenNOW`.

## Clean

```sh
make clean
```

## Contributing

Open issues for bugs or feature requests and submit pull requests for improvements.

# OpenNOW

OpenNOW is a native macOS cloud gaming client built with AppKit, Objective-C++, and WebRTC. It gives you a desktop-first way to sign in, browse games, and launch cloud streams.

![OpenNOW console home](assets/console-home.png)

## Features

- Native Mac interface with OAuth sign-in, persistent sessions, and account switching.
- Game catalog, library browsing, and a focused cloud-stream launch flow.
- Native WebRTC streaming with keyboard, mouse, gamepad, audio, microphone, and clipboard support.
- Stream tuning for resolution, FPS, codec, bitrate, region, HDR, and recovery behavior.
- Local upscaling, MP4 recording, stats HUD, Discord Rich Presence, and end-session diagnostics.

## Requirements

- macOS with AppKit/Cocoa support
- `clang++` with C++20 and Objective-C ARC support
- Xcode 16 or newer
- `WebRTC.framework` or `WebRTC.xcframework` in `third_party/webrtc-official`

## Sentry Support

OpenNOW uses the Apple Sentry SDK through Swift Package Manager in `OpenNOW.xcodeproj`:

```url
https://github.com/getsentry/sentry-cocoa.git
```

The project requires Sentry Cocoa `9.16.1` or newer and enables UI Profiling with trace lifecycle. To send the built-in verification event, run the app from Xcode with:

```sh
OPN_SENTRY_VERIFY=1
```

Set `OPN_SENTRY_INFO_LOGS=1` to forward verbose info-level runtime logs to Sentry structured logs.
Set `OPN_SENTRY_TRACES_SAMPLE_RATE` and `OPN_SENTRY_PROFILE_SESSION_SAMPLE_RATE` to tune trace and profile sampling.

## Build And Run

```sh
xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug build
```

Debug build artifacts are written under Xcode DerivedData.

For day-to-day development, open `OpenNOW.xcodeproj` in Xcode and run the `OpenNOW` target.

For optimized builds, use:

```sh
xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Release build
```

Release app bundles are written under Xcode DerivedData. To produce zip and DMG artifacts, run:

```sh
scripts/release-mac.sh
```

## Clean

```sh
xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW clean
```

## Contributing

Open issues for bugs or feature requests and submit pull requests for improvements.

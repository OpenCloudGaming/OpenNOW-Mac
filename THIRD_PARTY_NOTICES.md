# Third-Party Notices

OpenNOW bundles and/or depends on the following third-party components. Each is
redistributed under its own license; the full license text for the bundled
components lives alongside them in the source tree.

## Fonts

### Hanken Grotesk

- Copyright 2021 The Hanken Grotesk Project Authors
  (<https://github.com/marcologous/hanken-grotesk>)
- License: SIL Open Font License 1.1 (<https://scripts.sil.org/OFL>)
- Bundled as WOFF2 in `Resources/Fonts/` (Regular, Medium, Bold static instances,
  version 3.013).
- Full license text: `Resources/Fonts/OFL.txt`.

## WebRTC

- Copyright (c) 2011, The WebRTC project authors. All rights reserved.
- License: BSD 3-Clause
- Bundled as `WebRTC.framework`.
- Full license text: `WebRTC.framework/Versions/A/Resources/LICENSE`.

## Ably

### Ably JavaScript SDK (vendored for Remote Co-Op)

- Version 2.28.0 (`Resources/RemoteCoOp/browser/vendor/ably.min.js`)
- License: Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>)
- Source and SHA-256 documented in `Resources/RemoteCoOp/browser/vendor/README.md`.

### ably-cocoa

- Swift Package Manager dependency (exact `1.3.0`)
- License: Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>)

## Sentry

### sentry-cocoa

- Copyright (c) 2015 Sentry
- Swift Package Manager dependency (exact `9.18.0`)
- License: MIT License (<https://opensource.org/license/mit>)

## Build/Development Tooling

### SwiftLint Plugins (SimplyDanny/SwiftLintPlugins)

- Swift Package Manager dependency, wired as a command plugin only; never ships in
  the distributed app.
- License: MIT License

---

Nothing in this file grants rights beyond those in the referenced licenses. The
OpenNOW project's own source is licensed separately under the MIT License (`LICENSE`).

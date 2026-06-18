# OpenNOW Performance Audit

Generated: 2026-06-18

## Scope

Audited the app target plus all first-party Swift packages:

| Area | Packages |
| --- | --- |
| App/UI | `OpenNOW` |
| Streaming/rendering | `OPN.WebRTC.Media`, `OPN.SignalLinkKit` |
| Catalog/launch/session | `OPN.GameServices`, `OPN.Common` |
| Auth | `OPN.Auth`, `GFN.Jarvis`, `GFN.NesAuth`, `GFN.Starfleet` |
| Vendor services | `GFN.CloudMatch`, `GFN.GDN`, `GFN.LCARS`, `GFN.NetworkTest`, `GFN.Ragnarok`, `GFN.UDS` |
| Telemetry | `OPN.Telemetry` |

## Methodology

Used three data sources:

| Artifact | Purpose |
| --- | --- |
| `static-scan.json` | Production-source scan for SwiftUI invalidation, timers, JSON work, disk/image IO, main-thread dispatch, URLSession usage. Tests and `.build` are excluded. |
| `opn-game-services-catalog-models.json` | Release-mode runtime measurements using real `OPNGameInfo`, `OPNCatalogGameObject`, `OPNCatalogPanelObject`, and realistic catalog model sizes. |
| `opn-common-stream-preferences.json` | Release-mode runtime measurements for real `OPNStreamPreferences` settings/device APIs. |
| `local-image-decode.json` | Runtime measurements for bundled PNG/JPG/SVG image construction with `NSImage(contentsOf:)` and `NSImage(data:)`. |

Commands used for verification:

| Command | Result |
| --- | --- |
| `OPENNOW_PERF_AUDIT=1 OPENNOW_PERF_AUDIT_OUTPUT=... swift test -c release` in `OPN.GameServices` | Passed, wrote catalog model timings. |
| `OPENNOW_PERF_AUDIT=1 OPENNOW_PERF_AUDIT_OUTPUT=... swift test -c release` in `OPN.Common` | Passed, wrote stream preference timings. |
| `swift test -c release` in packages with tests | Passed for `GFN.CloudMatch`, `GFN.GDN`, `GFN.Jarvis`, `GFN.LCARS`, `GFN.NesAuth`, `GFN.NetworkTest`, `GFN.Ragnarok`, `GFN.Starfleet`, `GFN.UDS`, `OPN.GameServices`, `OPN.WebRTC.Media`, `OPN.Common`. |
| `swift test -c release` in packages without tests | Built then reported no test target for `OPN.Auth`, `OPN.SignalLinkKit`, `OPN.Telemetry`. |
| `xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug -destination 'platform=macOS' build` | Passed. |

## Executive Findings

1. The strongest measured UI-stutter source is `CatalogViewModel.loadSettingsPreferences()` calling synchronous device and CoreAudio APIs on the main actor. `OPNStreamPreferences.loadMicrophoneDeviceOptions()` reached 86.67 ms max and `loadDeviceCapabilities()` reached 76.71 ms max in release-mode measurement.
2. The catalog model decode path is expensive at large sizes: `JSONDecoder.decode([OPNGameInfo])` for 3,000 realistic games averaged 109.65 ms. The parsing work is mostly package-side, but the app then publishes many `@Published` properties sequentially, causing multiple SwiftUI invalidations.
3. `CatalogImageCache` is `@MainActor` and performs SwiftData fetch/save plus `NSImage(data:)` in the cache-hit path. This is structurally capable of blocking frames when many visible images resolve together.
4. The catalog body derives `imageCacheSignature`, `imageCacheURLs`, `marqueeGames`, `catalogSections`, and image URLs from large arrays during SwiftUI updates. Individual measured derivations are small, but they are repeated by timers, hover state, image load state, and sequential model publishes.
5. The streaming package has expected high-frequency timers/render loops. The code includes one `DispatchQueue.main.sync` removal path in `WebRTCNativeStreamSession.swift`; it is not the primary catalog/menu jank suspect, but it is a streaming teardown hitch risk.

## Measured Runtime Hotspots

### `OPN.Common` Settings/Device APIs

These calls are invoked by `CatalogViewModel.loadSettingsPreferences()` on `@MainActor` at `OpenNOW/ViewModels/CatalogViewModel.swift:1026`.

| Operation | Iterations | Mean | Max | Risk |
| --- | ---: | ---: | ---: | --- |
| `OPNStreamPreferences.loadDeviceCapabilities` | 200 | 0.51 ms | 76.71 ms | Frame drop on worst-case hardware/API response. |
| `OPNStreamPreferences.loadMicrophoneDeviceOptions` | 100 | 0.97 ms | 86.67 ms | Direct hitch risk during settings/menu transitions. |
| `OPNStreamPreferences.loadProfile/effectiveProfile` | 1,000 | 0.83 ms | 10.86 ms | Small but repeated with every settings save. |

Relevant source:

| Source | Concern |
| --- | --- |
| `OpenNOW/ViewModels/CatalogViewModel.swift:1026` | `loadSettingsPreferences()` runs on `@MainActor`. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:1027` | Calls `OPNStreamPreferences.loadDeviceCapabilities()`. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:1031` | Calls `OPNStreamPreferences.loadMicrophoneDeviceOptions()`. |
| `OPN.Common/Sources/Common/OPNStreamPreferences.swift:302` | Enumerates microphone devices synchronously. |
| `OPN.Common/Sources/Common/OPNStreamPreferences.swift:310` | Calls CoreAudio `AudioObjectGetPropertyDataSize`. |
| `OPN.Common/Sources/Common/OPNStreamPreferences.swift:313` | Calls CoreAudio `AudioObjectGetPropertyData`. |
| `OPN.Common/Sources/Common/OPNStreamPreferences.swift:330` | Calls VideoToolbox hardware decode checks. |

### `OPN.GameServices` Catalog Models

Release-mode model timings using realistic catalog data:

| Operation | Count | Mean | Max | Risk |
| --- | ---: | ---: | ---: | --- |
| `JSONDecoder.decode([OPNGameInfo])` | 1,500 | 55.76 ms | 59.34 ms | Too large for main thread. |
| `JSONDecoder.decode([OPNGameInfo])` | 3,000 | 109.65 ms | 111.50 ms | Severe if main-adjacent. |
| `JSONEncoder.encode([OPNGameInfo])` | 3,000 | 94.78 ms | 96.66 ms | Cache write should stay off main. |
| `OPNCatalogGameObject init map` | 3,000 | 1.70 ms | 1.86 ms | Acceptable. |
| `OPNCatalogGameObject swiftValue map` | 3,000 | 1.80 ms | 2.05 ms | Acceptable. |
| `OPNCatalogPanelObject init map` | 3,000 | 0.66 ms | 0.75 ms | Acceptable. |

Relevant source:

| Source | Concern |
| --- | --- |
| `OPN.GameServices/Sources/OpenNOWGameServices/OPNGameService.swift:141` | Catalog browse entry path. |
| `OPN.GameServices/Sources/OpenNOWGameServices/OPNGameService.swift:1358` | Dispatches browse completion back to main. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:260` | Browse completion starts setting UI-facing state. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:270` to `OpenNOW/ViewModels/CatalogViewModel.swift:278` | Multiple sequential `@Published` assignments. |

### `OpenNOW` Catalog Derivations

Measured equivalents using real `OPNCatalogGameObject` and `OPNCatalogPanelObject` models:

| Operation | Count | Mean | Max | Risk |
| --- | ---: | ---: | ---: | --- |
| `CatalogViewModel.catalogSections equivalent` | 3,000 | 0.002 ms | 0.010 ms | Not a standalone hotspot. |
| `CatalogViewModel.marqueeGames equivalent` | 3,000 | 0.141 ms | 0.378 ms | Fine once, but repeated often. |
| `selected detail section scan equivalent` | 3,000 | 0.027 ms | 0.054 ms | Not a standalone hotspot. |
| `best image URL derivation equivalent` | 3,000 | 1.151 ms | 1.299 ms | Repeated body invalidations can accumulate. |

Relevant source:

| Source | Concern |
| --- | --- |
| `OpenNOW/ViewModels/CatalogViewModel.swift:164` | `catalogSections` recomputes from `mainPanels`, `catalogGames`, and `libraryGames`. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:834` | `imageCacheSignature` builds from `imageCacheURLs`. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:838` | `imageCacheURLs` walks image cache games and derives optimized URLs. |
| `OpenNOW/ViewModels/CatalogViewModel.swift:856` | `imageCacheGames` walks `marqueeGames` and `catalogSections`. |
| `OpenNOW/Views/Catalog/CatalogView.swift:1102` | Main-run-loop hero timer invalidates catalog content every 5 seconds. |
| `OpenNOW/Views/Catalog/CatalogView.swift:1663` | Main-run-loop detail image timer invalidates selected detail panel every 5 seconds. |

### Local Image Decode/Open

Measured bundled image construction:

| Asset | Bytes | `NSImage(contentsOf:)` Mean | Max | `NSImage(data:)` Mean | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| `OpenNOW/Resources/OpenNOW/logo.png` | 1,389,234 | 0.322 ms | 7.048 ms | 0.072 ms | 0.337 ms |
| `OpenNOW/Resources/NVIDIA/LoginWallContentBackground.png` | 637,144 | 0.206 ms | 0.500 ms | 0.108 ms | 0.187 ms |
| `OpenNOW/Resources/NVIDIA/LoginWallFallbackTile.png` | 38,737 | 0.134 ms | 0.226 ms | 0.099 ms | 0.213 ms |
| `OpenNOW/Resources/NVIDIA/Marquee_Hero_Image_Gradient.svg` | 70,329 | 2.283 ms | 6.124 ms | 2.520 ms | 2.792 ms |

Relevant source:

| Source | Concern |
| --- | --- |
| `OpenNOW/Services/CatalogImageCache.swift:12` | Entire cache type is `@MainActor`. |
| `OpenNOW/Services/CatalogImageCache.swift:37` | `image(for:)` cache path is main actor isolated. |
| `OpenNOW/Services/CatalogImageCache.swift:82` | SwiftData fetch in `loadStoredImage(for:)`. |
| `OpenNOW/Services/CatalogImageCache.swift:88` | `NSImage(data:)` in stored image cache hit path. |
| `OpenNOW/Services/CatalogImageCache.swift:91` | Mutates SwiftData hit count/access time on cache hit. |
| `OpenNOW/Views/Catalog/CatalogView.swift:2127` | Hero scrim color extraction runs after image load state update. |
| `OpenNOW/Views/Catalog/CatalogView.swift:2248` | `CatalogHeroImageMetadata.scrimColor(from:)` uses `CGImageSource` and pixel sampling. |

## Static Package Scan

Production Swift source only, excluding tests and `.build`.

| Package | Swift Files | Lines | SwiftUI Bodies | `@Published` | Main Dispatch | JSON Serialization | Disk/Image IO | Timers | URLSession |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `OpenNOW` | 16 | 6,296 | 76 | 57 | 1 | 0 | 3 | 1 | 0 |
| `GFN.CloudMatch` | 3 | 349 | 0 | 0 | 0 | 2 | 0 | 0 | 0 |
| `GFN.GDN` | 3 | 165 | 0 | 0 | 0 | 2 | 1 | 0 | 0 |
| `GFN.Jarvis` | 4 | 1,976 | 0 | 0 | 0 | 6 | 0 | 0 | 0 |
| `GFN.LCARS` | 3 | 208 | 0 | 0 | 0 | 2 | 1 | 0 | 0 |
| `GFN.NesAuth` | 3 | 133 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `GFN.NetworkTest` | 3 | 320 | 0 | 0 | 0 | 2 | 0 | 0 | 0 |
| `GFN.Ragnarok` | 3 | 278 | 0 | 0 | 0 | 5 | 0 | 0 | 0 |
| `GFN.Starfleet` | 3 | 988 | 0 | 0 | 0 | 4 | 0 | 0 | 0 |
| `GFN.UDS` | 3 | 341 | 0 | 0 | 0 | 4 | 0 | 0 | 0 |
| `OPN.Auth` | 5 | 1,051 | 0 | 0 | 14 | 0 | 1 | 0 | 1 |
| `OPN.Common` | 6 | 1,881 | 0 | 0 | 8 | 7 | 0 | 0 | 4 |
| `OPN.GameServices` | 15 | 5,891 | 0 | 0 | 11 | 22 | 4 | 0 | 17 |
| `OPN.SignalLinkKit` | 2 | 399 | 0 | 0 | 5 | 4 | 0 | 1 | 0 |
| `OPN.Telemetry` | 3 | 470 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `OPN.WebRTC.Media` | 26 | 7,569 | 1 | 0 | 9 | 3 | 5 | 20 | 0 |

## Package-by-Package Assessment

### `OpenNOW`

Risk: high. This is where most visible stutter is likely produced because it owns SwiftUI invalidation and main-actor state publication. Static scan found 76 SwiftUI bodies, 57 `@Published` fields, 10 animation sites, 10 `GeometryReader` sites, and multiple timers. Measured catalog derivations are individually small, but they happen during body recomputation and are coupled to image loading, hover, timers, and sequential published updates.

Primary actions:

1. Move `loadSettingsPreferences()` device/microphone work off the main actor and publish one settings snapshot back to UI.
2. Replace the many sequential `@Published` catalog assignments with one published catalog state struct or explicit batching.
3. Cache `imageCacheURLs` and `imageCacheSignature` when source arrays change instead of recomputing from body/task evaluation.
4. Pause hero/detail timers when not visible or when the app is inactive.

### `OPN.Common`

Risk: high for settings transitions. The measured worst-case runtime for microphone enumeration and capability checks exceeds a 16.67 ms frame budget by 4x to 5x. Because `CatalogViewModel` is `@MainActor`, this is a direct choppy-interface cause.

Primary actions:

1. Add async/background loading APIs for device capabilities and microphone devices.
2. Cache microphone device options for a short TTL and refresh on device-change notifications.
3. Avoid re-running full settings loading after every scalar preference save.

### `OPN.GameServices`

Risk: medium-high. Large JSON parsing is expensive, but most URLSession work should happen off main. The issue becomes visible when results are converted into many main-actor `@Published` assignments and when cache hits/definitions produce rapid consecutive completions.

Primary actions:

1. Keep all JSON decode/encode and cache file IO off main.
2. Return one immutable browse result snapshot to the UI and apply it in one state mutation.
3. Avoid delivering cached result and network refresh back-to-back unless the network result materially differs.

### `OPN.WebRTC.Media`

Risk: medium during active stream or teardown, low for catalog browsing. Static scan found 20 timers/render-loop sites and one `DispatchQueue.main.sync` at `OPN.WebRTC.Media/Sources/WebRTCMedia/WebRTCNativeStreamSession.swift:267`. Rendering is intentionally high frequency, but teardown should not synchronously block a non-main worker waiting on the main actor.

Primary actions:

1. Replace `DispatchQueue.main.sync` teardown with an async main-actor operation when safe.
2. Ensure diagnostics/stat timers are stopped when overlays or streams are not visible.
3. Profile Metal enhancement frame time only during active stream if stutter persists inside gameplay.

### `OPN.SignalLinkKit`

Risk: low for the catalog UI. It has one timer and several main dispatches, but no SwiftUI surface or heavy model work. It built successfully but has no tests.

### `OPN.Auth`, `GFN.Jarvis`, `GFN.NesAuth`, `GFN.Starfleet`

Risk: low outside login. `GFN.Jarvis`, `GFN.NesAuth`, and `GFN.Starfleet` tests pass. `OPN.Auth` builds but has no tests. `OPN.Auth` has 14 main-dispatch sites, so login progress can trigger UI updates, but it is not the likely cause of catalog/menu stutter.

### `GFN.CloudMatch`, `GFN.GDN`, `GFN.LCARS`, `GFN.NetworkTest`, `GFN.Ragnarok`, `GFN.UDS`

Risk: low. These are small service packages with JSON request/response logic and passing release tests. No SwiftUI state, no timers, and minimal/no disk IO. They are unlikely to cause a globally choppy interface unless a caller invokes them repeatedly from main.

### `OPN.Telemetry`

Risk: low from source scan. It builds, has no tests, and no obvious UI-loop work in first-party code. Sentry dependency cost is mostly build/runtime initialization, not visible catalog twitch.

## Root-Cause Ranking

1. `CatalogViewModel.loadSettingsPreferences()` main-actor synchronous hardware/audio enumeration. Strong evidence: measured 76.71 ms and 86.67 ms max calls; source path is main actor.
2. Sequential `@Published` updates after catalog browse. Strong structural evidence: many consecutive assignments into a SwiftUI view tree with 76 bodies and timers. Runtime catalog model conversion is not the expensive part, but invalidation multiplication is.
3. `CatalogImageCache` main-actor disk/SwiftData/image work. Strong structural evidence: cache hit mutates SwiftData and creates `NSImage` under `@MainActor`; this scales with visible images and prefetch completions.
4. Recomputed image prefetch signatures and URL arrays. Moderate measured evidence: 1.15 ms for 3,000 image URL derivations, multiplied across frequent body updates.
5. Streaming teardown sync-to-main and high-frequency timers. Medium risk during active stream/teardown, not primary for catalog browsing.

## Recommended Fix Order

1. Make settings/device loading asynchronous and snapshot-based.
2. Batch catalog browse state into one published state object.
3. Move `CatalogImageCache` storage/image decoding off `@MainActor`; only publish final `NSImage` assignment on main.
4. Memoize `imageCacheURLs` and `imageCacheSignature` on catalog data changes.
5. Replace stream teardown `DispatchQueue.main.sync` with nonblocking main-actor cleanup.

## Reproducing Measurements

Run catalog model audit:

```bash
OPENNOW_PERF_AUDIT=1 OPENNOW_PERF_AUDIT_OUTPUT=/Volumes/Projects/OpenNOW-Mac/scripts/perf-audit/opn-game-services-catalog-models.json swift test -c release
```

Run stream preference audit:

```bash
OPENNOW_PERF_AUDIT=1 OPENNOW_PERF_AUDIT_OUTPUT=/Volumes/Projects/OpenNOW-Mac/scripts/perf-audit/opn-common-stream-preferences.json swift test -c release
```

Run static scan:

```bash
python3 scripts/perf-audit/static_scan.py > scripts/perf-audit/static-scan.json
```

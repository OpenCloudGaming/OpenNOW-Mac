# Upscaler Implementation Plan

Status: Plan created 2026-06-05

Owner: OpenNOW streaming renderer

Scope: Replace the current display-only Core Image upscaler with a low-latency Metal enhancement pipeline that can scale toward MetalFX and neural temporal super-resolution.

## Objective

Deliver a production-grade local video enhancement stack for cloud game streaming. The first release should make upscaling real by rendering to the actual display drawable size, removing CPU-bound color conversion from the hot path, and introducing an adaptive Metal renderer. Later releases should add MetalFX spatial scaling and a neural temporal super-resolution path that reconstructs higher-quality frames from lower-bitrate streams.

## Current State Audit

The current implementation is concentrated in `src/streaming/OPNLibWebRTCStreamSession.mm` inside `OPNMetalVideoView`.

Relevant files and responsibilities:

| File | Role |
| --- | --- |
| `src/streaming/OPNLibWebRTCStreamSession.mm` | WebRTC video renderer, current Core Image enhancement path, diagnostics, frame callbacks |
| `src/streaming/OPNLibWebRTCStreamSession.h` | Enhancement state storage and session-level interface |
| `src/streaming/OPNStreamSession.h` | Public stream session API and renderer diagnostics fields |
| `src/streaming/OPNStreamView.mm` | Stream view layout, upscaling mode propagation, layer magnification behavior, sidebar controls |
| `src/streaming/OPNStreamPreferences.h` | Stored upscaling profile fields |
| `src/streaming/OPNStreamPreferences.mm` | Upscaling mode options, persistence, clamping, defaults |
| `src/views/OPNSettingsView.mm` | Settings UI for mode, sharpness, denoise |
| `src/streaming/OPNStreamRecordingManager.mm` | Records incoming raw WebRTC frames before local enhancement |
| `tests/backend_tests.mm` | Preference coverage for default and clamped upscaling values |

Current enhancement behavior:

| Area | Current Behavior | Limitation |
| --- | --- | --- |
| Scaling | `CILanczosScaleTransform` in Core Image | Spatial scaler only; no reconstructed detail |
| Denoise | `CINoiseReduction` | Generic image filter, not tuned for streaming artifacts |
| Sharpen | `CIUnsharpMask` | Can halo or amplify compression artifacts |
| Frame source | WebRTC `RTCVideoFrame` | Non-`RTCCVPixelBuffer` frames fall back to CPU I420-to-BGRA conversion |
| Output target | `MTKView.currentDrawable` | Drawable size may be driven by incoming frame size rather than actual backing display size |
| Mode gating | Processed path requires `mode > 0` and sharpness or denoise above zero | Upscaler mode with both sliders at zero silently uses WebRTC renderer |
| Recording | Records raw incoming frame | Captures do not match enhanced display output |
| Adaptation | None for enhancement quality | Enhancement can exceed frame budget without automatic downgrade |

## Target Architecture

Create a dedicated renderer stack that separates WebRTC frame ingestion, texture conversion, enhancement, presentation, diagnostics, and optional capture.

Target components:

| Component | Type | Responsibility |
| --- | --- | --- |
| `OPNEnhancedMetalVideoView` | Objective-C++ `NSView`, `RTCVideoRenderer`, `MTKViewDelegate` | Own `MTKView`, receive WebRTC frames, schedule draws, expose renderer diagnostics |
| `OPNVideoEnhancementRenderer` | Objective-C++ class | Select and run native, spatial, MetalFX, neural, and temporal pipelines |
| `OPNVideoTextureSource` | Objective-C++ class | Convert `RTCVideoFrame` into Metal textures with `CVMetalTextureCache` where possible |
| `OPNYUVToRGBConverter` | Metal compute pipeline | GPU color conversion for NV12 and I420 fallback paths |
| `OPNSpatialUpscaler` | Metal render/compute pipeline | High-quality spatial scale, crop, letterbox, sharpness, denoise fallback |
| `OPNMetalFXUpscaler` | Objective-C++ wrapper | Use MetalFX spatial scaling when available |
| `OPNNeuralUpscaler` | Core ML, MPSGraph, or ML Program wrapper | Run a streaming-optimized super-resolution model |
| `OPNTemporalUpscaler` | Metal/Core ML hybrid | Manage previous frames, motion estimates, confidence masks, and artifact rejection |
| `OPNEnhancementGovernor` | C++/Objective-C++ policy object | Downgrade/upgrade quality based on frame time, FPS, decode time, thermal/power state |
| `OPNEnhancedFrameRecorderBridge` | Objective-C++ bridge | Optionally feed enhanced output textures into recording |

High-level flow:

```text
WebRTC RTCVideoFrame
  -> OPNEnhancedMetalVideoView
  -> OPNVideoTextureSource
  -> YUV/NV12/I420 Metal texture planes
  -> selected enhancement pipeline
  -> CAMetalDrawable texture
  -> present
  -> diagnostics and optional recording tap
```

Quality tiers:

| Tier | Name | Description | Runtime Requirement |
| --- | --- | --- | --- |
| 0 | Native | Existing WebRTC Metal renderer path | Always available |
| 1 | Spatial | Custom Metal color conversion, scaling, denoise, sharpening | Metal |
| 2 | MetalFX Spatial | MetalFX spatial scaler plus local artifact cleanup | macOS and GPU support for MetalFX |
| 3 | Neural Spatial | Single-frame neural SR tuned for game/compression artifacts | Apple Silicon preferred, Core ML support |
| 4 | Neural Temporal | History-aware SR with motion/confidence feedback | Apple Silicon, sufficient frame budget |

## Implementation Milestones

### Milestone 1: Correct Output Target and Observability

Goal: Make the current upscaler actually render to the backing drawable size and expose enough data to measure success.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Done | Set enhanced renderer drawable size from `MTKView.bounds * backingScaleFactor`, not WebRTC frame size | Diagnostics show source resolution and drawable resolution separately |
| In Progress | Keep aspect-fit math inside the renderer and remove duplicate layer magnification reliance | Core Image path now targets the backing drawable; full duplicate-layer cleanup remains for the extracted renderer milestone |
| Done | Add render timing with `CACurrentMediaTime` or Metal command buffer GPU timestamps where available | Stats include local enhancement time and active tier |
| Done | Update diagnostics strings for native, Core Image fallback, and enhanced paths | Stats overlay now shows active enhancement tier, drawable resolution, and frame time when available |
| Planned | Add tests for preference mode labels and clamping if mode list changes | Existing preference tests pass and new defaults are explicit |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Visual scale correctness | 1080p stream on 4K display renders through an enhancement target larger than source |
| Runtime stability | No regressions when upscaling is off |
| Observability | Stats can distinguish source size, drawable size, render tier, and fallback reason |

### Milestone 2: Extract the Enhancement Renderer

Goal: Move enhancement logic out of `OPNMetalVideoView` so the renderer can evolve without making WebRTC session code unmaintainable.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Done | Create `src/streaming/OPNVideoEnhancementRenderer.h` and `.mm` | `OPNMetalVideoView` delegates processed drawing to a focused class |
| Done | Introduce `OPNVideoEnhancementSettings` with mode, sharpness, denoise, target size, recording flag | Settings are immutable per draw call; recording flag remains for Milestone 7 |
| Done | Introduce `OPNVideoEnhancementResult` for path, fallback, timings, output size | Diagnostics are produced by result object |
| Done | Preserve current Core Image behavior as a compatibility fallback | Existing default behavior remains available for unsupported formats |
| Done | Add lifecycle cleanup for `CIContext`, command queue references, texture cache, and temporary buffers | Renderer owns Core Image context, color space, texture cache, and Metal pipeline state |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Code organization | `OPNLibWebRTCStreamSession.mm` no longer owns filter implementation details |
| Behavior | Upscaling output remains visually equivalent or better than current path |
| Safety | Failure falls back to WebRTC native renderer with explicit diagnostics |

### Milestone 3: GPU-First Texture Ingestion

Goal: Eliminate CPU per-pixel I420-to-BGRA conversion from the enhancement hot path.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Done | Add `OPNVideoTextureSource` using `CVMetalTextureCacheCreateTextureFromImage` for `RTCCVPixelBuffer` frames | NV12 and BGRA pixel buffers become Metal textures without CPU copy |
| Done | Add Metal compute shaders for NV12-to-RGBA and I420-to-RGBA conversion | NV12 and I420 are converted in the custom spatial fragment using Metal textures for each plane |
| Planned | Add texture pooling for intermediate RGBA and output textures | Current path renders directly to the drawable; pooling moves to the next performance pass |
| In Progress | Handle crop metadata from `RTCCVPixelBuffer` before conversion/scaling | Core Image fallback preserves crop metadata; direct Metal path still needs crop uniforms |
| Done | Keep Core Image path as a fallback for unsupported formats | Unsupported format logs a fallback without crashing |

Exit criteria:

| Requirement | Target |
| --- | --- |
| CPU cost | I420 fallback no longer performs full-frame CPU RGB conversion |
| Pixel format coverage | NV12, BGRA, ARGB, and I420 frames render correctly |
| Latency | Added local enhancement cost stays inside one frame budget at 60 FPS for common resolutions |

### Milestone 4: Custom Metal Spatial Upscaler

Goal: Replace generic Core Image filters with a single tuned Metal pipeline for game streaming.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Done | Add `src/shaders/OPNVideoEnhancement.metal` | Shader source is currently compiled from the renderer so the Makefile can build without a Metal asset pipeline change |
| Done | Implement aspect-fit sampling with high-quality bicubic or Lanczos-like kernel | RGB path now uses Catmull-Rom style bicubic sampling; YUV paths use GPU plane sampling with bounded cleanup |
| Done | Add edge-aware sharpening with clamp controls | Shader applies bounded local sharpening from the existing 0-10 sharpness setting |
| Done | Add compression-aware denoise pass | Metal shader applies bounded local denoise before sharpening using the existing 0-10 denoise setting |
| Done | Fold color conversion, scale, sharpen, and tone management into minimal passes | BGRA and NV12 paths render directly to the drawable in one render pass |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Quality | Spatial tier visibly beats current Core Image path on 1080p-to-4K game footage |
| Performance | 1080p-to-4K at 60 FPS fits within target device frame budget |
| Correctness | Letterboxing, aspect ratio, and crop are identical to native path |

### Milestone 5: MetalFX Spatial Tier

Goal: Use Apple’s optimized scaler when available, with automatic fallback to the custom Metal spatial tier.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Done | Add availability checks for MetalFX at compile time and runtime | Runtime detection avoids hard-linking MetalFX and keeps builds working without the framework |
| Done | Add `OPNMetalFXUpscaler` wrapper | Renderer can select MetalFX availability without leaking API details into WebRTC code |
| Done | Map upscaling settings to MetalFX-compatible inputs | Renderer converts BGRA, NV12, and I420 frames to a MetalFX-compatible BGRA input texture when needed |
| Done | Compare MetalFX output with custom spatial output | Diagnostics distinguish `OPNMetalFXSpatialScaler` from custom spatial fallback paths |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Availability | MetalFX tier only appears on supported systems |
| Fallback | Unsupported systems continue using custom Metal spatial tier |
| Quality | MetalFX tier is selected when it beats or matches custom spatial performance/quality |

### Milestone 6: Adaptive Enhancement Governor

Goal: Keep input latency and frame pacing stable by dynamically selecting the highest sustainable enhancement tier.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Done | Add local enhancement timing fields to `StreamStats` | UI can show enhancement cost and active tier |
| Done | Implement tier downgrade on missed frame budget, low render FPS, high decode time, or thermal pressure | Renderer downgrades MetalFX to spatial, then spatial to native when frame budget is repeatedly missed |
| Done | Implement slow upgrade after sustained headroom | Renderer restores spatial or MetalFX after sustained headroom |
| In Progress | Add user preference for auto, fixed tier, or off | Existing Upscaler mode now behaves as Auto; explicit fixed-tier UI remains future work |
| Done | Persist active configured tier separately from governor-selected runtime tier | Diagnostics report configured tier, active tier, and governor fallback reason |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Latency | Enhancement never repeatedly exceeds frame budget without downgrade |
| Transparency | Stats show configured tier, active tier, and reason for downgrade |
| Control | User can disable automatic quality scaling |

### Milestone 7: Recording Integration

Goal: Allow recordings to match the enhanced display output when requested.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| In Progress | Add recording preference: raw stream or enhanced output | Recording automatically switches to enhanced output when available; explicit preference remains future UI work |
| Done | Bridge enhanced Metal output to `CVPixelBuffer` through a pixel buffer pool | Renderer captures enhanced drawable output to a retained `CVPixelBuffer` only while recording is active |
| Done | Feed enhanced frames to `OPNStreamRecordingManager` with presentation timing | Enhanced frames use the existing real-time recording timeline |
| Done | Keep raw recording path as fallback | Raw WebRTC recording remains active until enhanced frames arrive, and remains the fallback when enhancement is unavailable |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Capture quality | Enhanced recording visually matches displayed frame |
| Performance | Recording does not add blocking GPU readback on the display command buffer |
| Safety | Raw recording still works on all existing supported systems |

### Milestone 8: Neural Spatial Super-Resolution

Goal: Add a realistic neural upscaler tier tuned for cloud gaming artifacts.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Planned | Select a small real-time SR architecture suitable for Apple Silicon | Model fits target latency and memory budget |
| Planned | Build or acquire training data from game frames with compression artifacts | Training data reflects GFN-like streams, HUD text, particles, motion, and dark scenes |
| Planned | Train separate profiles for 1.5x, 2x, and artifact cleanup | Model avoids oversharpened UI and temporal shimmer |
| Planned | Convert model to Core ML ML Program with fp16 or int8 variants | Runtime loads model without dynamic network access |
| Planned | Add neural tier behind capability and power checks | Intel or unsupported Macs fall back cleanly |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Quality | Neural spatial beats MetalFX/custom spatial in blind internal comparisons |
| Latency | 1080p-to-4K stays viable at 60 FPS on target Apple Silicon hardware |
| Packaging | Model assets are versioned, signed, and loaded deterministically |

### Milestone 9: Neural Temporal Super-Resolution

Goal: Use frame history and motion/confidence information to reconstruct detail while minimizing shimmer.

Tasks:

| Status | Task | Acceptance Criteria |
| --- | --- | --- |
| Planned | Add history buffers for previous input, previous output, and confidence | Buffers reset on resolution changes, seeks, stalls, or scene cuts |
| Planned | Add fast motion estimation or optical-flow approximation | Temporal accumulation aligns stable regions without ghosting fast motion |
| Planned | Add scene-change and disocclusion detection | Renderer avoids carrying stale history across cuts |
| Planned | Train temporal model or hybrid model using previous frames and motion hints | Fine texture improves without HUD trails |
| Planned | Integrate temporal tier with governor and diagnostics | Tier downgrades instantly if frame budget is exceeded |

Exit criteria:

| Requirement | Target |
| --- | --- |
| Stability | No obvious ghosting on fast camera pans, menus, or cursor movement |
| Quality | Better reconstruction than neural spatial on representative games |
| Safety | Temporal state resets correctly on stream format changes |

## Preference and UI Plan

Replace the current two-option upscaling mode with an explicit tier model.

Proposed settings:

| Setting | Values | Notes |
| --- | --- | --- |
| Local Upscaling | Off, Auto, Spatial, MetalFX, Neural, Temporal Neural | Unsupported values are hidden or disabled |
| Sharpness | 0-10 | Applies to spatial cleanup pass and final neural post-sharpen |
| Denoise | 0-10 | Applies to compression-aware denoise |
| Recording Source | Raw Stream, Enhanced Output | Advanced setting |
| Power Policy | Balanced, Quality, Low Latency | Influences governor thresholds |

Settings implementation notes:

| File | Change |
| --- | --- |
| `OPNStreamPreferences.h` | Add richer upscaling tier enum/profile fields |
| `OPNStreamPreferences.mm` | Add migration from existing mode `0/1` to new tier values |
| `OPNSettingsView.mm` | Show supported tiers and explain fallback behavior |
| `OPNStreamView.mm` | Pass target view/backing size and power policy into session |
| `tests/backend_tests.mm` | Add tests for migration, clamping, and unsupported tier fallback |

## Diagnostics and Telemetry Plan

Add renderer diagnostics before quality work begins. This makes every later milestone measurable.

Proposed new `StreamStats` fields:

| Field | Meaning |
| --- | --- |
| `videoEnhancementConfiguredTier` | User-selected tier |
| `videoEnhancementActiveTier` | Runtime-selected tier after governor |
| `videoEnhancementFallbackReason` | Why a lower tier is active |
| `videoEnhancementSourceResolution` | Decoded frame dimensions |
| `videoEnhancementDrawableResolution` | Actual Metal drawable dimensions |
| `videoEnhancementFrameTimeMs` | CPU scheduling plus GPU completion estimate |
| `videoEnhancementDroppedFrames` | Frames skipped by enhancement renderer |

Diagnostics UI should show active tier, frame time, source-to-output scale, and fallback reason in the existing streaming diagnostics surface.

## Verification Plan

Functional verification:

| Scenario | Expected Result |
| --- | --- |
| Upscaling off | Native WebRTC renderer remains stable and aspect-correct |
| Upscaling auto on unsupported MetalFX system | Custom spatial tier is selected or native fallback is explicit |
| 1080p stream on 4K display | Enhanced drawable is larger than source and output is aspect-correct |
| Resize stream window during playback | Renderer updates drawable and intermediate textures safely |
| Change upscaling tier during playback | New tier applies without stream restart |
| Start recording with raw source | Existing recording behavior remains intact |
| Start recording with enhanced source | Capture matches displayed enhanced frame |

Performance verification:

| Metric | Target |
| --- | --- |
| 1080p to 4K spatial at 60 FPS | Local enhancement stays below frame budget on target hardware |
| 1440p to 4K spatial at 60 FPS | Governor avoids sustained frame drops |
| 120 FPS streams | Auto mode selects only sustainable tiers |
| CPU usage | Lower than current CPU fallback path for I420 frames |
| Memory | Intermediate texture pools remain bounded across resize and format changes |

Quality verification:

| Test Clip Type | Focus Area |
| --- | --- |
| HUD-heavy game | Text clarity, halo control, UI shimmer |
| Dark scene | Banding, macroblock smoothing, black crush |
| Fast camera pan | Temporal ghosting, blur, frame pacing |
| Particle effects | Sparkle stability, over-denoise detection |
| Menu transitions | Scene-cut reset and history invalidation |

Automated tests:

| Test Area | Coverage |
| --- | --- |
| Preferences | Tier migration, clamping, defaults, unsupported fallback |
| Governor | Downgrade/upgrade thresholds with synthetic stats |
| Renderer settings | Target size, crop rect, aspect-fit math |
| Diagnostics | Strings and numeric fields update for each tier and fallback |

Manual test matrix:

| Hardware | Priority |
| --- | --- |
| Apple Silicon base model | Highest |
| Apple Silicon Pro/Max | High |
| Intel Mac with Metal | Medium, fallback validation |
| External 4K/5K display | High |
| High-refresh display | High for 120/240 FPS behavior |

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| MetalFX availability varies by SDK, macOS, and GPU | Build or runtime failures | Compile-time guards, runtime capability checks, fallback tiers |
| Neural model latency is too high | Input latency and frame drops | Governor, smaller models, fixed spatial fallback |
| Temporal SR ghosts fast motion | Visible artifacts in gameplay | Scene-cut detection, confidence masks, rapid fallback to neural spatial |
| Recording enhanced output forces GPU readback stalls | Presentation stutter | Use pixel buffer pools and async blit/compute paths, keep raw fallback |
| Pixel format assumptions break on WebRTC changes | Black frames or color errors | Explicit format diagnostics, fallback renderer, test each format |
| Shader complexity grows inside WebRTC session file | Maintenance burden | Keep renderer classes and shaders separate from session negotiation code |
| Model packaging increases app size | Distribution friction | Optional model bundles or tiered model assets if release process supports it |

## Rollout Strategy

Ship incrementally behind explicit tiers.

Release sequence:

| Release | User-visible Change | Internal Change |
| --- | --- | --- |
| R1 | Upscaler becomes accurate and measurable | Correct drawable targeting, diagnostics, extracted renderer |
| R2 | Faster local upscaler | GPU texture ingestion and custom Metal spatial tier |
| R3 | Better quality on supported Macs | MetalFX tier with fallback |
| R4 | Smarter performance | Adaptive governor and richer UI |
| R5 | Optional enhanced recording | Display-matching capture path |
| R6 | Experimental AI upscaling | Neural spatial tier behind capability gate |
| R7 | Best-quality experimental mode | Neural temporal tier behind capability gate |

## Progress Tracker

Legend: `Done`, `In Progress`, `Planned`, `Blocked`.

| Status | Date | Item | Notes |
| --- | --- | --- | --- |
| Done | 2026-06-05 | Audit current upscaler implementation | Current path is Core Image Lanczos, denoise, and unsharp mask |
| Done | 2026-06-05 | Identify major architectural gaps | Drawable targeting, CPU conversion, display-only output, missing adaptation |
| Done | 2026-06-05 | Create implementation plan | This document |
| Done | 2026-06-05 | Milestone 1 drawable targeting | `OPNMetalVideoView` now sizes the Metal drawable from backing view size and records source/drawable resolutions |
| Done | 2026-06-05 | Milestone 1 diagnostics | Added configured/active tier, fallback reason, source/drawable resolution, enhancement frame time, and enhancement fallback count to `StreamStats` |
| Done | 2026-06-05 | Milestone 1 zero-filter upscaling | Upscaler mode now still runs the Core Image scaler when sharpness and denoise are both zero |
| Done | 2026-06-05 | Milestone 1 stats overlay | Overlay reports active enhancement tier, output resolution, and enhancement timing |
| In Progress | 2026-06-05 | Milestone 1 implementation | Remaining cleanup: richer preference tests if mode list changes, and full renderer-owned aspect math during Milestone 2 |
| Done | 2026-06-05 | Milestone 2 implementation | Added `OPNVideoEnhancementRenderer`, settings/result objects, and moved Core Image fallback out of `OPNMetalVideoView` |
| Done | 2026-06-05 | Milestone 3 implementation | Added CVMetalTextureCache ingestion for BGRA/NV12 and GPU plane upload for I420 frames |
| Done | 2026-06-05 | Milestone 4 implementation | Added custom Metal spatial shader path for BGRA, NV12, and I420 frames with bounded sharpening and denoise |
| Done | 2026-06-05 | Milestone 5 implementation | Added `OPNMetalFXUpscaler` runtime wrapper, true scaler binding, and custom spatial fallback when unsupported |
| Done | 2026-06-05 | MetalFX scaler binding | Added weak-linked `MTLFXSpatialScaler` creation, dimension caching, and encode path into the drawable |
| Done | 2026-06-05 | I420 GPU ingestion | Added GPU upload of I420 Y/U/V planes and direct shader conversion, removing the I420 CPU BGRA compatibility path from normal enhanced rendering |
| Done | 2026-06-05 | Higher-order sampling and Metal denoise | Added Catmull-Rom style RGB sampling and bounded shader denoise before sharpening |
| Done | 2026-06-05 | Milestone 6 implementation | Added automatic frame-budget governor that downgrades from MetalFX to spatial to native, and recovers after sustained headroom |
| Done | 2026-06-05 | Milestone 7 implementation | Added enhanced-frame recording bridge from renderer to session to recording manager, with raw stream fallback |
| Planned | Not started | Milestone 8 research | Neural spatial model |
| Planned | Not started | Milestone 9 research | Neural temporal model |

## Immediate Next Actions

Start with Milestone 1 because it derisks every later tier.

| Order | Action | Files |
| --- | --- | --- |
| 1 | Done: Add enhancement diagnostics fields to `StreamStats` | `OPNStreamSession.h`, `OPNLibWebRTCStreamSession.*` |
| 2 | Done: Drive `MTKView.drawableSize` from view backing size while keeping source resolution diagnostics | `OPNLibWebRTCStreamSession.mm` |
| 3 | In progress: Update aspect-fit rendering bounds and remove reliance on layer magnification for enhanced output | `OPNLibWebRTCStreamSession.mm`, `OPNStreamView.mm` |
| 4 | Done: Ensure Upscaler mode with zero sharpness and zero denoise still uses a real scaler or clearly maps to native | `OPNLibWebRTCStreamSession.mm` |
| 5 | Add preference and diagnostics tests | `tests/backend_tests.mm` |
| 6 | Done: Extract enhancement renderer | `OPNVideoEnhancementRenderer.h`, `OPNVideoEnhancementRenderer.mm`, `OPNLibWebRTCStreamSession.mm` |
| 7 | Done: Add direct Metal ingestion and custom spatial path for BGRA/NV12 | `OPNVideoEnhancementRenderer.mm` |
| 8 | Done: Add runtime MetalFX wrapper with custom spatial fallback | `OPNVideoEnhancementRenderer.mm` |
| 9 | Done: Add true MetalFX scaler binding and I420 GPU plane ingestion | `OPNVideoEnhancementRenderer.mm`, `Makefile` |
| 10 | Done: Add adaptive enhancement governor | `OPNVideoEnhancementRenderer.mm`, `OPNStreamSession.h`, `OPNLibWebRTCStreamSession.*` |
| 11 | Done: Add enhanced recording bridge | `OPNVideoEnhancementRenderer.*`, `OPNLibWebRTCStreamSession.*`, `OPNStreamView.mm`, `OPNStreamRecordingManager.*` |

## Verification Log

| Date | Command | Result |
| --- | --- | --- |
| 2026-06-05 | `make test` | Passed, 72 tests |
| 2026-06-05 | `make all` | Passed, full app build succeeded |
| 2026-06-05 | `make all` | Passed after renderer extraction, BGRA/NV12 Metal ingestion, custom spatial shader path, and MetalFX wrapper |
| 2026-06-05 | `make all` | Passed after true MetalFX binding, I420 GPU plane upload, higher-order sampling, and Metal denoise |
| 2026-06-05 | `make test` | Passed, 72 tests |
| 2026-06-05 | `make all` | Passed after adaptive governor and enhanced recording bridge |
| 2026-06-05 | `make test` | Passed, 72 tests |

## Definition of Done

The complete initiative is done when Auto mode can select the best sustainable tier per device, 1080p and 1440p streams can be locally enhanced to high-DPI displays without CPU conversion bottlenecks, diagnostics explain every fallback, recording can optionally capture the enhanced frame, and unsupported systems remain stable on the native renderer.

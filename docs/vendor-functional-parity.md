# Vendor Functional Parity

This document tracks OpenNOW behavior against the vendored GeForce NOW web app. Parity here means user-visible native client behavior and required API protocol compatibility, not byte-for-byte parity with vendor JavaScript bundles.

## Scope

In scope:

- NVIDIA authentication, refresh, logout, and multi-account behavior.
- Provider discovery and region selection.
- Catalog, library, panels, game metadata, ownership, and store URL behavior.
- Session creation, polling, resume, active-session reuse, stop, queue, cleanup, and ad state handling.
- WebRTC signaling, SDP negotiation, ICE handling, audio, video, keyboard, mouse, and gamepad input.
- Stream settings for resolution, frame rate, codec, bitrate, color quality, L4S, prefiltering, microphone, and keyboard layout.
- Native error handling for launch, entitlement, network, capacity, maintenance, storage, and time-cap cases.

Out of scope by design:

- NVIDIA telemetry, feedback, OpenTelemetry, Zipkin, and analytics endpoints.
- PWA install behavior, service worker behavior, browser shell metadata, and web manifest install flow.
- Tizen, Samsung TV, Android Web API, and browser-specific compatibility surfaces.
- Angular, Angular Material, CSS selector, route, and DOM/component parity.
- NVIDIA overlay extras such as G-Assist, social integrations, capture/highlights, and Discord rich presence.

## Current Coverage

| Vendor behavior | OpenNOW coverage | Primary files |
| --- | --- | --- |
| OAuth login and token refresh | Implemented | `src/auth/OPNAuthService.*` |
| Saved sessions and account switching | Implemented | `src/auth/OPNAuthService.*`, `src/OPNAppDelegate.mm` |
| Provider discovery | Implemented | `src/games/OPNGameService.mm` |
| Region discovery and latency ordering | Implemented with latency probing, best-effort nettest session creation, bitrate recommendation, and poor-network continue-anyway warning | `src/streaming/OPNStreamPreferences.mm`, `src/streaming/OPNStreamViewController.mm` |
| Catalog browse, search, filters, panels, and library | Implemented | `src/games/OPNGameService.mm` |
| Store URL resolution and ownership remediation | Implemented with external store open and launch-time remediation sheet | `src/games/OPNGameService.mm`, `src/OPNAppDelegate.mm` |
| Locale-aware requests | Implemented from native preferred locale | `src/common/OPNLocale.*`, `src/auth/OPNAuthService.mm`, `src/games/OPNGameService.mm`, `src/streaming/OPNSessionManager.mm` |
| Cloudmatch device identity | Implemented with centralized stable ID and legacy migration | `src/common/OPNDeviceIdentity.*`, `src/streaming/OPNSessionManager.mm`, `src/streaming/OPNStreamPreferences.mm` |
| Session create, poll, resume, claim, stop | Implemented with shared Cloudmatch session headers and monitor settings on launch/resume requests | `src/streaming/OPNSessionManager.mm` |
| Active-session reuse and session-limit recovery | Implemented | `src/games/OPNGameService.mm`, `src/streaming/OPNSessionManager.mm` |
| Queue and previous-session cleanup progress | Implemented | `src/games/OPNGameService.mm`, `src/streaming/OPNStreamViewController.mm` |
| Session ad parsing and reporting | Partially implemented with active ad playback/reporting, terminal ad-state filtering, native MP4/HLS media preference, and playback-failure reporting | `src/streaming/OPNSessionManager.mm`, `src/streaming/OPNStreamViewController.mm`, `src/views/OPNLoadingView.mm` |
| WebRTC signaling and stream connection | Implemented | `src/streaming/OPNSignalingClient.mm`, `src/streaming/OPNLibWebRTCStreamSession.mm` |
| Keyboard, mouse, and gamepad input | Implemented | `src/streaming/OPNInputProtocol.*`, `src/streaming/OPNStreamViewController.mm` |
| Stream quality settings | Implemented, with display capabilities included and HDR mode still explicitly off | `src/streaming/OPNStreamPreferences.*`, `src/streaming/OPNSessionManager.mm` |
| Vendor launch/session error mapping | Implemented for native launch, resume, network, maintenance, capacity, storage, ownership, time-limit, and stale-session failures | `src/common/OPNGFNError.*`, `src/streaming/OPNStreamViewController.mm`, `src/OPNAppDelegate.mm` |

## Actionable Gaps

1. Expand network-test result parity if needed.

   Vendor evidence includes `/v2/nettestsession`, bandwidth, packet loss, zone warning, and continue-anyway flows. OpenNOW now creates a best-effort nettest session before launch, applies latency-based bitrate recommendations, and prompts before continuing on poor preflight conditions. It still relies on region latency probing plus runtime WebRTC stats because native packet-loss/bandwidth test payload parity is not implemented.

2. Add explicit HDR streaming controls if needed.

   OpenNOW now sends native display dimensions, DPI, and HDR capability metadata in session requests. It still keeps `sdrHdrMode` and `trueHdr` off because there is no explicit user-facing HDR streaming setting yet.

3. Expand account-link and ownership remediation UX if needed.

   OpenNOW parses store URLs, selected store, service status, and `accountLinked`, and now prompts before launching games that appear unowned or unlinked. The vendor app still has fuller embedded store-account linking and entitlement remediation surfaces.

4. Expand locale fallback behavior if needed.

   OpenNOW now centralizes the native preferred locale and uses it for auth UI locale, catalog language, subscription language, launch language, and logout. Some vendor content endpoints may still need per-locale fallback behavior if NVIDIA does not publish every locale file.

5. Expand device identity diagnostics if needed.

   OpenNOW now centralizes the stable Cloudmatch `deviceHashId` and `x-device-id`, preserves the existing OpenNOW device ID plist, and migrates the legacy GeForce NOW device ID file. OAuth still uses its separate login `device_id` value.

6. Decide whether vendor cloud variables affect native behavior.

   The vendor bundle references `https://api.gdn.nvidia.com/cloudvariables/v3`. If those variables control launch/session behavior, OpenNOW should fetch and apply only native-relevant values.

7. Verify free-tier ad media behavior.

   OpenNOW parses session ads, skips vendor terminal ad states, prefers native-playable MP4/HLS media over WebM, presents the active ad, reports start/finish/cancel playback actions, and keeps queue progress updated. It should still be checked against vendor behavior for browser-only ad formats, pause/resume transitions, and all free-tier queue edge cases.

## Non-Goals Checklist

These should not be implemented as parity work unless the product scope changes:

- Sending NVIDIA analytics, telemetry, feedback, or OpenTelemetry payloads.
- Matching Angular routes, component names, CSS classes, or DOM structure.
- Adding service worker, PWA install, or web manifest behavior.
- Supporting Tizen/Samsung TV-specific APIs.
- Adding browser-only permission prompts or unsupported-browser flows.
- Recreating vendor social, capture, G-Assist, or overlay features.

## Verification Targets

Functional parity changes should be verified against these flows:

- Login with a fresh account and with a saved account.
- Refresh an expired session and recover the client token.
- Discover provider endpoints for the selected identity provider.
- Fetch catalog browse results, library results, panels, and app metadata.
- Resolve a store URL for an unowned title.
- Launch a new session and connect WebRTC successfully.
- Resume or claim an existing active session.
- Handle a session-limit response without starting a duplicate launch.
- Stop a running session remotely.
- Exercise queue, previous-session cleanup, and ad-required states.
- Validate selected stream settings appear in session request and SDP.
- Validate region selection, latency display, and network quality warnings.

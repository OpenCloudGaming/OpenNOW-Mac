# Vendor Functional Parity

This document tracks OpenNOW behavior against the vendored GeForce NOW web app. Parity here means user-visible native client behavior and required API protocol compatibility, not byte-for-byte parity with vendor JavaScript bundles.

## Scope

In scope:

- NVIDIA authentication, refresh, logout, and multi-account behavior.
- Provider discovery and region selection.
- Catalog, library, panels, game metadata, ownership, and store URL behavior.
- Session creation, polling, resume, active-session reuse, stop, queue, cleanup, and ad state handling.
- WebRTC signaling, SDP negotiation, ICE handling, audio, video, keyboard, mouse, and gamepad input.
- Stream settings for resolution, frame rate, codec, bitrate, color quality, HDR, L4S, prefiltering, microphone, and keyboard layout.
- Native error handling for launch, entitlement, network, capacity, maintenance, storage, time-cap, and vendor diagnostic code cases.

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
| Region discovery and latency ordering | Implemented with latency probing, nettest session parsing, bandwidth/loss/jitter bitrate recommendation, and poor-network continue-anyway warning | `src/streaming/OPNStreamPreferences.mm`, `src/streaming/OPNStreamViewController.mm` |
| Catalog browse, search, filters, panels, and library | Implemented | `src/games/OPNGameService.mm` |
| Store URL resolution and ownership remediation | Implemented with external store open plus structured launch-time purchase/link/install remediation sheet | `src/games/OPNGameService.mm`, `src/common/OPNGameRemediation.*`, `src/OPNAppDelegate.mm` |
| Locale-aware requests | Implemented from native preferred locale | `src/common/OPNLocale.*`, `src/auth/OPNAuthService.mm`, `src/games/OPNGameService.mm`, `src/streaming/OPNSessionManager.swift` |
| Cloudmatch device identity | Implemented with centralized stable ID and legacy migration | `src/common/OPNDeviceIdentity.*`, `src/streaming/OPNSessionManager.swift`, `src/streaming/OPNStreamPreferences.mm` |
| Session create, poll, resume, claim, stop | Implemented with shared Cloudmatch session headers and monitor settings on launch/resume requests | `src/streaming/OPNSessionManager.swift` |
| Active-session reuse and session-limit recovery | Implemented | `src/games/OPNGameService.mm`, `src/streaming/OPNSessionManager.swift` |
| Queue and previous-session cleanup progress | Implemented | `src/games/OPNGameService.mm`, `src/streaming/OPNStreamViewController.mm` |
| Session ad parsing and reporting | Partially implemented with active ad playback/reporting, required-empty-ad waiting state, queue-paused ad messaging, terminal ad-state filtering, native MP4/HLS media preference, and playback-failure reporting | `src/streaming/OPNSessionManager.swift`, `src/streaming/OPNStreamViewController.swift`, `src/views/OPNLoadingView.mm` |
| WebRTC signaling and stream connection | Implemented | `src/streaming/OPNWebSocketSignalingClient.swift`, `src/streaming/OPNLibWebRTCStreamSession.swift` |
| Keyboard, mouse, and gamepad input | Implemented | `src/streaming/OPNInputProtocol.*`, `src/streaming/OPNStreamViewController.mm` |
| Stream quality settings | Implemented, with display capabilities, explicit HDR request control, local resolution upscaling controls, AI prefilter entitlement/mode gating, and cloud-variable request gating | `src/streaming/OPNStreamPreferences.*`, `src/streaming/OPNSessionManager.swift`, `src/views/OPNSettingsView.mm` |
| Vendor launch/session error mapping | Implemented for native launch, resume, network, maintenance, capacity, storage, ownership, account-link, install-required, ad-required, age restriction, time-limit, stale-session, hex/SRC/NVB, and diagnostic GSEC failures | `src/common/OPNGFNError.*`, `src/streaming/OPNStreamViewController.mm`, `src/OPNAppDelegate.mm` |
| Protocol payload validation | Implemented with opt-in sanitized protocol logging for cloud variables, network tests, create-session, and claim-session payloads | `src/common/OPNProtocolDebug.*`, `src/streaming/OPNStreamPreferences.mm`, `src/streaming/OPNSessionManager.swift` |

## Actionable Gaps

1. Expand account-link and ownership remediation UX if needed.

   OpenNOW parses store URLs, selected store, service status, and `accountLinked`, then classifies launch remediation as purchase/add, account-link, or install-required before opening the external store. The vendor app still has fuller embedded store-account linking and entitlement remediation surfaces.

2. Expand locale fallback behavior if needed.

   OpenNOW now centralizes the native preferred locale and uses it for auth UI locale, catalog language, subscription language, launch language, and logout. Static public game-list fetches fall back through region, language, and `en_US`; GraphQL and session mutations still avoid automatic locale retries unless confirmed safe.

3. Expand device identity diagnostics if needed.

   OpenNOW now centralizes the stable Cloudmatch `deviceHashId` and `x-device-id`, preserves the existing OpenNOW device ID plist, and migrates the legacy GeForce NOW device ID file. OAuth still uses its separate login `device_id` value.

4. Monitor vendor cloud-variable coverage.

   OpenNOW fetches and caches `https://api.gdn.nvidia.com/cloudvariables/v3`, applying only native-relevant stream request gates for codec, HDR, L4S, Reflex, max bitrate, cache TTL, and GPU diagnostics. New variables should remain fail-open unless they clearly affect native launch/session behavior.

5. Verify free-tier ad media behavior.

   OpenNOW parses session ads, skips vendor terminal ad states, prefers native-playable MP4/HLS media over WebM, presents active ads, distinguishes required-empty-ad waiting from queue-paused ad states, reports start/finish/cancel playback actions, and keeps queue progress updated. It should still be checked against vendor behavior for browser-only ad formats, pause/resume transitions, and all free-tier queue edge cases.

## Non-Goals Checklist

These should not be implemented as parity work unless the product scope changes:

- Sending NVIDIA analytics, telemetry, feedback, or OpenTelemetry payloads.
- Matching Angular routes, component names, CSS classes, or DOM structure.
- Adding service worker, PWA install, or web manifest behavior.
- Supporting Tizen/Samsung TV-specific APIs.
- Adding browser-only permission prompts or unsupported-browser flows.
- Recreating vendor social, capture, G-Assist, or overlay features.

## Protocol Capture Workflow

Use sanitized protocol capture only for parity validation. Payloads are redacted before logging or writing, but captured files should still be treated as diagnostic data.

1. Run OpenNOW with protocol capture enabled:

   ```sh
   OPN_PROTOCOL_DEBUG=1 OPN_PROTOCOL_CAPTURE_DIR="$TMPDIR/OpenNOWProtocol"
   ```

2. Launch or resume a session through the target flow.

3. Review sanitized JSON files in `$TMPDIR/OpenNOWProtocol` for payload shape only.

4. Summarize the captured payload shapes:

   ```sh
   scripts/analyze-protocol-captures.py "$TMPDIR/OpenNOWProtocol"
   ```

5. Add parser aliases or error mappings only for native-relevant fields observed in those sanitized payloads.

Captured protocol areas currently include cloud variables, network-test session requests/responses, session create requests/responses, and session claim requests/responses.

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

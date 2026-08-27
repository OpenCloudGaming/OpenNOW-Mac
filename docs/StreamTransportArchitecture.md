# Stream Transport Architecture

OpenNOW has two streaming transports selected per game by `OPNStreamTransportSelector.selectedTransport(forGame:capabilities:)` (`OPN/Stream/StreamTransportSelection.swift`), driven by the launch profile's transport mode:

| | WebRTC path | Native NVST path |
|---|---|---|
| Transport | `NativeWebRTCTransport` | `NvstBifrostFreeTransport` |
| Session/signaling | `OpenNOWStreamSessionCoordinator` + `NVSTWebSocketSignalingClient` | `OpenNOWStreamSessionCoordinator` (as `NativeNVSTSessionProvider`) + RTSPS control plane (`GFN/NVST/Rtsp`) |
| Host view | `WebRTCMediaStreamSurface` (SwiftUI) hosting `NativeWebRTCStreamView` | `NativeNVSTStreamingPath` and its surface overlays |

## Shared boundary

`OPN/Stream/StreamingPath.swift` defines the transport-agnostic contract both paths implement:

- `StreamSessionProvider` — offer/answer lifecycle (`startSession`, `finishSession`)
- `WebRTCStreamTransport` — connect, ICE, input events, session-limit updates
- `StreamSignalingChannel` — answer/ICE/end-event exchange
- `WebRTCStreamingPath` — actor orchestrating provider + transport + signaling

## Rules

- **New stream-facing features must target the `StreamingPath.swift` protocols**, not a concrete transport, unless the feature is inherently transport-specific (e.g. NVST input encoding, WebRTC stats internals).
- The NVST path keeps its protocol stack (`GFN/NVST/BifrostFree`, `GFN/NVST/Rtsp`, `GFN/NVST/Signaling`, `GFN/NVST/SDP`) out of SwiftUI code; views never touch it directly.
- HUD/sidebar components shared by both paths live in `StreamHUDComponents.swift` and must stay transport-agnostic.
- `WebRTCMediaStreamSurface` is the WebRTC host view only; NVST-specific surface behavior belongs to the NVST path's own views.

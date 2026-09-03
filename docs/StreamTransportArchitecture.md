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

## Audio planes

- **Down (game audio):** the seat sends 48 kHz stereo Opus in 5 ms RED-wrapped frames on the
  bundle; `OPNCoreAudioRTCDevice` playout tees decoded PCM to the recorder and Remote Co-Op relay.
- **Up (microphone, NVST):** bundle mic carriage is server-driven — the client only echoes
  `x-nv-general.rtcMicOnNativeBundle` when the seat offered it in DESCRIBE (libBifrost2 parses
  it into config and re-emits it under the diff-vs-default gate), and every current seat offers
  it. Under the offer a send-only `m=audio` (mid 2) section joins the bundle's first answer (NVST
  has no renegotiation), ANNOUNCE echoes the flag plus `x-nv-mic.micSsrcConfig.senderSsrc`, and
  capture flows through the CoreAudio device's input side gated by
  `NvstWebRtcBundle.setMicrophoneCaptureEnabled`. Two facts make it work, both verified live on
  2026-09-03: (1) the seat binds the mic by the vendor's deterministic **SSRC 1**, and libwebrtc's
  only seam for choosing a sender SSRC is the local answer's `a=ssrc` lines, rewritten before
  `setLocalDescription` (`replacingMicrophoneSenderSsrc`; `setParameters` refuses) and read back
  afterwards — a mismatch rebuilds the bundle without the mic section; (2) Opus pt 111 then lives
  in two audio m-sections, which makes libwebrtc disable payload-type demuxing for the bundle's
  audio, so the synthesized offer signals the seat's downlink audio SSRC (`a=ssrc:1` on mid 0)
  or every game-audio packet is dropped as undemuxable — the weeks-long "seat withholds game
  audio whenever a mic section exists" was our own demuxer. The legacy RTSP mic transport
  (`SETUP` + UDP RTP sink) remains unrecovered; a seat that does not offer bundle mic reports
  that when the mic is enabled.

## Rules

- **New stream-facing features must target the `StreamingPath.swift` protocols**, not a concrete transport, unless the feature is inherently transport-specific (e.g. NVST input encoding, WebRTC stats internals).
- The NVST path keeps its protocol stack (`GFN/NVST/BifrostFree`, `GFN/NVST/Rtsp`, `GFN/NVST/Signaling`, `GFN/NVST/SDP`) out of SwiftUI code; views never touch it directly.
- HUD/sidebar components shared by both paths live in `StreamHUDComponents.swift` and must stay transport-agnostic.
- `WebRTCMediaStreamSurface` is the WebRTC host view only; NVST-specific surface behavior belongs to the NVST path's own views.

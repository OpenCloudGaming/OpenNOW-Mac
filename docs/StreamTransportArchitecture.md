# Stream Transport Architecture

OpenNOW uses **NVST for every GeForce NOW launch, resume, and recovery**. Global and per-game
profiles no longer select a transport. Old transport keys are ignored when loading saved profiles;
quality, input, audio, and other settings retain their existing behavior.

| Responsibility | Implementation |
|---|---|
| Allocation, claim/resume, release | `OPNStreamSessionCoordinator`, `OPNSessionManager` |
| Lifecycle and recovery | `NativeNVSTStreamingPath`, `NativeNVSTSessionProvider`, `NativeNVSTTransport` |
| Transport | `NvstBifrostFreeTransport` |
| Session negotiation | RTSPS control plane in `GFN/NVST/Rtsp` |
| Video reception and decode | Raw-SRTP/Mjolnir in `GFN/NVST/BifrostFree`, VideoToolbox |
| Connection, input/control channels, audio | `NvstWebRtcBundle` and `OPNCoreAudioRTCDevice` |
| Host surface and controls | `StreamHostView`, `NativeNVSTMediaStreamSurface`, `NativeNVSTHostViewModel`, `NativeStreamView` |
| Shared settings and media capture | `StreamSettingsResolver`, `StreamRecorder`, `StreamReplayBuffer` |

The standalone WebRTC transport, offer/answer orchestration, session engine, and duplicate SwiftUI
surface/HUD have been removed. `StreamSessionStartCancellable` remains alongside the native
lifecycle contracts in `OPN/Stream/NativeNVSTStreamingPath.swift`.

## Remaining WebRTC dependency

Removing the standalone backend does not yet remove `WebRTC.framework`:

- NVST synthesizes a local SDP exchange from RTSPS answers. `NvstWebRtcBundle` supplies ICE,
  DTLS, SCTP data channels, SRTP game audio, and microphone transmission. Audio does **not** ride
  SCTP data channels.
- `NvstBifrostFreeVideoRenderer` wraps native pixel buffers in RTC frames. `OPNMetalVideoView`
  and its conversion/rendering helpers still use RTC types and renderer classes.
- Remote Co-Op's host, browser guests, and native guests use WebRTC for media and input.
  Co-Op's Automatic/Direct connectivity setting is independent of the GFN transport.

The framework stays linked and embedded in Xcode and SwiftPM, including its required public
headers. `OPN_NVST_WEBRTC_BUNDLE=0` is a STUN diagnostic path, not a replacement connection or
audio implementation. `NvstOpusDecoder` alone does not replace jitter buffering, surround playout,
or microphone capture/transmission.

## Audio planes

- **Down (game audio):** the seat sends Opus over SRTP on the bundle, with channel configuration
  negotiated for the seat, device, and profile. `NvstBundleAudioSDP` handles surround mappings;
  `OPNCoreAudioRTCDevice` playout tees decoded PCM to the recorder and Remote Co-Op relay.
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

Microphone diagnostics in the per-session NVST log separate CoreAudio capture from the RTC
sender: `captureMeter` uses the Settings meter's 6× RMS scale, `captureReadings` and
`captureAgeMs` establish callback activity, and `sourceLevel`/`sourceEnergy`/`sourceSeconds`
describe the audio source feeding the encoder. `rtpPackets` and `tx` count outgoing traffic,
including silence. `remoteReport=present` means a linked RTCP receiver report exists;
`unknown` means no such report is available. Remote-inbound RTC statistics do not provide
`packetsReceived`, so the former `rr=0` field was not evidence of failed server reception.
Bundle diagnostics snapshot owned state under the bundle lock, then query RTC track/channel
properties after releasing it. RTC proxies can synchronously call the signaling thread, whose
statistics callback also needs the bundle lock; holding it across a proxy call deadlocks streaming.
CoreAudio fills the buffer supplied by RTC's recording render callback. The pre-filled-buffer
path in the RTC audio device module treats `frameCount` as an Int16 sample count, discarding
half the interleaved samples from stereo microphones. The render-callback path sizes its buffer
as frames × channels. A live stereo-input check must show `sourceSeconds` advancing at wall-clock
rate, with positive audio energy while speaking, before treating microphone timing as verified.

## Dependency-removal plan

1. **NVST-only application routing.** Remove transport selection and obsolete persisted fields;
   use native CloudMatch identity and secure RTSPS requests for launch and resume. Preserve old
   profiles' other settings. Remove transport-dependent Co-Op gating.
2. **Retire the standalone backend.** Remove its signaling orchestration, transport/session
   engine, decoder factory, surface, and HUD. Preserve shared keyboard mappings, CoreAudio lookup,
   surround SDP, cancellation, input, settings, recording, and replay in their active implementations.
   Steps 1–2 are the current implementation milestone.
3. **Native media boundary.** Make the NVST rendering/enhancement path consume `CVPixelBuffer`
   and native timing/diagnostics directly. Keep RTC conversion at the Co-Op boundary. Validate
   HDR/10-bit/4:4:4 rendering, presentation modes, upscaling, pillarbox fill, screenshots, and capture.
4. **Native connection and audio.** Select and validate an interoperable ICE/DTLS/SCTP/SRTP
   implementation before replacing `NvstWebRtcBundle` in place. Preserve reliable/partial input,
   feedback, reconnect, key handling, Opus jitter/loss recovery, stereo/surround, device changes,
   and microphone modes. Canonical libraries and captured protocol fixtures must be evaluated
   against live GFN seats; no replacement stack has been selected yet.
5. **Confine WebRTC to Co-Op.** Require a source/dependency audit showing that no GFN runtime
   path relies on RTC types or behavior. Keep Co-Op functional using its existing transport.
    Final framework deletion requires a separately designed replacement for browser and native
    Co-Op connections.

### Native bundle replacement deliverables

The seat still requires STUN/ICE, DTLS, SCTP, RTP and SRTP. Removing `WebRTC.framework` from
NVST means implementing those required protocols through native components rather than removing
them from the wire protocol.

The official client's own stack, inspected 2026-09-23 in `/Applications/GeForceNOW.app`, confirms
those requirements and the library lineage. `libBifrost2.dylib` links only system libraries and
statically embeds a WebRTC-derived stack: libwebrtc `net/dcsctp`, NVIDIA's OpenSSL fork
`nssl-3.5.7-fa0bcc66f3` (DTLS with `SSL_CTX_set_tlsext_use_srtp` and
`SSL_export_keying_material`, advertising `SRTP_AEAD_AES_256_GCM` and `SRTP_AES128_CM_SHA1_80`),
an `SrtpTransport`/`SecureRtp` pair using the libsrtp2 API, libopus with
`opus_multistream_decoder_create` and RED at 2/6/8 channels, and its own audio jitter buffer with
FEC, resync, and concealment. `libGsAudioWebRTC.dylib` is NVIDIA's CoreAudio device wrapper with
libwebrtc AEC3. Their stack is embedded rather than shared, so it cannot be linked: an
independent implementation is required, and the API lineage makes OpenSSL + libsrtp2 + usrsctp +
libopus the directly comparable set. Their AEC3 presence also means microphone echo cancellation
is available on the official path and is absent from ours.

1. **Secure bundle prototype.** Bind the routed UDP socket, generate the local certificate, and
   return its fingerprint and port before RTSP ANNOUNCE. Preserve the vendor's ICE credentials,
   STUN behavior, DTLS client role, remote fingerprint verification, and NAT keepalive behavior.
   Prove DTLS-SRTP profile negotiation and key export against a live seat. OpenSSL is an initial
   DTLS candidate; library selection remains subject to this interoperability gate.
2. **SCTP control/input.** Evaluate usrsctp over the DTLS association. Implement data-channel
   OPEN/ACK messages and preserve all eight existing channel labels/IDs, ordering, lifetimes,
   and retransmission policies. Reuse the recovered NVST command encoders and feedback logic.
   Verify keyboard, mouse, gamepads, haptics, cursor notifications, and seat termination.
3. **Native game audio.** Evaluate libsrtp and libopus, including multistream Opus. Implement RTP
   ordering/timing, RED depacketization, jitter buffering, loss concealment, applicable FEC, and
   stereo/surround output. Feed CoreAudio, recording, replay, and Co-Op from native PCM buffers.
4. **Native microphone.** Capture the selected CoreAudio input, preserve samples across channel
   counts, resample and packetize on the negotiated clock, encode Opus, and protect outgoing RTP.
   Preserve SSRC negotiation, mute, push-to-talk, gain, and device changes. Prove audibility with
   the cloud Steam voice test as well as packet/sample counters.
5. **In-place integration.** Replace the bundle implementation and RTC audio-device dependency
   in place, with native lifecycle, cancellation, statistics, and recovery. Complete the separate
   native video boundary so no NVST renderer/enhancement path still consumes RTC frame types.
   Audit GFN runtime imports and transitive dependencies; RTC conversion stays at Co-Op's boundary.

The first transport milestone is a live authenticated bundle carrying a control command and
decryptable game audio. Successful STUN alone does not establish a replacement transport.

### Verification gates

- Xcode build/tests establish that the single host path compiles and the native lifecycle,
  request, old-profile, input, recording/replay, and Co-Op regression coverage passes.
- Strict UI lint and review at UI scales 1.25 and 1.5 cover the changed settings and stream surfaces.
- Live GFN launch, resume, cancellation, network recovery, audio/microphone, input, capture, and
  Co-Op host/browser/native guest checks establish interoperability; unit tests cannot establish it.
- Each lower-level replacement must pass its media/protocol gate before deleting its current
  implementation. A probe-only or audio-decode-only path is insufficient evidence.

### Milestone 1–2 verification, 2026-09-23

- Xcode 27 built the macOS arm64 application and test target. After fixing Co-Op certificate
  persistence, the full suite reported **2,165 passed, 4 skipped, and 0 failed** across 2,169 tests.
  The native loopback failures came from `.completeFileProtection` rejecting the atomic PKCS#12
  write with `EPERM`. A normal atomic write with enforced `0600` permissions fixes the failure.
  Regression tests cover persistence, certificate reuse, and replacement when the host changes;
  native loopback tests use isolated certificates and verify the server fingerprint.
- Strict repository SwiftLint completed with zero violations; the baseline was not changed.
- Offscreen Network, About, Co-Op settings, and launch-loading layouts were inspected at 1.25×
  and 1.5×. Native text fields are outside `ImageRenderer`'s coverage. The temporary capture
  harness was removed after inspection.
- Live authenticated NVST launch/resume/recovery and host/browser/native Co-Op media checks
  remain outstanding. The unit-test and layout evidence does not establish live interoperability.

## Rules

- Stream-facing features use `NativeNVSTStreamingPath` contracts and the host view model.
- Keep the NVST protocol stack out of SwiftUI code.
- Shared HUD/sidebar components live in `View/Stream/StreamHUDComponents.swift`.
- Retain WebRTC-specific names where the implementation genuinely depends on the framework;
  shared native input, settings, and capture code use transport-neutral names.

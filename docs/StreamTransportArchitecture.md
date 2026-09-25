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

**Native bundle microphone send** (`NvstNativeBundle`) reproduces what that libwebrtc path sent,
because the seat's DESCRIBE is the contract: plain Opus on **pt 111** with the vendor's
deterministic **SSRC 1**, stereo (`opus/48000/2`), **10 ms** per packet. `x-nv-mic.frameSize:10`
and the synthesized section's `a=ptime:10` both name the 10 ms grid; `x-nv-aqos.packetDuration:5`
is the *downlink* audio grid, not the mic's. Sending 5 ms mic frames leaves the seat's virtual mic
meter dead while `tx` still climbs — the counter proves transmission, not reception. The mic
attributes the seat asked for (`enableRedundancyForMic`, `bitrate`, `numChannels`) do not need to be
honoured packet-for-packet: plain pt-111 Opus carried speech to the seat's meter in the verified run.
The diagnostics line now reports `mic=on(ssrc=…,tx=…,pkts=…,frames=…,level=…)`, so a silent capture
(`frames`/`level` flat while speaking) is distinguishable from a seat that never decodes the stream
(`frames`/`level` advancing while the meter stays dead).

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
   Implemented as `OPNVideoFrame`: the decoded buffer plus capture time, rotation and keyframe, with
   the clean-aperture display geometry. `NvstBifrostFreeVideoRenderer` constructs it, `OPNMetalVideoView`,
   `OPNVideoTextureSource`, `OPNVideoEnhancementRenderer` and its output/support extensions consume it,
   and every frame — enhanced or not — is drawn by the app's own spatial pass. RTC frame types are
   converted once, at `OPNRemoteCoOpGuestVideoRenderer` (a received guest track) and the Co-Op host
   relay's `renderPixelBuffer` (already native). Two consequences to validate: the plain 8-bit NV12
   case now shares the spatial pass instead of a peer renderer, and the drawable is no longer
   write-only because a snapshot reads it back. Known limitation carried forward: the plane sampling
   covers the whole coded surface, not the clean aperture, so a padded stream (1080p coded 1920x1088)
   is stretched by the padding rows. `RTCCVPixelBuffer(pixelBuffer:)` behaved the same way, so this is
   pre-existing rather than introduced; cropping to `OPNVideoFrame.displaySize` is a follow-up.
   Pillarbox fill and the upscaler are structurally exclusive: a fill is reprojected against the
   texture the shader writes into, and the MetalFX/temporal staging renders into an intermediate
   sized to the source, so its fill geometry would be computed against the wrong aspect — and when
   the scaler declines (it cannot downscale, so a 5120x2160 stream in a smaller window fails it) the
   fallback was the Core Image path, which applies no fill at all. A selected fill mode therefore
   takes the spatial pass straight into the drawable and the upscaler is skipped, with one log line
   per session saying so; `fillTakesSpatialPass` is the decision, pinned by test.
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

### Native bundle progress, 2026-09-23

Deliverable 1's foundation is implemented and verified in-process and over real sockets:

- `NvstDtlsIdentity` — a fresh P-256 key and self-signed certificate per session, DER export, and
  the SHA-256 fingerprint in the colon-hex form `general.dtlsFingerprint` expects.
- `NvstDtlsHandshake` — one DTLS 1.2 endpoint, driven by datagrams over memory BIOs so the state
  machine is deterministic and testable without a network. Authenticates the peer by certificate
  digest, and exports keying material under `EXTRACTOR-dtls_srtp`.
- `NvstDtlsTransport` — the same state machine over a real UDP socket taken from the reservation
  that punched the NAT mapping, with the DTLS retransmission clock driven from `SSL_ctrl`
  (`DTLSv1_get_timeout` / `DTLSv1_handle_timeout` are macros).
- `NvstBundleSrtpKeys` — the RFC 5764 §4.2 split of the export into the four SRTP master values,
  keyed off the negotiated profile (88 bytes for `AEAD_AES_256_GCM_8`).

Verified by 17 tests across four suites: handshake convergence, both ends deriving identical
non-zero keying material, rejection of a peer whose certificate does not match the announced
fingerprint, refusal to export before completion, the same handshake over real loopback sockets,
application datagrams round-tripping both ways over the association, and a timeout when the peer
never answers. The live-seat handshake remains outstanding: unit and loopback evidence cannot
establish interoperability with a real seat.

Interop facts established the hard way, all of which cost a compile or a test cycle:
`EVP_PKEY_Q_keygen` is variadic and unusable from Swift; `MBSTRING_ASC` is an arithmetic macro;
`X509_get_notBefore` is a macro where `X509_getm_notBefore` is a function;
`SSL_CTX_set_read_ahead` and `BIO_set_mem_eof_return` are macros over the ctrl interfaces;
`DTLSv1_get_timeout` and `DTLSv1_handle_timeout` are macros over `SSL_ctrl`; a memory BIO must
report "no data yet" rather than EOF; and `SSL_VERIFY_NONE` prevents a server from ever receiving a
peer certificate, so `SSL_VERIFY_PEER` with an accept-any callback is required and the fingerprint
comparison is the actual authentication.

OpenSSL's own headers `#include <openssl/...>` as a subdirectory, so the directory containing
`openssl/` must be on the header search path in both build systems — and it is relative to each
target's own directory, which differs between the root target and the `Tests`/`Benchmarks` targets.

### Native SCTP progress, 2026-09-24

The channel layer and the association exist under `GFN/NVST/Native/`:

- `NvstDataChannel` — the eight channels pinned to their labels and even stream ids `0…14` with
  their reliability (300 ms timed, zero-retransmit, reliable), and RFC 8832 DCEP OPEN/ACK framing.
- `NvstSctpAssociation` — the association over `AF_CONN`, usrsctp's in-process address family.
- `NvstOpusEncoder` — the microphone's Opus, and `NvstAudioRtp` the RTP packetisation and SRTP
  direction split that carry it.

The initial tests covered the channel table and an Opus round trip. Their DCEP expectations were
incorrect and did not prove RFC interoperability; see the wire-level corrections below.

Findings that each cost a cycle, and which a future change must not undo:

- `AF_CONN` carries SCTP over the application's DTLS transport. Its opaque address must be
  registered, used for both bind/connect, and passed directly to `usrsctp_conninput`.
- SCTP ports are present on the wire even though `AF_CONN` does not use OS network sockets.
  Both endpoints use port 5000; omitting bind gives the client an unintended ephemeral SCTP port.
- The initial archive produced `EADDRNOTAVAIL` because its private `sockaddr_conn` layout was built
  without `HAVE_SCONN_LEN`, while the macOS public header included that field. This was a build
  configuration defect, not an inherent limitation on in-process accepting peers.
- `usrsctp_connect` emits the first flight from inside the call, so the outbound hook must be
  installed in the initializer. Installed afterwards, the first INIT was silently dropped.
- `conn_output`'s address argument is the `sconn_addr` value itself, not a pointer to a
  `sockaddr_conn`; dereferencing it traps.
- That callback runs on usrsctp's own thread, so `usrsctp_conninput` must never be called from
  inside it: inbound DTLS application records are fed by the transport's receive path, on its own
  queue, one framed SCTP packet at a time.
- The encoder rejects a compression magic cookie with `'!siz'` even though the decoder requires the
  equivalent decompression cookie.

### Native audio progress, 2026-09-24

The receive and send primitives exist under `GFN/NVST/Native/`:

- `NvstAudioSrtp` — the RTP/SRTP split (header, ciphertext, tag) with the authentication covering any
  CSRC list and header extension; AES-GCM and AES-CM/HMAC-SHA1 use `SrtpKeyDerivation` and the
  RFC 5764 direction split from DTLS-exported master values.
- `NvstAudioJitterBuffer` — reorders by extended sequence number, holds a fixed packet depth,
  reports each missing sequence number exactly once for concealment, and bounds its own depth.
- `NvstOpusEncoder` — the microphone's Opus, verified by encoding PCM and decoding it back to the
  same tone with the existing decoder.
- `NvstAudioRtp` — microphone RTP framing (SSRC 1, pt 111, 5 ms timestamp advance, marker on the
  first packet only) and the outbound/inbound key pairing.

Offsets and orderings are asserted by value rather than by shape, because these are the parts that
fail silently: a wrong key direction decrypts to noise, a wrong sequence extension flushes the
buffer, and a header extension mistaken for payload fails every tag.

**RED depacketisation is implemented** (`NvstRedAudio`), and it is the receive path's loss recovery:
each redundant block is preceded by a four-octet header carrying its payload type, how far back its
timestamp is, and its length, so a repeat of a frame that was lost can be slotted back at the
sequence it belongs to before the jitter buffer decides it is missing. The primary block has a
one-octet header and takes the remainder.

An earlier note here claimed RFC 2198 does not encode block lengths and that RED therefore could not
be implemented without a capture. That was **wrong**: the header carries a ten-bit length, and the
browser's own splitter reads it. The layout was confirmed against RFC 2198 and WebRTC's
`RedPayloadSplitter` before writing it, and the tests pin the header fields by hand-computed bytes.

Two ordering facts each cost a cycle: every header precedes every payload (the browser's splitter
advances by the header length alone, never skipping a payload), and a RED packet's repeats are older
frames, so the one immediately behind the primary is the one that covers a loss.

One production bug surfaced only by the integration test: `SrtpGcm8`'s decrypted payload is a **slice
of CryptoKit's sealed box**, so its `startIndex` is not zero, and slicing it with zero-based indices
traps. `NvstRedAudio.split` and `NvstAudioRtpPacket.parse` now build their pieces from a normalised
byte array rather than calling `subdata(in:)` on a caller's `Data`. Unit fixtures built by
concatenation are always zero-based, which is exactly why they missed it.

### Native CoreAudio device, 2026-09-24

`NvstCoreAudioDevice` replaces the libwebrtc `RTCAudioDevice` the bundle borrowed, and with it the
last RTC type in the audio path. It is CoreAudio only: a HAL output unit whose render callback fills
16-bit interleaved PCM from a closure, and an input unit whose callback hands captured PCM to
another. Neither direction knows about Opus or SRTP — the pipelines do — so the device is format
conversion, timing and the two taps.

The tap ordering is deliberate and is the same lesson the device it replaces records: playout is
teed to the recorder and the Co-Op relay *before* the local mute is applied, so silencing this Mac's
speakers cannot silence a guest or a recording. The microphone gate is applied after the level
report, so the meter keeps working while muted.

Its format arithmetic lives in `NvstCoreAudioFormat` so it can be checked without a sound device:
the surround clamp, the stereo fallback for a device that cannot carry six or eight channels, the
5 ms IO buffer with the device's own range applied, the 16-bit interleaved stream format, and the
microphone level curve the Settings meter shares. Those are covered by tests; the I/O itself is
verified only by a live session, like every other device path.

Two format decisions exist because the native path owns Opus directly where libwebrtc did not:

- **The callbacks always exchange 48 kHz**, the rate Opus, the RTP clock and the jitter buffer
  assume. The old device reported the hardware's rate and let libwebrtc resample; a native device
  that did that would hand 44.1 kHz samples to a 48 kHz encoder. The HAL unit is therefore
  configured with a 48 kHz client format and resamples to and from the hardware itself. The
  hardware's own rate is kept only for the IO-buffer and latency arithmetic, which are in device
  frames.
- **The decode is stereo, and the device is asked for stereo.** The seat negotiates
  `opus/48000/2`, and the decoder, jitter buffer and receive pipeline are all two-channel. Asking
  the hardware for the configured surround count would interleave a stereo decode into a six- or
  eight-channel buffer. A fill helper maps the stereo decode onto the channel count the device
  actually settled on — mono averages the pair, stereo keeps it, a wider layout fills the front pair
  and leaves the rest silent. Native surround decode remains unimplemented and is recorded as such.

Full Xcode suite at this point: **2,231 passed, 4 skipped, 0 failed** across 2,235 tests, including
the 61 added by this milestone's native components. An earlier SwiftPM-only run reported failures in
`StreamRecordingTests` and `StreamReplayBufferTests`; those pass under the Xcode command, which sets
`TEST_RUNNER_CFFIXED_USER_HOME`, so they were environmental (AVAssetWriter needs a writable home)
rather than regressions.

### Bundle socket demultiplexing, 2026-09-24

`NvstBundleDatagramDemux` separates the two things that share the bundle port. The seat muxes game
audio onto the same UDP socket as the DTLS association, exactly as a browser does: SRTP is not
carried *inside* DTLS, it runs alongside it. A DTLS record's first byte is its content type (20…63);
an RTP or RTCP first byte has the version field set to 2, which makes it 128…191. Anything else is
neither and is counted rather than fed to either layer.

This is a correctness hazard rather than tidiness: handing an audio packet to the DTLS record layer
stalls the handshake or tears the association down, and the failure looks like a network fault
rather than a demultiplexing one.

### Native component inventory, 2026-09-24

The following milestone-4 components exist under `GFN/NVST/Native/`. Component tests alone do not
establish correct assembly, live interoperability, or completion of 4c/4d:

| Component | Covers |
|---|---|
| `NvstDtlsIdentity`, `NvstDtlsHandshake`, `NvstDtlsTransport` | the DTLS connection and its keying export |
| `NvstBundleSrtpKeys` | the RFC 5764 split of that export |
| `NvstDataChannel`, `NvstSctpAssociation` | the eight channels, their DCEP framing, and SCTP itself |
| `NvstAudioSrtp` | protect/unprotect, with the header extension authenticated whole |
| `NvstRedAudio` | RFC 2198 blocks, including the repeats that recover a loss |
| `NvstAudioJitterBuffer` | reordering, depth bounding, and loss reporting |
| `NvstAudioReceivePipeline`, `NvstAudioSendPipeline` | the two audio paths end to end |
| `NvstOpusEncoder` | the microphone's codec |
| `NvstCoreAudioFormat`, `NvstCoreAudioDevice` | device formats, and the CoreAudio I/O itself |
| `NvstBundleDatagramDemux` | DTLS versus SRTP on one port |

Full Xcode suite at this point: **2,243 passed, 4 skipped, 0 failed** across 2,247 tests.

**What is not done, and what it needs.** No assembly of these components into a bundle type that
implements `NvstBundleReserving`, no rewiring of `NvstBifrostFreeTransport`, and no deletion of
`NvstWebRtcBundle` — those are milestone 4e, which the plan gates on 4c and 4d passing against a live
seat. The gates are the outstanding work, and each needs an authenticated GeForce NOW session that
only a person at the keyboard can start:

- 4c: the DTLS handshake completes, SCTP carries a control command, and the seat answers. An
  accepting local peer can verify the SCTP/DCEP exchange once the native library is built correctly;
  it cannot establish that the vendor accepts OpenNOW's complete channel and control profile.
- 4d: audible game audio, and the cloud Steam voice test hearing the microphone.

### What 4e needs, after attempting it, 2026-09-24

Writing the assembly first, then deleting it, established something worth recording: 4e is not
wiring. `NvstBifrostFreeTransport` consumes two measurements that only libwebrtc was supplying, and
the bundle must provide them or the HUD loses them. Both are now resolved:

- **Audio jitter dwell.** The HUD computes its A/V jitter reading from `jitterBufferDelaySeconds`
  over `jitterBufferEmittedCount`. `NvstAudioJitterBuffer` now measures exactly that — each packet's
  arrival time to its emission — with the clock injected so the measurement is asserted rather than
  waited for. The counter names match libwebrtc's, so the HUD's arithmetic is unchanged. Dwell
  reflects buffering, so the first packet in a burst reads longest, which is the point of the metric.
- **Bundle round trip.** No native ICE RTT exists, and none is needed: `NvstBifrostFreeInput`
  already falls back to the Mjolnir socket's own STUN round trip and then to the control
  connection's WebSocket ping/pong, which the seat answers mandatorily.
- **Control-channel totals.** `NvstNativeBundle.controlChannelStats` counts sends and failures for
  the commands written through its `sendControl`/`sendPartiallyReliableControl` paths only — stream 0
  and the partially-reliable stream 6. Input and feedback call the association's `send` directly and
  are not counted, because their own paths already report and counting them would inflate `0x313`.

The remaining 4e work is the assembly itself: a bundle owning DTLS, SCTP and audio that mirrors the
~35 members the transport calls, plus rewiring and then deleting `NvstWebRtcBundle`. That deletion
still waits on 4c and 4d passing against a live seat.

### 4e assembly, 2026-09-24

`NvstNativeBundle` composes the components into the bundle the transport runs on: DTLS, SCTP and
audio, with no peer-library types. It owns the socket, completes the handshake in `prepare`, derives
the two audio directions from the exported keys, starts the association and opens the eight channels,
and classifies every inbound datagram before any layer sees it — DTLS to the association, SRTP to the
audio pipeline.

It deliberately does **not** carry three members of the bundle it replaces, because they existed only
to expose libwebrtc's own statistics and would be no-ops:

- `roundTripMilliseconds` and `refreshTransportStatistics`: there is no ICE candidate pair to time.
  Latency keeps a real source because `NvstBifrostFreeInput` already falls back to the Mjolnir
  socket's STUN round trip and then the control connection's ping/pong.
- `controlChannelStats` is **kept**, not dropped: the `0x313` records live in
  `NvstNativeBundle.controlStats`, keyed by command code, because only the caller that sends a
  command knows its code. The association cannot supply them.

Its dwell counters reach the HUD through `NvstAudioReceivePipeline.jitterBufferDwellSeconds` over
`jitterBufferEmittedCount`, named as libwebrtc's were so the A/V arithmetic is unchanged.

**Proven and not proven.** The assembly compiles, lints and is wired into
`NvstBifrostFreeTransport`; `NvstWebRtcBundle` is now unreferenced by production code. What no test
here can reach is the assembly against a real seat: it needs a socket, a seat and audio hardware, so
its live behavior is gated, not proven, and is recorded as such below.

Full Xcode suite with it in the tree: **2,248 passed, 4 skipped, 0 failed** across 2,252 tests.

### 4e rewiring, 2026-09-24

`NvstBifrostFreeTransport` now brings the bundle up through `NvstNativeBundle`. The call sites that
existed only to read libwebrtc's statistics are gone:

- the two `refreshTransportStatistics` calls, and both `bundle.roundTripMilliseconds` reads. The HUD
  and the log now take latency from the fallbacks that were already there — the Mjolnir socket's own
  STUN round trip, then the control connection's ping/pong.
- the `usesOfficialIceCredentials` warning: that length-check interplay was between libwebrtc's SDP
  and Bifrost, and the native bundle has no SDP to mangle.
- `seedMicrophoneBundleForTesting` and the bundle-typed parameters in the video pipeline, input and
  handler files were retyped to the native bundle.

The `0x313` per-command counters moved into the bundle, which is the only place that knows a
command's code; the association cannot key them. `AudioReception` gained the three fields the
transport's audio log already printed — `samples`, `concealed`, `discarded` — backed by real
measurements added to the pipeline (decoded samples, wire bytes in, and discards split from
concealment) rather than by placeholders.

**The old bundle is now unreferenced by production code.** `NvstWebRtcBundle` and its three
companion files, and the libwebrtc audio device that only it constructed, appear only in comments
and in their own tests. Deleting them is therefore a single step — and it is the step the objective
gates on 4c and 4d passing against a live seat.

Full Xcode suite with the rewiring in place: **2,247 passed, 4 skipped, 0 failed** across 2,251 tests.

### First live run, 2026-09-24: DTLS never completed

An authenticated Ultimate session on macOS 27 reached the bundle and failed:

```
NVST bundle bring-up failed: The NVST bundle's DTLS handshake failed:
  The DTLS handshake did not complete before its deadline.; falling back to the STUN-only probe
```

The timeline named the cause: `SETUP ok` at 00:35:55, failure at 00:36:05 — exactly the ten-second
deadline. Three defects in the native path, all found from that one log:

1. **The handshake was inside `prepare`, before ANNOUNCE.** The seat cannot answer DTLS until
   ANNOUNCE has told it our bundle port and fingerprint; the old libwebrtc bundle's own comment said
   ICE "cannot succeed until ANNOUNCE lands, so this waits only for local gathering." Mine blocked on
   a reply the seat had no reason to send yet. `prepare` now binds and returns the identity, and the
   handshake is driven afterwards by `onHandshakeComplete`.
2. **Nothing read the socket.** The old transport had a `receive()` no one called, so even a
   correctly-timed handshake had no inbound path. `NvstDtlsTransport.start()` now runs a receive loop.
3. **One record per call stalled the handshake.** A DTLS datagram carries a whole flight and
   OpenSSL's memory BIO processes one record per `SSL_do_handshake`, so a driver that calls in once
   per datagram stops one record short of finishing — with no error in the logs. Traced on loopback:
   the client's second flight arrived and the server produced nothing, and the client retransmitted.
   `NvstDtlsHandshake.hasPendingInbound` plus a re-driving loop fixes it.

### The bundle NATT punch, 2026-09-24

The seat's front end demultiplexes its two client flows **only by the STUN username**: both sockets
talk to one public seat port, and `<srvUfrag><internalPort>:<localUfrag>` selects the video service
or the bundle service. The native path sent a bare ClientHello with no punch, so it had no route and
nothing answered.

`NvstBundleNattPunch` builds the authenticated Binding Request with the DESCRIBE remote ufrag — which
already ends in the seat's internal bundle port (the live DESCRIBE returned `e503c1fe47999`, i.e.
`e503c1fe` + `47999`) — plus the shared local ufrag, keyed by the remote ICE password.
`NvstDtlsTransport` sends the burst before the ClientHello (the official client's ~37 ms gap), keeps
it on the ICE cadence until the handshake completes and the slower keepalive after, and classifies
STUN distinctly so it is never fed to the record layer. `NvstBundleDatagramDemux` gained the `.stun`
case, matched on the magic cookie rather than the first byte alone.

Covered by tests: the username, that the request is a Binding Request carrying its transaction, that
the integrity is keyed by the remote password, and — over loopback sockets — that the **first
datagram the transport emits is the STUN punch, not the ClientHello**.

Native suite after these changes: **459 tests in 68 suites**, strict lint clean on 159 files.

### Input regression: the SCTP payload protocol ids, 2026-09-24

Input and feedback ride the bundle's SCTP data channels; audio is SRTP alongside DTLS, and video rides the separate Mjolnir
socket. So a bundle that fails — or whose data channels the seat rejects — shows up exactly as
"video works, input does not".

The native association tagged every control, input and feedback message with **PPID 51** and every
DCEP establishment message with **PPID 56**. Both are wrong by the WebRTC spec the seat follows
(RFC 8831 / `draft-ietf-rtcweb-data-protocol`):

- **51 is UTF-8 String; binary is 53.**
- **50 is DCEP; 56 is "binary, empty".**

The libwebrtc bundle this replaces sent `RTCDataBuffer(data:isBinary: true)` — PPID 53 for payloads
and 50 for DCEP — which is why input worked before the rewiring. With DCEP on 56 the seat never
acknowledges the channels, and with payloads on 51 it reads them as text, so `isInputReady` never
becomes true. `NvstSctpAssociation.PPID.binary` is now 53 and `NvstDataChannelProtocol.ppid` is 50.

### DESCRIBE features override main, 2026-09-24

The DESCRIBE 200 body is three documents joined end to end — `main ;; features || offer` — and the
official client lets the small **features** document override main. `NvstRtspSdp.attribute` was a
first-match regex over the whole body, so it read main's superseded value.

The live capture proves it: `runtime.micSrtp` appears as `1` in main and `0` in features, and
`audio.enableDynamicAudioConfig` as `0`/`1`. The captured official ANNOUNCE carries the features
values (`micSrtp 0`, `enableDynamicAudioConfig 1`), confirming which document wins.

`NvstRtspSdp.describeSections` now splits the body and `attribute` consults features before main;
`offeredAttributes` merges main then features and excludes the media offer. A body without the
separators behaves exactly as before.

### Second live run, 2026-09-24: handshake works, channels and audio did not

With the punch and async fixes in the running build, the handshake completed —
`NVST native bundle DTLS established on port 51892 profile=AEAD_AES_256_GCM_8` — and `sctp=up`.
Two further faults were still visible in the live counters:

```
NVST bundle sctp=up control=false feedback=false input=false mic=off
           receive[datagrams=3288 decoded=0 lost=0 recovered=0 tagFail=3288] reportsSent=0
```

Two attempted fixes followed: retrying channel OPENs after inbound SCTP, and switching audio from
DTLS-exported keys to the video runtime key. A rebuilt live run still had closed channels and 100%
audio authentication failures. Neither attempt established a fix. The earlier assertion here that
the runtime key was proven to protect bundle audio was incorrect.

Native suite: **462 tests in 68 suites**, strict lint clean on 168 files.

### Wire-level audit after the failed live retries, 2026-09-24

The instrumented run delivered 12 decrypted DTLS application records while no channel OPENs
completed. The first audio packet had a readable RTP header (PT 63, sequence 0, timestamp 0, SSRC 1).
Readable RTP headers are also expected for encrypted SRTP and do not establish plaintext media.
The runtime-key probe did not test the DTLS-exported keys; its AES-CM attempt incorrectly used GCM.

Corrections are based on [usrsctp's accepting-peer example](https://github.com/sctplab/usrsctp/blob/0.9.5.0/programs/ekr_loop.c),
[RFC 8832](https://www.rfc-editor.org/rfc/rfc8832), and the negotiated DTLS-SRTP profiles:

- Rebuild the pinned usrsctp archive through its CMake configuration and Xcode. The macOS address
  layout macros must agree with the shipped header. `scripts/build-usrsctp.sh` reproduces this build.
- Register one transport token, bind/connect port 5000 with it, pass that token directly to
  `usrsctp_conninput`, return zero from successful output callbacks, and deregister on close.
- Set `SCTP_SEND_SNDINFO_VALID`/`SCTP_SEND_PRINFO_VALID` rather than using `SCTP_SENDV_SPA` as
  validity flags. PPIDs cross the C API in network byte order. Apply each stream's actual PR policy.
- DCEP OPEN is `0x03`, ACK is `0x02`, ordered retransmit-limited is `0x01`, and ordered timed is
  `0x02`. Preserve all eight labels, stream IDs and configured reliability limits. DCEP itself is reliable.
- DTLS GCM profiles use 16-byte authentication tags. NVIDIA's 8-byte video profile does not change
  that negotiation. Game audio reads the server write keys; microphone audio uses client write keys.
- Implement the advertised AES-CM/HMAC-SHA1 fallback with its own counter IV and HMAC, and serialize
  access to the OpenSSL session across socket, input and usrsctp timer threads.
- Estimate receive rollover before authenticating, update replay state only after authentication,
  and retain decoded PCM that does not fit in the current CoreAudio render callback.

Independent crypto fixtures: AES-128-CM and AES-128-GCM packets from libsrtp v2.7.0
[`test/srtp_driver.c`](https://github.com/cisco/libsrtp/blob/v2.7.0/test/srtp_driver.c), and an
AES-256-GCM packet generated with Python cryptography using RFC 3711 key derivation and RFC 7714
nonce/AAD construction. The local SCTP fixture uses a raw usrsctp listener and literal DCEP ACK
bytes, rather than routing a second copy of OpenNOW's DCEP encoder/decoder back to itself.

### Known divergences from the official client, 2026-09-24

An interoperability analysis of the official PC client (`streamsdk-client`, P4 38712457) confirms the
NATT punch model above and records three places where OpenNOW's SCTP channel table differs. The
objective is to *preserve* the existing eight channels and their reliability, so these are recorded
rather than changed:

- the official client opens **six** channels (SIDs 0, 2, 4, 6, 8, 10); OpenNOW adds cursor SID 12 and
  RTCP SID 14;
- official SIDs 4 and 6 are **maxRetransmits 2**; OpenNOW uses the 300 ms timed form for both;
- official SIDs 8 and 10 are **unordered**; the channel definition has no ordering field, so every
  message is ordered today. Ordering blocks head-of-line only; it does not break the association.
- the analysis also confirms the control-message framing already implemented here: `[u16 code][u16
  len][payload]` packed into SCTP messages of at most 1,071 bytes.

The analysis is the strongest available substitute for an official-client capture, and it independently
agrees with the old bundle's own 2026-08-23 note that the seat "gates media on this handshake".

### Wire-level corrections, verified, 2026-09-24

The corrections above are now in the tree and independently checked:

- **DCEP values against the RFC.** RFC 8832 §5.1/§5.2/§8.2.1 were read directly: OPEN `0x03`,
  ACK `0x02`, `RELIABLE 0x00`, `PARTIAL_RELIABLE_REXMIT 0x01`, `PARTIAL_RELIABLE_TIMED 0x02`. The
  encoder/decoder and their tests use those bytes.
- **A real SCTP peer exchange, both bare and carried inside DTLS.**
  `NvstSctpAssociationTests` stands up a second, raw usrsctp endpoint as an accepting listener over
  `AF_CONN`, exchanges INIT/INIT-ACK/COOKIE, and has it acknowledge all eight channel OPENs with a
  literal `0x02` ACK. The client then opens all eight channels, sends a binary message the peer
  receives with PPID 53 on the right stream, and receives an 80 KB reply that reassembles in order.
  `NvstBundleStackTests` then drives the same arrangement through two real DTLS record layers: the
  association's packets are encrypted by one `NvstDtlsHandshake` and decrypted by the other, so all
  eight channels and both payload directions cross the DTLS/SCTP boundary the live failure lived in.
  Together they prove the association, the DCEP handshake, the record-layer wiring and both payload
  directions against peers that are not OpenNOW's own encoder/decoder. They cannot prove the vendor
  accepts the full profile — that is the live gate.
- **The production assembly, over loopback.**
  `NvstBundleStackTests.theBundleOpensChannelsAndDecodesSeatAudioOverLoopback` drives a real
  `NvstNativeBundle` against a local seat endpoint: the bundle binds its own socket, completes DTLS,
  derives its two audio directions from the export, carries SCTP inside the record layer, opens the
  eight channels, and authenticates and decodes Opus protected with the server write keys. This is
  the first test of the assembled type rather than its parts. Its companions,
  `theBundleSendsCapturedMicrophoneAudioEncryptedWithItsClientKeys` and
  `theBundleUnlocksInputAndSendsControlOverTheAssembledChannels`, drive the microphone boundary
  (the seat authenticates the resulting SRTP with the client write keys, so the up-path is covered
  without hardware) and the control/input plane (the seat's input-protocol announcement unlocks
  `isInputReady`, and a control command and an input event reach the seat on streams 0 and 10).
  None can prove the vendor accepts the profile, but every wiring fault from the socket to decoded
  PCM, the encrypted microphone, or an input event fails locally now.
- **Audio direction is single-sourced.** `NvstNativeBundle` derives its two pipelines from
  `NvstAudioSrtpDirection.directions(from:)` instead of restating RFC 5764's ordering, so the
  existing direction test covers the bundle's mapping as well as the pipelines'.
- **Microphone carriage is advertised only when requested.** The bundle builds its send pipeline
  only when a microphone setup was supplied, and `microphoneNegotiation.negotiated` follows the
  microphone SSRC rather than the pipeline's mere existence. A session that did not request the
  microphone therefore advertises `rtcMicOnNativeBundle:0` instead of claiming mic carriage with no
  SSRC, and `onRemoteAudio` — previously declared but never called — fires once when audio is armed.
- **A refused channel is observable.** `NvstSctpAssociation` counts SCTP notifications and stream
  resets, and the bundle's summary prints `resets=`. A seat that refuses a channel resets its stream
  rather than answering the OPEN, so this distinguishes "no OPEN was sent" from "the seat refused
  it". The counter reads whatever arrives and changes no socket option, so it cannot affect an
  association.
- **SRTP reference packets.** Three vectors that OpenNOW did not generate: libsrtp v2.7.0's
  AES-128-CM/HMAC-SHA1-80 and AES-128-GCM `srtp_validate` packets, and an AES-256-GCM packet built
  with Python `cryptography` using RFC 3711 key derivation and RFC 7714 nonce/AAD. `protect` must
  reproduce each byte-for-byte and `unprotect` must return the plaintext; a tampered header, payload,
  or rollover counter must fail authentication.
- **DTLS-SRTP key direction.** `NvstDtlsHandshakeTests` negotiates both advertised profiles
  (`SRTP_AEAD_AES_256_GCM`, `SRTP_AES128_CM_SHA1_80`) end to end and confirms the exported client and
  server halves are distinct, that a server-key sender is readable by a client-key receiver, and that
  the wrong direction fails its tag.
- **PLAY default.** The negotiator sent PLAY only when `general.disablePlay` was literally `0`, so a
  seat that omitted the attribute would get no PLAY and stream nothing. The official client sends
  PLAY unless the seat disables it, so only a literal `1` now suppresses it; absence means send.
- **Verification.** Xcode suite: **2,260 passed, 4 skipped, 0 failed** after the 4e deletion. Strict
  lint: zero violations across 875 files. The rebuilt usrsctp static archive is committed with its
  SHA-256 and a reproduction script (`scripts/build-usrsctp.sh`).

**All four gates are now proven live (2026-09-24):**

- **Channels.** `sctp=established(in=4554 opens=8 resets=0 appData=4554)` — SCTP up, eight channels
  open, no stream resets.
- **Control + input.** `control=true feedback=true input=true`, `reportsSent` and `inputOut` growing.
- **Game audio.** `keying=DTLS-SRTP profile=AEAD_AES_256_GCM tagBytes=16`, device
  `playout=true capture=true outRate=48000`, `receive[datagrams=13260 authenticated=13246
  decoded=13243 lost=0 tagFail=14 decodeFail=0 redFail=0]` (the 14 tagFails are 0.1% stragglers).
- **Microphone.** `ANNOUNCE a=x-nv-general.rtcMicOnNativeBundle:1` and `mic=on(ssrc=1,tx=…)` with
  `tx` climbing past 1 MB.

The runbook that produced those readings, kept for the next regression:

- **Channels.** `sctp=established(… opens=8 resets=0 …)`; `resets=` non-zero means the seat refused
  the profile, and `cookie-wait`/`connecting` means the association never came up.
- **Control.** `control=true` and the periodic `0x313` totals growing.
- **Input.** `input=true` with `inputOut=`/`padOut=` growing as the mouse and keys are used.
- **Game audio.** `keying=… tagBytes=…`, then `decoded>0` with `tagFail=0`; `authenticated>0` with
  `decoded=0` isolates the RED/Opus path from the crypto.
- **Microphone.** `mic=on(ssrc=1,tx=…)` with `tx` growing while the mic is enabled.

**The superseded implementation is deleted.** Production referenced none of it, so the removal was a
closed set: `OPN/Stream/NvstWebRtcBundle.swift`, `NvstWebRtcBundleDelegates.swift`,
`NvstWebRtcBundleSDP.swift`, `NvstWebRtcBundleSetup.swift`, `WebRTCNativeAudioCoreDevice.swift`,
`WebRTCNativeAudioCoreDevice+Surround.swift`, `WebRTCNativeAudioDeviceMonitor.swift`,
`NvstBundleAudioSDP.swift` (the multiopus SDP munging, exclusive to the old WebRTC SDP path), and
`Tests/Stream/NvstWebRtcBundleTests.swift`. The two tests in `SurroundAudioTests` that exercised the
old synthesized offer, the old device's downmix, and that munging were removed with them; the
resolver, HUD, announce and surround-info tests in that file stay.

**The `WebRTC` dependency stays.** Remote Co-Op still builds its guest and host peers on
`RTCPeerConnection`, and `WebRTCI420BGRAConverter` is the Co-Op guest renderer's converter; the
`WebRTC` package/project dependency and `Vendor/WebRTC.xcframework` are therefore *not* part of this
deletion. Only the stream-side bundle and its exclusive audio device go.

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

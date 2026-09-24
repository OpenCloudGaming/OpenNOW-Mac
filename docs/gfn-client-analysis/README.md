# NVST client teardown — interoperability analysis of the official GeForce NOW client

Source: an interoperability analysis of the official PC client
(`streamsdk-client`, branch `gcomp/rel/gs_04_91`, P4 38712457), reconstructed from the Linux Flatpak
and Windows binaries (symbols, disassembly, `PE` imports), the web UI's recovered TypeScript, and two
complete runtime logs written by the client itself. No Alliance session was captured; Alliance
behaviour is derived from code and marked *Inferred*.

It is kept here because it is the strongest available substitute for an official-client capture, and
because several of its findings directly govern the native NVST bundle in `GFN/NVST/Native/`. The
findings that affect this repository are cross-referenced from
`docs/StreamTransportArchitecture.md`.

**Evidence tags:** `[log]` runtime log · `[bin]` binary/disassembly · `[js]` recovered web UI source.

---

## 00 · Overview

The desktop client is one process. `GeForceNOW(.exe)` hosts the Chromium web UI and loads two native
libraries in-process. **Geronimo** is the application layer: window, input, decoders, renderer and
frame pacing. **Bifrost2** contains the NVb CloudMatch SDK and a statically linked copy of NVIDIA's
NVST `streamsdk-client`, where the whole protocol lives.

```
GeForceNOW(.exe) — one process
  Web UI (mall/)            Angular · login · zones · serverInfo · settings
  CEF host                  server_type_helper (x − 1)
  Geronimo                  GridApp · IOInterface · SessionControl
                            VideoDecoderSet (DXVA · VDPAU · Vulkan · lavc)
                            SDLWindow · renderer · AsyncFrameQueue
  BifrostSDKExecutor
  Bifrost2                  NVb SDK (nvb*)
    client A: NIMBUS, profile 8      (SessionControl; CloudMatch HTTP only)
    client B: PASSTHRU (51)          (GridApp; streams)
    GridServer · Streamer
    NVST streamsdk-client
      SignalingHandler (RTSP/WSS) · SDP · NvscClientConfig
      Mjolnir RTP · FEC · NACK
      NattHolePunch (ping v6)
      WebRtcTransport (libre) — ICE · DTLS · dcSCTP · SRTP
      ServerControl (udp_ag) · QoS v7 · stats v9
    POCO 1.14 · OpenSSL 3.5
  CloudMatch                zone: POST /v2/session
                            control host: GET · DELETE
                            Authorization: GFNJWT …
  Game seat                 RTSP over WSS :322 → :48322
                            video UDP 5004 → 47998
                            bundle UDP 5004 → 47999
                            (same public port; the STUN
                             username selects the socket)
                            encoder: H.264 · HEVC · AV1
```

Infrastructure: HTTPS · WSS · UDP ×2.

### A real session, second by second

Session 2 in `geronimo.log`: zone `np-ams-06`, RTX 3080 client, 2560×1440 @ 165 Hz G-SYNC monitor,
1920×1080 @ 240 fps HEVC 4:4:4 10-bit.

NVST phase — ms after `nvbStartStreaming`. Preceded by 11.85 s of CloudMatch polling (queue position
0, ETA 12 s).

| ms | step |
|---|---|
| ~0 | TLS + WS upgrade + OPTIONS (8 ms) |
| 8 | DESCRIBE 141 ms — 4,116 + 63 attrs, control = `udp_ag` |
| 149 | SETUP video/0/0 19 ms → `X-GS-ServerPort=5004-5005` |
| 168 | ANNOUNCE 547 ms — 159 attrs incl. AES key + key ID (warn > 300 ms) |
| 715 | NATT v6 · DTLS 17 ms · SCTP ×6 |
| 732 | PLAY 113 ms |
| 845 | **1,205 ms — Frame [1] is an IDR** |

Session ended after 18 min: `nvbStopStreaming` → control-channel stop → WebSocket close → CloudMatch
DELETE (106 ms). No RTSP TEARDOWN, no keep-alive. Timestamps from `geronimo.log` L1678–L3507.
ANNOUNCE is the slowest step because the seat applies the client configuration before replying.

---

## 01 · Session & CloudMatch

Two Bifrost clients run side by side. **Client A** (`SessionControl`, server type 0 NIMBUS, profile
8; 3 s connect, 3 retries, 13 s data timeout) owns all CloudMatch HTTP. **Client B** (`GridApp`,
server type 51 PASSTHRU) streams. Client A briefly builds an NVST client only to compute request
metadata ("setup for seat configuration only"), then tears it down.

| Step | Request | Notes |
|---|---|---|
| Create | `POST https://<zone>:443/v2/session?keyboardLayout=en-US&languageCode=en_US` | `Authorization: GFNJWT <token>`; `sessionRequestData` with `secureRTSPSupported:true`, `transport:null`, seven metadata entries |
| Poll | `GET https://<sessionControlInfo.ip>:<port>/v2/session/<id>` | About every 1.02 s until `status == 2`. Always the control host from the response, re-targeted on "forwarded from zone". |
| Stream | `nvbStartStreaming(connectionInfo[])` | Endpoints converted by a fixed usage table (below) |
| Stop | `DELETE https://<control host>/v2/session/<id>` | After the control-channel stop. No PUT anywhere in a fresh launch. |

**Request metadata (all seven):** `SubSessionId` (new GUID), `wssignaling` `"1"`,
`latency@<zone host>` (measured ms), `networkType` (Ethernet / Wi-Fi), `ClientImeSupport` `0`,
`clientPhysicalResolution` (JSON w×h), `surroundAudioInfo` (channels).
OpenNOW sends only `SubSessionId` and `surroundAudioInfo`.

**Signalling endpoint selection:** usage 14 (SIGNALING) counts only with `appLevelProtocol` 1 or 6;
usage 16 (RTSPS) always counts; usage 15 (MEDIA) is dropped. Address = `ip` if non-empty, else
`resourcePath`. CloudMatch protocol 1 (TCP) → NVSC transport 6 → Secure WebSocket. Order is
preserved: `:322`, then `:48322`. At most 20 endpoints.

**Server-type chain:**

| UI / serverInfo | NVB type | NVSC serverNetwork | Effect |
|---|---|---|---|
| 1 | 0 NIMBUS | 2 | cloud: "No need to capture candidates for cloud server" |
| 2 | 1 GAMESTREAM | 1 | GameStream candidate path; legacy RTSP port 48010 fallback |
| 3 | 2 ROAMING_PROXY | 3 | public-STUN candidate capture (5 × 500 ms) |
| 4 / 5 | 3 CLOUD_STATION / 4 QUADRO_STATION | 2 | as cloud |
| 1001 | 51 PASSTHRU | 2 | streaming-only client (GridApp) |

Mapping recovered from `libBifrost2.so` 0x1f4b00 / 0x2004f9 and the CEF host's `server_type_helper`
table. *Confirmed*.

---

## 02 · Alliance servers

**The official client has no Alliance code path.** An exhaustive string and code search of Bifrost2
(Linux and Windows), NVST and Geronimo found no "alliance", "affiliate", partner-domain or
`nvidiagrid.net` checks. The only host-name test pins one extra CA when a host contains `nvidia.com`.
Alliance zones are entirely data-driven. From prepare onwards, a partner zone takes exactly the
NVIDIA code path. *Confirmed*.

A partner deployment works in the official client because it trusts whatever NES and CloudMatch hand
it. OpenNOW breaks at every point where it assumes NVIDIA-operated infrastructure.

| Pin | Official client | OpenNOW today |
|---|---|---|
| A1 | Chooses the provider by `idpId`. `isAffiliate` only affects UI and telemetry. | `trusted_cloudmatch_base` drops any provider outside `*.nvidiagrid.net` without warning. |
| A2 | Formats any host into `https://%s:%d/v2/session`. | `is_zone_hostname` decides whether to follow the control host. |
| A3 | Polls the control host CloudMatch names, wherever it is. | The streamer rejects non-`nvidiagrid.net` signalling hosts. |
| A4 | Tries every signalling endpoint and accepts the certificate (`validateCertificates` → 2). | Only the first endpoint is tried, with strict rustls host verification. |
| A5 | Supports three server networks and the legacy transport layout. | Seats without `nativeRtcOnBundlePort=1` are refused. No `serverNetwork` modes. |

**Checklist for a client that works on Alliance zones:**

1. Discover the provider from NES `serviceUrls` by `idpId`; fall back to `defaultProvider`.
2. Do not filter `streamingServiceUrl`, zone hosts or control hosts by domain. Require HTTPS on 443
   and a valid certificate.
3. Build zones strictly from the provider's `gfn-regions`, and fetch each zone's `serverInfo`
   (`serverType − 1`).
4. POST the full `sessionRequestData` with all seven metadata entries. Never send a follow-up PUT.
5. Poll `sessionControlInfo` about once a second until `status == 2`, and re-target whenever it moves.
6. Convert `connectionInfo` exactly like Bifrost, and try each signalling endpoint in order.
7. Pick the carrier from `appLevelProtocol` (5/6 → WSS, 1 → raw RTSP). Split DESCRIBE, then honour
   `serverNetwork` and the transport flags.
8. Collect one official `geronimo.log` from an Alliance region to settle the open questions below.

**Open until a partner capture exists:** partner host names (inside or outside `nvidiagrid.net`?),
partner `serverType` and `authType`, whether `connectionInfo` carries a raw-IP `ip` or a dash-host
`resourcePath`, the partner certificate names, and whether SETUP returns a server transport.

---

## 03 · Signalling & SDP

RTSP is carried as text frames inside a Secure WebSocket (`wss://host:port/rtsp`). The URL still says
`rtsps://`. The log shows the client overriding it: *"requested scheme 'RTSPS' does not match the
expected scheme 'WSS'"*. The upgrade and every request carry `x-nv-sessionid`, and responses are
matched by `Request-Id = CSeq`. There are no retries over WSS. Timeouts are 6 s to connect and 20 s
to send or receive.

```
Client (NVST)                                   Game seat
TLS 1-way · GET /rtsp Upgrade: websocket · x-nv-sessionid
OPTIONS X-GS-Version: 14.2 (14 = protocol, 2 = RTP ext. header)
   → 200 · Public: OPTIONS,DESCRIBE,ANNOUNCE,SETUP,TEARDOWN,PLAY,PAUSE,X_NV_COMMAND,X_NV_EVENT
DESCRIBE Accept: application/sdp x-nv-abtesting: 2
   → 200 · Session: XNV… · main SDP ;; features SDP || upstream offer
SETUP streamid=video/0/0 Transport: (empty)
   → 200 · unicast;X-GS-ServerPort=5004-5005;source=… · x-nv-ping: 6 · X-Nv-Ping-Payload
ANNOUNCE 159 x-nv-* attrs · runtime.encryptionKey / encryptionKeyId
   → 200 (547 ms)
UDP: NATT ping v6 on 49005 and 49006 → 5004 · ICE · DTLS (17 ms)
dcSCTP opens SIDs 0, 2, 4, 6, 8, 10 · control protocol udp_ag · audio/mic SRTP on the bundle
PLAY Session: XNV…
   → 200 (113 ms) → app messages allowed; first IDR ~100 ms later
… 18 minutes: no RTSP traffic at all (no GET_PARAMETER, no keep-alive) …
control-channel stop → WebSocket close (no TEARDOWN)
```

**The DESCRIBE body has three parts:** *main SDP* (4,116 `NvscClientConfig` attributes · `m=` blocks ·
`a=control`) `;;` *features SDP* (63 attributes + HMAC seed · applied after main · bundle switches,
`grc.enable`) `||` *upstream offer* (video offer). Attribute syntax is
`a=x-nv-<group>.<field>:<value>`, e.g. `x-nv-video[0].maxFPS` and
`x-nv-general.serverBundlePort`. **The features part overrides the main part**; a parser that takes the
first match anywhere in the body reads stale values.

**Carrier by `appLevelProtocol`:** 5 (HTTPS) / 6 (RTSPS + TCP) → WSS `/rtsp`; usage 7 (RTSP + TCP) →
plain WS; 1 (RTSP) → raw RTSP over TCP/TLS (`CSeq`; 3000 ms doubling retry); protocol 0/2 → config
default.

**Control protocol fallback chain:** `udp_ag_enc → udp_enc → udp_ag → udp → tcp_enc → tcp`.
Picked in the log: **`udp_ag`** (not encrypted at the application level). It rides dcSCTP inside
DTLS, with control id `streamid=control/10`.

**ANNOUNCE values where OpenNOW contradicts the official session:**

| Attribute | OpenNOW | Official |
|---|---|---|
| `video[0].maxCodecLevel` | 61 | 51 |
| `videoSplitEncodeStripsPerFrame` | 64 | 63 (server-owned) |
| `framePacing.mode` / `feedbackMode` | 1 / 1 | 2 / 0 |
| `fec.repairMinPercent` / `repairMaxPercent` | 20 / 35 | 5 / 40 |
| `bllFec.enable` | 0 | 1 |
| `vqos[0].grc.enable` | 7 | server value |
| `packetPacing.maxDelayUs` | 4000 | 1000 |
| `packetPacing.minNumPacketsPerGroup` | 15 | 0 |
| `x-nv-clientSupportHevc` | sent | does not exist |

**Key delivery:** the client generates the media key — 32 random bytes (AES-256) plus a random
non-zero u32 key ID. It installs the key for control, audio and video, then sends it in ANNOUNCE
(`x-nv-runtime.encryptionKey`, `encryptionKeyId`), protected only by the signalling TLS. *Confirmed*.

---

## 04 · Transport

The client uses two exclusive UDP sockets (IPv4, falling back to a random port when the reserved one
is busy), and **both talk to one public server port**. The seat's front end tells the two flows apart
**only by the STUN username in the NATT ping**. An incorrect username can send a client socket to the
wrong internal socket, or to none. *Inferred demux model, consistent with OpenNOW's earlier bundle
bug.*

```
Client                                Seat (internal)                    Seat front end
video  · UDP 49005  ─┬─ Mjolnir RTP (AES-GCM, FEC, NACK) ── video 47998
                     └─ NATT ping v6 · 1 per tick                 USER <srvUfrag>47998:<local>
bundle · UDP 49006  ─┬─ ICE · DTLS · dcSCTP ×6 ────────────── bundle 47999
                     ├─ SRTP audio + mic · control                USER <srvUfrag>47999:<local>
                     └─ NATT ping v6 · 3 per tick            ── UDP 5004 (X-GS-ServerPort 5004-5005)
```

Pings: 20 ms before connection, 100 ms after, for the whole session; **the seat never pings back**.
Video pings start after DTLS/SCTP, ~3 ms before PLAY.

**NATT ping v6 is an authenticated STUN Binding Request**, signed with the server's ICE password and
carrying a `FINGERPRINT`. **The literal `PING` string is never sent with v6.** OpenNOW uses
`PING:<local>` on the bundle and derives the server ufrag by incrementing a hex string.

**SCTP data channels (exactly six):**

| SID | Label | Ordered | Reliability |
|---|---|---|---|
| 0 | `control_channel_reliable` | yes | reliable |
| 2 | `custom_message_on_sctp_private_reliable` | yes | reliable |
| 4 | `custom_message_on_sctp_private_partially_reliable` | yes | maxRetransmits 2 |
| 6 | `control_channel_partially_reliable` | yes | maxRetransmits 2 |
| 8 | `control_channel_unreliable` | no | maxRetransmits 1 |
| 10 | `input_channel_partially_reliable` | no | lifetime 300 ms |

> **OpenNOW divergences:** opens **eight** channels (adding cursor SID 12 and RTCP SID 14); makes SIDs
> 4/6 unordered; uses the 300 ms timed form on 4/6; SID 8 maxRetransmits 0; no ordering field.

Control messages are `[u16 code][u16 len][payload]` records, packed into SCTP messages of at most
**1,071 bytes** and flushed about every **50 ms**. OpenNOW sends one SCTP message per record.

**Server networks: three transport modes.** `serverNetwork 2` (cloud): no candidate capture, one host
candidate plus the SETUP peer — the only mode OpenNOW implements. `serverNetwork 3`: the client
captures its public address by STUN (5 attempts × 500 ms) before ICE. **No server transport in
SETUP**: DTLS goes straight to the RTSPS host on the bundle port, with ICE disabled. *Inferred — a
strong Alliance candidate.*

---

## 05 · Video decode

**Codec and mode rules.** Auto picks HEVC for ≥ 240 fps or HDR, and H.264 otherwise. H.264 is capped
at 120 fps, 8-bit, 4:2:0. AV1 is never used on Linux or SteamOS, above 120 fps, or above 5120×2880
(remote config). Codec level 5.1; levels 6.1/6.2 need a remote-config opt-in. Decoder capability is
probed per codec, HDR and chroma.

**Backends.** Windows: DXVA on a dedicated D3D11 video device, 25 decode surfaces (1080p HEVC).
Linux: VDPAU, Vulkan Video, or libavcodec in software. The real decoder is created lazily from the
first parsed SPS (coded 1920×1088 → display 1920×1080). SPS/PPS arrive in DESCRIBE. The first frame
is an IDR.

**Decode queue and recovery.**

| | Official | OpenNOW |
|---|---|---|
| Queue | 40 decode units for the first 80 frames after an IDR, then a configured size (240/360 fps queues ~30/45). Overflow first drops only frames older than the latest IDR. Decoder state reported per frame (1/2/4/6); "unrecoverable bitstream" only after repeated consecutive failures. | A 2-unit queue (`media.rs:25`). A full queue or any gap invalidates everything and waits for a keyframe. Every decode failure requests a keyframe, which becomes an IDR storm on lossy links. |

---

## 06 · Colour & HDR

Negotiation only tells the encoder what to produce. For rendering, the client trusts the bitstream's
**VUI** (primaries, transfer, range) and its bit depth.

| Stream kind | CloudMatch request | NVST config | Decoder out (Win) | Swapchain | DXGI colour space |
|---|---|---|---|---|---|
| SDR 8-bit 4:2:0 | `bitDepth:0 chromaFormat:0 sdrHdrMode:0 trueHdr:false` | bitDepth 8, chromaFormat 0, dynamicRangeMode 0, csc 2/4 | NV12 | R8G8B8A8 (0x1c) | `RGB_FULL_G22_NONE_P709` |
| SDR 10-bit 4:4:4 | `bitDepth:1 chromaFormat:1` | bitDepth 10, chromaFormat 1, csc 2/4 | Y410 | R10G10B10A2 (0x18) | `RGB_FULL_G22_NONE_P709` |
| HDR10 code | `sdrHdrMode:1, displayData{…}` | dynamicRangeMode 1, bitDepth 10, hdrCsc 4 | P010 / Y410 | R10G10B10A2 (0x18) | `RGB_FULL_G2084_NONE_P2020` |

**NVST colour-space enum:** 0 BT.601 limited · 1 BT.601 full · 2 BT.709 limited (SDR CSC) · 3 BT.709
full · 4 BT.2020 limited (HDR CSC) · 5 BT.2020 full · 6 sRGB limited · 7 sRGB full.
`dynamicRangeMode`: 0 SDR · 1 HDR10 · 2 valid but unused. `Monitor ColorSpace:7` in the log means an
SDR desktop; 9 would mean Windows HDR.

**Three corrections for OpenNOW:**

1. **`trueHdr` is not HDR.** It requests the server's AI SDR→HDR filter. It was false in every
   official request; OpenNOW sets it whenever HDR is on.
2. **`chromaFormat` is 0/1 in the NVST config** (verified in both logs). OpenNOW sends 1/3. Capture an
   official ANNOUNCE before changing it.
3. **`displayData` is null in SDR**, and in HDR carries the real monitor primaries ×50000 and
   luminance. OpenNOW always sends zeros and 1000/400 nits.

**HDR is a state, not a session constant.** An HDR-negotiated session starts at `hdrMode = 0` until
the game switches, and the official swapchain's `pq` flag follows the stream. OpenNOW treats SDR
frames in an HDR session as a hard error (`decoder.rs:1125-1129`). The official client uses no FP16
output and no `SetHDRMetaData`; 10-bit SDR gets a real 10-bit swapchain even with Windows HDR off.

---

## 07 · Frame pacing, VRR & G-SYNC

`AsyncFrameQueue::push` chooses the presentation mode for every frame, running these checks in order.
`updateQueueMode` only reports a mode after it has held for 300 frames (telemetry values 1 Fixed ·
2 Timestamp · 3 Legacy · 4 VRR/Adaptive · 5 Cinematic).

1. Benchmark mode enabled → **Legacy**
2. Vsync off (the logged session) → **Legacy**
3. Non-blocking fast stream: 1.5 × server interval < display interval and the window requested it → **Legacy**
4. Frame paced by the server's frame-rate limiter (`framePacing.mode 2`) → **Fixed**
5. VRR enabled — keep the newest frame, plus one when hardware flip-queue pacing is on and the stream is slower than refresh → **VRR**
6. Cinematic pacing enabled (high-water frame count / max queue time) → **Cinematic**
7. Adaptive queue: 0–2 extra frames, re-evaluated every 180 frames. Depth rises above 24/40 ms jitter and falls below 16/32 ms, after 4 agreeing windows → **Adaptive**
8. Timestamps disabled, or frame-rate mismatch (server interval outside 0.75–1.5 × display interval) → **Legacy**
9. Otherwise: present at arrival + jitter advance, 8–32 ms queue time → **Timestamp**

At most 7 frames are alive (`FRAME_RENDER_MAX_COUNT`). Every dropped frame is reported to the server
as frame state 8. The session dropped 43 frames in about 18 minutes, at an average of about 148 fps
delivered.

**Present path (Windows):** `FLIP_SEQUENTIAL`, 2 buffers, `SetMaximumFrameLatency(1)`, frame-latency
waitable object. With vsync off: `Present(0, DXGI_PRESENT_ALLOW_TEARING)`. Swapchain is 10-bit (0x18)
for any 10-bit stream. **Linux:** FIFO → MAILBOX → FIFO_RELAXED with vsync on, IMMEDIATE first with
vsync off. No `present_wait`.

**VRR / G-SYNC detection.** Windows: NVAPI monitor caps, the driver "Enable G-SYNC" setting,
`NvAPI_D3D_SetVRRState`, and the OS refresh range. `vrrDisplayWar` forces a 10 Hz minimum when a
G-SYNC display reports no range — this is the "Force to VRR" log line. Requires driver ≥ 546.24 and a
Turing+ GPU; hardware pacing also needs Windows 11 22H2. Linux: every VRR check returns false.

| Signal | Carrier | Values (session 2) | OpenNOW |
|---|---|---|---|
| `VSYNC_INTERVAL` | `nvbFeatureControl` type 12 (µs) | 0 — only non-zero with vsync on + Adaptive pacing | never sent |
| `VrrCapable` · `HwFramePacing` | client-info key/values (0 no, 1 capable, 2 enabled) | 1 · 0 | never sent |
| `FramePacingMode` | client info | `frl` (server frame-rate limiter) | never sent |
| Window / system state | 0x0320 / 0x0321 | 16 / 17 / 19 on focus and overlays | 19 once at input start |
| `cloudGsync` | CloudMatch request + `video[0].cloudGsync` | false (user profile); allowed at ≥ 60 fps | from the setting alone, no detection |
| Reflex | request feature | on; without VRR needs ≥ 120 fps | — |

---

## 08 · QoS & loss handling

Versions negotiated from the SDP: QoS feedback v7, client timings v5, blob stats v9. The `0x0207`
report is 52 bytes, sent every 50 ms.

| Offset | Size | Field |
|---|---|---|
| +0 | u32 | feedback version = 7 |
| +4 | u8 | stream idx |
| +5..7 | | padding |
| +8 | u32 | feedback sequence, +1 per send |
| +12 | u32 | last sender frame number — *OpenNOW writes a local count* |
| +16 | u32 | receiver counter (*Inferred*) |
| +20 | u32 | time quantity ×1000 (OWD/jitter? *Inferred*) |
| +24 | u16 | per-frame value |
| +26 | u16 | loss per 10,000 — *OpenNOW: always 0* |
| +28 | u8 | per-frame value |
| +30 | u16 | max decode fps (1000 = unknown) |
| +32 | u16 | max render fps |
| +34 | u16 | zero — *OpenNOW: 12708* |
| +36 | u32 | client clock, 90 kHz ticks — *OpenNOW: RTP timestamp* |
| +40 | u32 | receiver statistic |
| +44 | u32 | per-frame value |
| +48 | u32 | receiver counter |

Recovered from the builder in `libBifrost2.so`. Red fields differ in OpenNOW (`nvst_control.rs:109-146`).
Without a loss report the server's bandwidth estimator cannot step down.

**The loss ladder.**

| | Official | OpenNOW |
|---|---|---|
| 1 | FEC — Reed-Solomon, 5–40 % repair | 52 ms gap (always NACK) |
| 2 | NACK `0x0317` — only once an RTT estimate exists | no reference invalidation — straight to keyframe |
| 3 | Ref. invalidation `0x0301` — u64 first · u64 last · u64 stream + freeze | IDR `0x0302` + RTCP PLI |
| 4 | IDR `0x0302` — last resort | |

A healthy official session sent no IDR request, no PLI and no RTCP: 5 NACKs recovered 27 packets and
FEC recovered 2. OpenNOW also requests an IDR at startup, before the channels open.

---

## 09 · OpenNOW gap tracker

P0 blocks a connection · P1 breaks quality or stability · P2 parity. The file references are OpenNOW
at `d66726a1`.

41 of 41 gaps. Alliance-relevant subset:

| ID | Priority | Gap | Where |
|---|---|---|---|
| A1 | P0 Alliance | A `*.nvidiagrid.net` allow-list silently drops partner providers, regions and session hosts. | `opennow-core/src/cloudmatch.rs:1896-1915` |
| A2 | P0 Alliance | Polls the zone host unless the control host matches `*.cloudmatch(beta).nvidiagrid.net`. | `cloudmatch.rs:2565-2571` |
| A3 | P0 Alliance | Streamer rejects signalling hosts outside `*.nvidiagrid.net`. | `nvst_rtsp.rs:1530-1551` |
| A4 | P0 Alliance | Only the first signalling endpoint is tried (no 322 → 48322). | `nvst_rtsp.rs:745-759` |
| A5 | P0 Alliance | Strict TLS host verification; the official client delegates the verdict and accepts. Needs evidence and a narrowly scoped fix. | `nvst_rtsp.rs:336-354` |
| A6 | P0 Alliance | Always WSS; no raw RTSP(S) carrier for `appLevelProtocol 1`. | `nvst_rtsp.rs:1502-1528` |
| A7 | P0 Alliance | Refuses seats without `nativeRtcOnBundlePort=1`; no legacy SETUP or control-protocol chain. | `nvst_rtsp.rs:841-847` |
| A8 | P0 Alliance | Ignores `general.serverNetwork`; no STUN-candidate or direct-DTLS (ICE off) mode. | transport (inventory §3) |
| A9 | P0 | Bundle NATT username `PING:<local>`; remote ufrag derived by hex increment. | `nvst.rs:5917`, `nvst_rtsp.rs:1719-1757` |
| A10 | P0 | DESCRIBE `main ;; features || offer` is not split; the first match wins. | `nvst_rtsp.rs:1641-1657` |
| A11 | P0 | PLAY is skipped when `disablePlay` is absent (the official default is to send it). | `nvst_rtsp.rs:840` |
| A12 | P0 | Unsolicited PUT RESUME right after every POST. | `cloudmatch.rs:313-341` |
| A13 | P0 | Request metadata lacks `wssignaling`, `latency@`, `networkType`, `ClientImeSupport`, `clientPhysicalResolution`. | `cloudmatch.rs:1385-1391` |
| A14 | P0 | Endpoint table differs from Bifrost's (`resourcePath` before `ip`, the browser `/nvst/` fallback, `port:0` fails the whole session). | `cloudmatch.rs:1514-1535` |
| A15 | P0 Alliance | Region discovery only for `prod.cloudmatchbeta.nvidiagrid.net`; zones not taken from `gfn-regions`. | `cloudmatch.rs:1170-1173` |
| A16 | P0 | Waits for `resourcePath` instead of `status == 2`. | `cloudmatch.rs` |
| S1 | P1 | Hand-written ANNOUNCE echoes server-owned fields with contradicting values. | `nvst_rtsp.rs:1093-1251` |
| S2 | P1 | GET_PARAMETER every 2 s, and TEARDOWN on close. | `nvst_rtsp.rs:665-672` |
| S3 | P1 | App messages can go out before the PLAY response. | `nvst_input.rs:1138-1149` |
| S4 | P1 | IDR/PLI requested at startup. | `nvst.rs:5921-5923` |
| S5 | P1 | No reference invalidation (`0x0301`); a 52 ms gap goes straight to IDR + PLI; NACK always on. | `nvst.rs:3002-3018` |
| S6 | P1 | 2-unit decode queue with full-flush semantics. | `platform/src/media.rs:25` |
| S7 | P1 | Keyframe on every decode failure; no consecutive-failure threshold. | `media.rs:2515-2591` |
| S8 | P1 | `0x0207`: loss never reported; wrong fields at +12/+34/+36; 55.6 ms cadence; not batched. | `nvst_control.rs:109-146` |
| S9 | P1 | Sends `0x0203` and advertises `feedbackMode:1`. | `nvst_rtsp.rs:1128-1129` |
| S10 | P1 | Eight SCTP channels; SIDs 4/6 unordered with 300 ms lifetime. | `nvst_input.rs:69-121` |
| S11 | P1 | Video identity pinged to every port in `X-GS-ServerPort`. | `nvst.rs:6979-6994` |
| S12 | P1 | One recovery attempt; no `0x0312` in-session recovery mode. | `streamer-core/src/lib.rs:89` |
| V1 | P1 | `trueHdr = hdr` requests the AI SDR→HDR filter. | `cloudmatch.rs:1414` |
| V2 | P1 | `displayData` always sent, with zero primaries. | `cloudmatch.rs:1336-1350` |
| V3 | P1 | `chromaFormat` 1/3 vs official 0/1. Verify with an ANNOUNCE capture. | `nvst_rtsp_color.rs:21-24` |
| V4 | P1 | Linux infers BT.601 from height ≤ 576. | `platform-linux/src/format.rs:95-99` |
| V5 | P1 | SDR frames in an HDR session are a hard error. | `windows/decoder.rs:1125-1129` |
| V6 | P2 | 10-bit SDR shown on an 8-bit swapchain with dithering. | `StreamVideoTextureRenderer.h:35-37` |
| V7 | P2 | FP16 scRGB HDR output instead of the official R10G10B10A2 PQ path. | `HdrSwapChainRecovery.h:9-10` |
| V8 | P1 | `maxCodecLevel` 61; auto codec may choose AV1 above 120 fps. | `nvst_rtsp.rs:1118` |
| R1 | P1 | Never sends `VSYNC_INTERVAL`, `VrrCapable`, `HwFramePacing`, `FramePacingMode`; window state sent only once. | `nvst_input.rs:1138-1149` |
| R2 | P1 | Cloud G-SYNC requested from the setting alone, with no VRR detection. | `cloudmatch.rs:2480` |
| R3 | P1 | No queue modes; Qt default vsync; alpha buffer likely forces composition (no tearing or VRR). | `ApplicationStartup.cpp:78` |
| R4 | P2 | Presentation drops and present timing are not reported. | `nvst_control.rs:70-89` |
| R5 | P2 | Linux pacer fast-stream threshold uses the mismatch bound (0.75×) instead of 1.5×. | Linux pacer |

**Suggested order of work:**

1. Get one official `geronimo.log` from an Alliance region (redact IDs and tokens).
2. Remove the domain allow-lists, follow `sessionControlInfo`, and generalise discovery (A1–A3, A15).
3. Try all signalling endpoints, mirror Bifrost's endpoint table, and wait for `status 2` (A4, A14, A16).
4. Split DESCRIBE, send PLAY by default, drop the PUT, and send the full metadata (A10–A13).
5. Fix the bundle NATT identity (A9).
6. Add the raw RTSP(S) carrier, the legacy transport layout, and the `serverNetwork` modes (A6–A8).
7. Build ANNOUNCE from config, add the loss ladder, fix the QoS v7 fields, size the decode queue, add
   the recovery mode (S1–S12).
8. Fix the colour request fields (V1–V8), then add VRR and vsync signalling and pacing (R1–R5).

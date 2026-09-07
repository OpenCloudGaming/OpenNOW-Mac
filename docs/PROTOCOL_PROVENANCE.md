# Protocol Provenance and Interoperability Statement

This document records how the vendor-protocol code in `GFN/` and `OPN/Stream/` was produced, what
it does and does not incorporate, and the licensing position of the OpenNOW project. It exists so
that a contributor, auditor, or downstream redistributor can answer one question precisely: *where
did the GeForce NOW protocol knowledge in this codebase come from, and whose code is in here?*

## Scope

This statement covers:

- `GFN/CloudMatch` — session/service-discovery and subscription endpoints
- `GFN/GDN` — game discovery / library graph
- `GFN/NesAuth` — account authentication
- `GFN/Jarvis` — OAuth authorization flow
- `GFN/LCARS` — the catalog GraphQL surface (`games.geforce.com/graphql`)
- `GFN/Starfleet` — session allocation
- `GFN/UDS` — user diagnostic / end-of-session reporting
- `GFN/NetworkTest` — network preflight
- `GFN/NVST` — the native streaming path (`BifrostFree`, `Rtsp`, `Signaling`, `SDP`,
  `Geronimo` input wire types, the `Mjolnir` video receiver)
- `OPN/Stream` — the WebRTC and native NVST transports, VideoToolbox decode, upscaling, and
  controller input that consume the above

## What this repository contains

These facts are verifiable from the source tree itself.

1. **The implementation is original Swift.** There are no Objective-C++, C, or C++ source files in
   this repository outside the vendored `WebRTC.framework` distribution. `GFN/` and `OPN/Stream/`
   are Swift from top to bottom.

2. **No vendor libraries are bundled or linked.** The application links only `WebRTC.framework`
   (Google's WebRTC, BSD 3-Clause) and the system `AppIntents.framework`; Sentry and Ably arrive
   via Swift Package Manager. There is no NVIDIA `.framework`, `.dylib`, static archive, or binary
   `bundle` in the repository or the application bundle.

3. **The native transport loads no vendor library.** OpenNOW's native NVST path — RTSP control
   plane, raw-SRTP video receiver, and VideoToolbox decode — is OpenNOW's own Swift implementation
   and links or loads no NVIDIA library of any kind. Its transport factory documents that it runs
   with no NVIDIA libraries, on OpenNOW's own RTSP control plane and raw-SRTP Mjolnir receiver.

4. **Third-party code that *is* incorporated is separately licensed and attributed.** WebRTC
   (BSD 3-Clause), the Hanken Grotesk font (SIL OFL 1.1), ably-js / ably-cocoa / delta-codec-cocoa
   / msgpack-objective-C (Apache-2.0), and sentry-cocoa (MIT) are all listed with full license
   texts in `Resources/Licenses/THIRD_PARTY_NOTICES.md`, which ships inside the application bundle.

5. **Game artwork and storefront imagery are fetched at runtime, not bundled.** Cover art, hero
   images, and login-wall tiles are requested from the vendor's content delivery network while the
   app runs; they are not redistributed in this repository or the app bundle. Generic placeholder
   tiles and original SVG glyphs in `Resources/` are the only visual assets that ship.

## Method of derivation

Out of respect for the distinction that matters, "clean room" is used here in its precise sense: a
process in which one group studies behavior while a second group, isolated from any non-public
implementation detail, writes original code against a written specification. OpenNOW is not a
two-team clean-room project. What it is — and what this statement commits to — is a **black-box
interoperability reimplementation**:

- Protocol knowledge was obtained by observing the vendor's *publicly reachable service* through a
  real GeForce NOW account — the HTTP requests and responses, the GraphQL exchanges, the RTSP/SDP
  negotiation, and the RTP/SRTP media stream the service itself produces — together with the
  service's publicly observable string tables.
- The endpoint names, GraphQL operation shapes, SDP attribute names, codec and SSRC conventions,
  and field layouts in `GFN/` are the vendor's own *interoperability identifiers* as they appear
  at the network boundary. They are retained in this codebase solely so that OpenNOW can speak the
  protocol at the other end of the wire, in the same way other clients retain a server's field
  names to interoperate with it.
- Names such as `CloudMatch`, `GDN`, `NesAuth`, `Jarvis`, `LCARS`, `Starfleet`, `UDS`, `NVST`,
  `Bifrost`, `Geronimo`, and `Mjolnir` are the vendor's service identifiers, used here as
  descriptive identifiers for data that flows over the public protocol. They are not copied
  subsystem implementations.

**What was not used.** No NVIDIA source code, object code, debug symbols, SDKs, or confidential
documentation were copied into, linked into, decompiled into, or otherwise incorporated in this
repository. The distributed application contains no vendor runtime of any kind.

## Trademarks and naming

NVIDIA, GeForce NOW, Valve, Steam, Steam Controller, Xbox, Ubisoft, Epic Games, Battle.net,
Blizzard, Gaijin, and Twitch are trademarks of their respective owners. OpenNOW is an independent
community project, not affiliated with, endorsed by, or sponsored by any of them. Trademarks are
used for identification and interoperability only, as described in the Trademarks section of
`Resources/Licenses/THIRD_PARTY_NOTICES.md`.

## Limitations of this statement

This document describes the repository's contents and the project's methodology; it is not legal
advice and does not by itself grant any rights. It also does not address the separate question of
whether using OpenNOW is permitted by the GeForce NOW Terms of Use — that is a contract between
each user and NVIDIA, and using OpenNOW requires the user's own GeForce NOW account. Nothing here
should be read as an endorsement of, or a claim to have received permission for, interoperating
with the service beyond what ordinary authorized use of one's own account entails.

## Maintenance

If the provenance of any file under `GFN/` or `OPN/Stream/` changes — for example, a contribution
derived from a differently-licensed reference is merged — this statement and
`Resources/Licenses/THIRD_PARTY_NOTICES.md` must be updated in the same change. Contributions that
introduce foreign source code must carry that code's license and attribution.

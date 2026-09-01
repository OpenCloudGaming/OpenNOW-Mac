# Hosted signaling — plan

Status: implemented (steps 1-5), proven end to end against a real Ably account (see below).

## The problem this solves

The tunnel exists for one reason: this branch moved signaling onto the host. A guest has to reach
the host's embedded HTTPS server to negotiate, so the host needs inbound reachability, so it needs a
tunnel — and with the tunnel comes a random hostname per launch, a self-signed certificate on the
LAN path, and total failure when the *host* is behind CGNAT or on a cafe network.

A relay does not fix this. TURN carries media *after* negotiation; you cannot open an allocation
toward a peer you have not negotiated with. The tunnel is a signaling problem wearing a networking
costume.

Put signaling on something public and it all goes away, because the host connects **outbound** to it
exactly as it already does to TURN:

| | Today | With hosted signaling |
| --- | --- | --- |
| Guest page | Host's embedded server | Static public host |
| Signaling | Host's embedded server (needs tunnel) | Hosted service, host dials out |
| Media | Direct, or TURN relay | Unchanged |
| Host inbound reachability | Required | **None** |
| Host behind CGNAT / in a cafe | Broken | Works |
| Certificate | Self-signed, or the tunnel's | Provider's, always valid |
| Join URL | New per launch | Stable |

## This is a fallback, not a default

Hosted signaling is one more option, never the preferred path. If a guest can reach the host
directly there is no reason to involve a third party, and no reason to spend messages doing it.

The distinction worth holding: **media** fallback is automatic — ICE prefers a direct candidate pair
and only relays when nothing else works, which is why `relayAugmented` appends rather than
substitutes. **Signaling** has no equivalent negotiation; it always goes somewhere. So "fallback"
here means the host runs *both* transports at once and the guest uses whichever it can reach:

- LAN or tailnet guest — reaches the embedded server, no third party, no messages billed.
- Remote guest — uses the hosted channel.

`OPNRemoteCoOpCompositeSignalingSession` already fans commands to several children and merges their
events, so this is the shape the code is built for rather than a new concept.

**But that is exactly the case the review found broken.** The composite has no notion of which
transport owns a participant, so the two children's "already claimed by a live socket" guards cannot
see each other — a guest appearing on both is currently mishandled. Running embedded and hosted
concurrently walks into that defect, which is the second reason the security gate has to be
extracted before this transport exists, not after.

## What does not change

- **The relay.** Media still needs TURN when a guest's network blocks a direct connection. All four
  existing providers stay exactly as they are. Hosted signaling and the relay solve different halves.
- **The embedded server stays the default.** A LAN or tailnet session must keep working with no
  account and no third party. This is an added transport, not a replacement.
- **Media privacy.** DTLS-SRTP is end to end. The service sees SDP and ICE metadata, never frames.
- **`OPNRemoteCoOpWireMessage`.** The wire vocabulary is already JSON and stays as it is.

## Provider: Ably

| | Free | Beyond free | Swift SDK |
| --- | --- | --- | --- |
| **Ably** | 6M messages/mo, 200 connections | **$2.50/million, linear** | `ably-cocoa` |
| Supabase Realtime | 200 connections | $25/mo step | `supabase-swift` |
| Pusher | 200k msgs/day, 100 conns | $49/mo cliff | yes |
| PubNub | 200 MAU | $49/mo cliff | yes |

Ably is the only one with free quota *and* genuine pay-as-you-go — the others jump to a monthly
plan, which is not what was asked for.

The free tier is effectively unbounded here. A guest join costs an invite, a join, one SDP exchange,
a dozen or so ICE candidates and some participant updates — a few hundred messages for an entire
session. 6M/month is thousands of sessions. Reaching $2.50 of usage would take deliberate effort.

**Presence is a bonus worth calling out.** Ably channels have presence, which replaces the heartbeat
and the idle sweep outright — and those are where three of the bugs found in review lived (the
heartbeat echo loop, the native listener's missing sweep, the wall-clock idle timeout). Deleting that
machinery is a real simplification, not just a migration.

## Credential model

Verified against Ably's documentation before designing around it, and the first design did not
survive.

**Ably JWT, signed locally.** The host holds the API key, mints a JWT scoped to this invite's channel
and expiring with the invite, and the guest connects with the JWT alone.

```
host keychain:  Ably API key                       (never leaves the machine)
host mints:     JWT, HS256 over the key secret     (local — no network)
  kid                 = key name
  x-ably-capability   = {"<invite channel>": ["subscribe","publish","presence"]}
  exp                 = invite expiry
invite link:    carries the JWT
guest:          connects with the JWT only
```

Two properties make this work where the obvious approach does not: it is **multi-use**, so all three
guests of one invite can present it, and its lifetime is **ours to choose**, so it can match the
invite rather than dictate it.

Signing is `HMAC-SHA256` plus base64url — CryptoKit, no new dependency, and the same shape as the
coturn shared-secret provider already shipped. `ably-cocoa` is then needed only for the realtime
connection, not for minting.

### Rejected: signed TokenRequest

The natural-looking approach, and wrong here. A signed `TokenRequest` is created offline, which is
why it looked right — but Ably requires it to be **exchanged within 2 minutes** of its timestamp, and
the nonce makes it **single-use**.

Our invites live an hour, get pasted into a chat and opened later, and serve up to three guests. A
TokenRequest in an invite would be dead before most guests clicked it, and usable by only the first.
Recorded so nobody reaches for it again.

### Constraints that must hold

- The JWT is scoped to **one channel** and expires with the invite, so a leaked invite reaches no
  other session and outlives nothing.
- Ably caps a token's capability at the issuing key's, so an over-broad user key still yields a
  correctly narrow JWT.
- The API key goes in the keychain and **never** into launch metadata, which is copied and logged —
  the same rule as the relay credentials.

## Invite format

`OPNRemoteCoOpInviteTokenPayload` is already versioned (`version: Int`) and HMAC-signed, so the
guest cannot forge or edit it. Bump to version 2 and add:

```
signalingKind:      "embedded" | "hosted"      // which transport the guest should use
signalingChannel:   String                     // Ably channel name for this invite
signalingToken:     String                     // Ably JWT, channel-scoped, expires with the invite
```

Version 1 invites keep working unchanged — they mean `embedded`, which is what they are.

## The seam

```swift
public protocol OPNRemoteCoOpSignalingSession: Sendable {
    func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent>
    func send(_ command: OPNRemoteCoOpSignalingCommand) async
    func close() async
}
```

Three methods, with commands and events both already enums. There are three implementations today —
embedded, native, composite — so a fourth is a normal addition rather than a rewrite.

`OPNAblyRemoteCoOpSignalingSession`:

- `send(_:)` publishes the command as JSON on the invite's channel.
- `events()` subscribes and decodes guest messages into `OPNRemoteCoOpSignalingEvent`.
- Presence leave publishes `.guestDisconnected`, replacing the heartbeat and idle sweep.
- Composes with the existing composite session, so hosted and native guests can coexist.

The **security policy must not be duplicated into it.** The review already found the kind allowlist,
the participant-claim guard and the ownership checks copy-pasted between the two existing listeners,
and drifting. A third copy is not acceptable — extract the gate first, or this transport inherits a
known-drifting policy.

## Browser guest

`connectToRoom()` currently does `new WebSocket(endpoint)` and sends `guestJoinRequested` on open.
Replace with the Ably JS SDK against the channel and token from the invite. The message shapes do not
change, so `handleMessage` and everything downstream is untouched.

The page itself becomes static — no host to serve it — so it can live on GitHub Pages: free, stable
URL, certificate browsers already trust. That removes the last reason a host needs inbound
reachability.

## What this does not solve

- **A guest on a UDP-blocking network still needs the relay.** Signaling reachability and media
  reachability are independent; this plan only removes the tunnel.
- **A dependency on Ably being up.** New joins fail during an outage; sessions already negotiated are
  unaffected, since media is peer-to-peer or via TURN.
- **The guest page still needs a public home.** GitHub Pages is free and sufficient, but it is a
  second thing to deploy.

## Phasing

1. **Extract the guest-message security gate** out of the two existing listeners into one place.
   Prerequisite, not optional: it is the only way a third transport does not become a third copy of a
   policy that has already drifted once.
2. **Invite payload v2**, the JWT minter and the keychain store. No behaviour change. *Done.*
   The visible settings card is deliberately deferred to step 4: a field a host can fill in that
   changes nothing is worse than no field, and it cannot honestly say what it does until something
   routes over it.
3. **`OPNRemoteCoOpHostedSignalingSession`**, host side only, exercised by tests against a stub.
   *Done.* Split in two: the session holds everything with a decision in it and is tested through a
   stub channel, and `OPNRemoteCoOpAblyChannel` is a thin adapter that only moves strings. Named for
   what it does rather than for Ably, since nothing in it is Ably-specific.
4. **Host side wired** — the settings card, the session composed alongside the embedded and native
   transports, and the invite carrying its channel and credential. *Done.* Split from the browser
   guest, which is 4b: until that lands nothing can actually connect over the channel, so the host
   half is committed but unproven end to end.
5. **Browser guest over Ably**, behind the `signalingKind` field so version 1 invites are unaffected.
   *Done.* Both transports made to present the same four-method shape, so `connectToRoom` and
   everything downstream of `handleMessage` do not know which one is live. The Ably JS SDK is
   vendored rather than CDN-loaded — a guest on a restrictive network is exactly the case this exists
   for, and that is the same network a CDN fetch could be blocked on.
6. **Static page hosting**, then delete the tunnel requirement from the docs and the reach card.
   *Done, as a host-configured option.* A host can point invites at a static copy of the guest page
   (GitHub Pages, documented in the README) instead of this Mac's own server. Nothing here publishes
   or deploys anything on the host's behalf — that stays a manual step, deliberately: pushing to a
   repository and changing a GitHub project's Pages settings are actions with real, external
   consequences that this plan does not get to decide for someone. The tunnel requirement is not
   deleted from the reach card; it is joined by a third glossary term explaining what hosted
   signaling covers that a tunnel cannot. A fourth "your own reachability" reach-status row, distinct
   from the four existing guest-situation rows, is still open — it needs a real way to detect whether
   this Mac itself is reachable, which does not exist yet, and guessing at that felt worse than
   leaving the gap named here.
7. ~~Presence replaces heartbeat/idle sweep~~ **Answered by the live test below: no code change
   needed.** This step was written before the hosted transport existed, when "replace" seemed like
   it meant touching the socket transports. It never did — sockets have no presence concept, and the
   heartbeat/idle sweep on the embedded and native listeners serves a different transport entirely
   and stays exactly as it is. What step 7 actually named was whether the hosted transport's decision
   to rely on presence *alone*, with no heartbeat of its own, was safe to ship - that decision was
   already built (`OPNRemoteCoOpHostedSignalingSession` never had a heartbeat to begin with) and
   needed live proof, not more code.

## Live end-to-end proof (2026-09-01)

Run once, against a real Ably account, with the host's own code path (`OPNRemoteCoOpAblyChannel` +
`OPNRemoteCoOpHostedSignalingSession`, unmodified) on one side and a raw `ARTRealtime` client driven
exactly like `app.js` on the other. The test file was never committed — throwaway, deleted
immediately after — and the key was supplied only as an environment variable to the one command that
ran it, never written to disk or logged.

Caught one real bug before running anything: `OPNRemoteCoOpAblyJWT.mint` never set
`x-ably-clientId`, so every minted token was anonymous, and Ably rejects a client that declares a
`clientId` — which the guest transport does — against an anonymous token. Confirmed by reading
Ably's docs, not by the failure itself; fixed and pinned with a test (`3a84ebd`) before the live run.

Results:

| Question | Result |
| --- | --- |
| Guest join reaches the host over a real channel | **Yes** |
| Host message reaches the guest over a real channel | **Yes** |
| Host detects an *abrupt* disconnect (no explicit leave) via presence `absent` | **Yes, within 25s** |

The third result is the one that mattered: nothing in the design forced Ably to notice an ungraceful
drop quickly, or at all, on the free tier. It did, well inside the 45s grace period the rest of Remote
Co-Op already uses for a disconnected guest's slot - so the hosted transport's presence-only liveness
model is sound as built, not a gap to close later.

Each step ships independently. Nothing before step 5 changes the default LAN behaviour.

## Testing

Today's lesson applies directly: three regression tests written for the credential fixes passed
whether or not the fix was present. Every test here needs a **positive control** — proof the channel
could have delivered the thing being asserted absent.

Specifically:

- A capability token scoped to invite A must be **proven** unable to reach invite B's channel, with a
  matching assertion that it *can* reach its own.
- The API key must be asserted absent from launch metadata and from the invite payload.
- Version 1 invites must be shown to still take the embedded path.

## Open questions

1. ~~Can a capability-limited credential be minted locally, with no server?~~ **Answered: yes, as an
   Ably JWT.** A signed TokenRequest cannot — 2-minute exchange window, single use — but a JWT signed
   HS256 over the key secret is local, multi-use, and expires when we say.
2. Is the JWT in the invite acceptable, given the invite may be pasted into a chat? It is scoped to
   one channel and expires with the invite, so it grants exactly what the invite already grants — the
   same trade as the join token today, and no worse.
3. Should the Ably key be per-user, or should the project ship one? Per-user, on today's evidence: a
   shipped key is a shared quota and a shared abuse surface, and the user asked for login-or-key.
4. ~~Does presence fire reliably enough on an ungraceful drop to replace the idle sweep, or does the
   sweep stay as a backstop?~~ **Answered by the live test above: yes, within 25s of an abrupt
   close, no sweep needed.** Not a general guarantee about Ably's infrastructure - one measurement,
   one account, one region - but it is real evidence rather than a hope, and the hosted transport
   never had a sweep to keep or discard: the question was whether presence alone was good enough to
   ship without one, and it is.

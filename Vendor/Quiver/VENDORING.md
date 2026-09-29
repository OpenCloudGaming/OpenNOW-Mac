# Vendored Quiver

Pure-Swift QUIC + HTTP/3 + WebTransport, used for the browser Remote Co-Op egress.

## Provenance

- Upstream: <https://github.com/hironichu/quiver>
- Pinned commit: `d3b0cdc56b57775adebd771558245913b4a7e728` (2026-02-11)
- License: MIT (see `LICENSE`)

## Why it is vendored

Quiver is the only implementation that ships a complete **WebTransport server** (extended CONNECT,
stream framing, capsules, datagrams) that we could drive from Swift on macOS — `msquic`, `ngtcp2`
and `lsquic` stop at QUIC/HTTP-3 and would leave us to write the WebTransport layer ourselves.

It cannot be consumed as a normal external SwiftPM dependency for one reason: upstream's
`Package.swift` does not expose `QUICCrypto` as a library product, so an external package cannot
link the TLS provider at all (upstream works only because its own demo lives inside the package).
`TLS13Handler` itself is already `public` at the pinned commit.

The `package`-to-`public` lift in `Sources/QUICCrypto` is a consequence of consuming the module
externally, not the reason for vendoring: with `QUICCrypto` exposed as a product, its
externally-visible surface must be reachable from another module. Should upstream add the product,
the reason to vendor disappears; see "Exiting the vendoring".

## Reproducing the tree

`Vendor/Quiver` is generated from the pinned commit plus the committed patch series:

```sh
scripts/vendor-quiver.sh
```

The script clones the pin, strips the non-library trees (`Tests/`, `Examples/`, `Benchmarks/`,
`Docs/`, `assets/`, `certs/`, the DocC catalogs and `TLS/TLS_SECURITY.md`), applies every patch in
`Vendor/Quiver/Patches/` in filename order, and fails if `Sources/`, `Package.swift` or `LICENSE`
differ from the committed tree. CI runs it on any change under `Vendor/Quiver`.

Every change to the vendored tree must be recorded as a patch. Editing the tree without a matching
patch makes the script — and CI — fail.

## Local changes from upstream

The patch series, with the reason for each:

| Patch | Change |
|-------|--------|
| `0001-slim-vendor-tree-and-expose-quiccrypto` | Drop the non-library targets and DocC plugin, and expose `QUICCrypto` as a library product. |
| `0002-lift-quiccrypto-package-access-to-public` | Lift `package` access to `public` across `Sources/QUICCrypto` so an external package can build the TLS server. |
| `0003-bound-clienthello-legacy-session-id` | Reject an oversized peer `legacy_session_id` as a protocol error; the initializer would otherwise trap. |
| `0004-saturate-ack-range-estimate` | Saturate the capacity estimate derived from peer ACK ranges; a plain sum traps on a 62-bit range length. |
| `0005-add-webtransport-bidi-stream-signal` | Write the draft-ietf-webtrans-http3 §4.4 `0x41` signal on outgoing bidirectional WebTransport streams, which Chrome requires. |
| `0006-release-webtransport-sessions-and-streams` | Unregister sessions on close, remove streams on FIN/reset, cap streams per session, and reset child streams on session close. |
| `0007-deliver-frame-spanning-bidi-streams` | Read the signal and session-ID varints across STREAM frames; reset a signal with no session ID; reject a DATA-frame first varint instead of routing it to session 0. |
| `0008-bound-webtransport-and-crypto-buffers` | Bound the session event streams (with a drop counter), the capsule payload length, and the CRYPTO reassembly segment count. |
| `0009-harden-0rtt-retry-and-protocol-limits` | Refuse 0-RTT without replay protection, index sliced Retry data safely, remove duplicate protocol limits, and fail closed on an empty ALPN list. |

Two notes on older changes:

- The previous recipe ran `s/\bpackage /public /g` over `Sources/QUICCrypto`. That regex also hit
  prose, rewriting the `SystemTrustStore` diagnostic from "ca-certificates package" to
  "ca-certificates public". The wording is restored, and because the restored text matches upstream
  the fix leaves no delta — the access lift is now captured as `0002` rather than a blind regex.
- `MockTLSProvider` is unreachable from the app: it is selected only by
  `QUICSecurityMode.testing` inside `#if DEBUG`, and the app configures
  `QUICConfiguration.development { TLS13Handler(...) }`.

## Exiting the vendoring

Two small upstream changes would let the app consume Quiver as a normal SwiftPM dependency and
delete the vendored copy: expose `QUICCrypto` as a library product, and add the `0x41` bidirectional
signal per draft-ietf-webtrans-http3 §4.4. Until then, the patch series above is the supported
consumption path.

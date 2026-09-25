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

It cannot be consumed as a normal external SwiftPM dependency, though: its TLS provider
(`TLS13Handler`) is declared `package`-scoped in the `QUICCrypto` target, and that target is not
exposed as a library product, so an external package cannot build a TLS server at all (upstream
works only because its own demo lives inside the package). Vendoring a patched copy is therefore
the supported way to consume it.

## Local changes from upstream

1. **Slimmed.** Removed `Tests/`, `Examples/`, `Benchmarks/`, the DocC catalogs and the DocC plugin;
   kept only the library targets the app links.
2. **Exposed `QUICCrypto` as a library product.**
3. **Lifted `package` access to `public`** throughout `Sources/QUICCrypto`, so our target can
   construct a `TLS13Handler` for `QUICConfiguration.development`/`.production`.
4. **Fixed bidirectional WebTransport stream framing** (`HTTP3Connection+Streams.swift`,
   `WebTransport/WebTransportStream.swift`). Per draft-ietf-webtrans-http3 §4.4, a bidirectional
   WebTransport stream begins with the signal value `0x41` (as a varint) *before* the session ID.
   Upstream omits the signal on send and treats the first varint as the session ID on receive, so it
   only interoperates with itself. A real browser (Chrome 153) sends `0x41`, which upstream read as a
   session ID of 65 and dropped — the guest joined but no stream was ever delivered. The client now
   writes the signal, and the server accepts it optionally (so a peer without it, including upstream
   output, still works). Verified end to end against Chrome; see `spikes/browseregress`.

These are the only differences; everything else is upstream verbatim. Re-applying them after an
upstream bump is: copy `Sources/`, strip the extra targets from `Package.swift`, add the
`QUICCrypto` product, run `s/\bpackage /public /g` over `Sources/QUICCrypto`, re-apply the bidi
framing fix, then re-run `spikes/webtransport` (agency loopback) and `spikes/browseregress`
(real-browser) to confirm both still pass.

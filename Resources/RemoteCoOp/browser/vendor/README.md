# Vendored: ably-js

`ably.min.js` is the Ably JavaScript SDK, browser UMD build, fetched from
`https://cdn.jsdelivr.net/npm/ably@2.28.0/build/ably.min.js`.

Vendored rather than loaded from a CDN because the guest page is served from this Mac over a
self-signed local certificate, and a guest on a restrictive network is exactly the case hosted
signaling exists for — the same network that might block a CDN is the one this is meant to work
around.

- Version: 2.28.0
- SHA-256: `15a7911d56937c6003ded63253ab6af0d0114da0fc151f8a057b2e557c878e61`
- License: Apache-2.0 (see the header of the file)

To update: fetch the same URL with the new version number, verify the SHA-256 of what actually
shipped, and update both above.

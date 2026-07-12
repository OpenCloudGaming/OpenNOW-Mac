# OpenNOW Remote Co-Op Operations

This folder contains the browser Remote Co-Op reference stack:

- `run-servers.mjs`: all-server Node runner for LAN/all-interface testing.
- `server/broker.mjs`: signaling broker and static browser app server.
- `browser/`: guest join page.
- `turn/turn-server.mjs`: Node launcher/manager for a system `coturn` TURN server.

The broker is signaling-only. It relays JSON messages between the macOS host and browser guests. It does not relay media and does not validate gameplay authority. The host app validates signed invite tokens, approves guests, assigns player slots, rejects stale input, and routes accepted input through the native GFN input path.

## All Server Nodes

For production hosting on public IP `198.12.95.48`, run every Remote Co-Op server-side Node process with broker and TURN listeners bound to that address:

```sh
node RemoteCoOp/run-servers.mjs
```

The runner starts:

- `server/broker.mjs` with `OPENNOW_REMOTE_COOP_BIND_HOST=198.12.95.48`.
- `turn/turn-server.mjs` with `OPENNOW_REMOTE_COOP_TURN_LISTENING_IP=198.12.95.48`.

It defaults printed join/TURN URLs to `198.12.95.48`, generates an ephemeral TURN shared secret when one is not provided, and injects matching `OPENNOW_REMOTE_COOP_TURN_URLS` into the broker.

Production browser invites use HTTP/WS against the public IP by default to avoid browser domain HTTPS upgrades. HTTPS/WSS remains supported when explicitly configured with a certificate that clients trust for the IP address.

If the broker port is busy, the runner lets the broker fall back to the next available configured alternate and prints the actual browser/WebSocket URLs after the broker binds. By default, `8789` and `8790` are tried after `8788`.

Dry-run without starting long-lived servers:

```sh
node RemoteCoOp/run-servers.mjs --dry-run
```

Override the advertised public host for LAN testing:

```sh
OPENNOW_REMOTE_COOP_PUBLIC_HOST=192.168.1.25 \
node RemoteCoOp/run-servers.mjs
```

For production, provide a stable TURN REST secret:

```sh
OPENNOW_REMOTE_COOP_PUBLIC_HOST=198.12.95.48 \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
node RemoteCoOp/run-servers.mjs
```

Install `coturn` before running without `--dry-run`.

## Local Broker

Run from the repository root:

```sh
node RemoteCoOp/server/broker.mjs
```

Default endpoints:

```text
Browser join page: http://198.12.95.48:8788/
WebSocket signaling: ws://198.12.95.48:8788/remote-coop
```

Broker environment:

```text
OPENNOW_REMOTE_COOP_BIND_HOST=198.12.95.48
OPENNOW_REMOTE_COOP_PORT=8788
OPENNOW_REMOTE_COOP_PORT_ALTERNATES=8789,8790
OPENNOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302
OPENNOW_REMOTE_COOP_TURN_URLS=turn:198.12.95.48:3478?transport=udp,turn:198.12.95.48:3478?transport=tcp
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=shared-coturn-rest-secret
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
```

When `OPENNOW_REMOTE_COOP_PORT` is unavailable, the broker retries the comma-separated `OPENNOW_REMOTE_COOP_PORT_ALTERNATES` list. Keep OpenNOW's Remote Co-Op Signaling Server and Guest Join URL settings aligned with the actual broker URL printed at startup.

If broker certificate/key paths are configured, the broker serves HTTPS/WSS. Without them, it serves HTTP/WS.

Static TURN credentials are also supported with `OPENNOW_REMOTE_COOP_TURN_USERNAME` and `OPENNOW_REMOTE_COOP_TURN_CREDENTIAL`, but shared-secret REST credentials are preferred for production.

## TURN Server

`turn/turn-server.mjs` is a Node executable that manages `coturn`. It does not implement the TURN protocol itself.

Install `coturn` first:

```sh
brew install coturn
```

On Debian or Ubuntu:

```sh
sudo apt-get install coturn
```

Dry-run local config:

```sh
OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs --dry-run
```

Run local development TURN:

```sh
OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs
```

Run broker against local TURN:

```sh
OPENNOW_REMOTE_COOP_TURN_URLS='turn:127.0.0.1:3478?transport=udp,turn:127.0.0.1:3478?transport=tcp' \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/server/broker.mjs
```

## Production TURN

Run TURN on the production public IP `198.12.95.48`:

```sh
OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST=198.12.95.48 \
OPENNOW_REMOTE_COOP_TURN_REALM=198.12.95.48 \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
OPENNOW_REMOTE_COOP_TURN_EXTERNAL_IP=203.0.113.10 \
node RemoteCoOp/turn/turn-server.mjs
```

Expose these firewall ports on the TURN host:

```text
3478/udp       TURN UDP
3478/tcp       TURN TCP
443/tcp        TURNS TCP when cert/key are explicitly configured
49160-49200/udp relay allocation range by default
```

Configure the broker with the same secret:

```sh
OPENNOW_REMOTE_COOP_TURN_URLS='turn:198.12.95.48:3478?transport=udp,turn:198.12.95.48:3478?transport=tcp' \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600 \
node RemoteCoOp/server/broker.mjs
```

The Node broker can still terminate TLS directly with `OPENNOW_REMOTE_COOP_BROKER_CERT` and `OPENNOW_REMOTE_COOP_BROKER_KEY`, or it can keep binding to `127.0.0.1` behind a reverse proxy. The default production path intentionally uses the public IP over HTTP/WS.

## Transport Modes

Automatic mode is the default. Browsers try direct ICE candidates first and fall back to TURN when available.

Relay Only mode forces TURN relay candidates and avoids exposing direct peer IP candidates.

Direct Only mode omits TURN and may fail behind strict routers or firewalls.

## Smoke Checks

Run the broker network-config smoke check:

```sh
node RemoteCoOp/server/smoke-network-config.mjs
```

This starts a temporary broker with test STUN/TURN settings and verifies:

- Automatic emits STUN plus TURN.
- Relay Only forces `iceTransportPolicy: "relay"`.
- Relay Only emits expiring TURN REST credentials.
- Direct Only omits TURN.

Target an already running broker:

```sh
OPENNOW_REMOTE_COOP_TURN_URLS='turn:127.0.0.1:3478?transport=udp' \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/server/smoke-network-config.mjs --broker-url http://127.0.0.1:8788
```

Validate TURN launcher config without starting coturn:

```sh
OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs --dry-run
```

## Manual End-To-End Validation

Local validation:

1. Start the TURN server in development mode.
2. Start the broker with matching TURN URLs and shared secret.
3. Launch OpenNOW.
4. Enable Remote Co-Op and reserve at least one guest controller.
5. Start a real GFN stream.
6. Create a Remote Co-Op invite.
7. Open the browser join page and join as a guest.
8. Approve the guest on the host.
9. Verify guest video renders.
10. Verify guest audio plays game audio.
11. Verify guest input controls the native GFN session.
12. Check the browser diagnostics panel for WebRTC `connected`, a selected ICE route, inbound audio/video stats, and input packets using the data channel.

WAN validation:

1. Deploy broker on public IP `198.12.95.48` with HTTP/WS port `8788` open.
2. Deploy TURN with UDP/TCP `3478` and the UDP relay range open.
3. Configure OpenNOW Remote Co-Op invites to use the deployed broker URL.
4. Test host and guest on different networks.
5. Repeat in Automatic mode.
6. Repeat in Relay Only mode.
7. Use the browser diagnostics copy button to capture candidate route, RTT, media stats, and input transport for failures.

## Browser Diagnostics

The browser guest page includes a connection diagnostics panel after joining a room. It reports:

- WebSocket broker state and host approval state.
- Transport mode, ICE policy, configured STUN/TURN/TURNS counts, and local/remote candidate counts.
- WebRTC connection, signaling, ICE connection, and ICE gathering state.
- Selected candidate route by candidate type/protocol without printing raw IP addresses.
- Inbound video/audio stats, including dimensions, FPS, bytes received, jitter, packet loss, and route RTT when the browser exposes them.
- Input transport, packet count, last sequence number, and whether input is using the data channel or WebSocket fallback.

Use the Copy button when reporting E2E failures. Avoid sharing invite tokens or raw SDP separately.

## Security Notes

- Do not run anonymous TURN in production.
- Use `OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET` with short-lived REST credentials.
- Keep `OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1` limited to local development.
- Keep the coturn CLI disabled.
- Bound the relay port range and firewall only the required ports.
- Treat TURN as bandwidth-relay infrastructure and monitor/limit it at the deployment layer.
- Do not log invite tokens, raw SDP, or TURN secrets.

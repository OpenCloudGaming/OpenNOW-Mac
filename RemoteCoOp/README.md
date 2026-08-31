# OpenNOW Remote Co-Op Operations

This folder contains the browser Remote Co-Op reference stack:

- `run-servers.mjs`: all-server Node runner for LAN/all-interface testing.
- `panel/control-panel.mjs`: HTTPS background control panel that manages `run-servers.mjs`.
- `server/broker.mjs`: signaling broker and static browser app server.
- `browser/`: guest join page.
- `turn/turn-server.mjs`: Node launcher/manager for a system `coturn` TURN server.

The broker is signaling-only. It relays JSON messages between the macOS host and browser guests. It does not relay media and does not validate gameplay authority. The host app validates signed invite tokens, approves guests, assigns player slots, rejects stale input, and routes accepted input through the native GFN input path.

## Invite Signing Secret

The broker verifies every invite signature server-side. It rejects the host's own registration and
each guest join when the signature does not check out, so a mismatched secret is not a degraded
mode: nobody can join, and the only symptom is `Invalid or expired invite token`.

Both sides key the HMAC with the **raw bytes of the secret string**, matching Node's
`createHmac("sha256", secret)`. The value is opaque; it does not have to be base64.

Set the same value on both sides:

```sh
OPENNOW_REMOTE_COOP_INVITE_SECRET='replace-with-long-random-secret' \
node RemoteCoOp/run-servers.mjs
```

In OpenNOW, paste it into Settings > Gameplay > Remote Co-Op > Invite Signing Secret. It is stored
in the keychain and is never displayed again. `OPENNOW_REMOTE_COOP_INVITE_SECRET` still takes
precedence when the app is launched from a shell, which is the convenient path for local
development alongside `run-servers.mjs`.

`run-servers.mjs` and the service installers generate a secret when none is provided. That
generated value is what has to be copied into the app - read it from the panel's environment file,
or set it explicitly so both sides are configured from the same place.

## Background Service And Web Panel

Production deployments should run the web control panel as the supervised service. The panel stays alive in the background, authenticates against system accounts, and starts/stops/restarts `run-servers.mjs` as its managed child process.

Install Linux systemd service:

```sh
RemoteCoOp/service/install-linux.sh
```

Install macOS launchd service:

```sh
RemoteCoOp/service/install-macos.sh
```

Then open:

```text
https://198.12.95.48:<printed-panel-port>/
```

The installers are non-interactive. They create the panel access group, install the PAM helper, select currently unused high ports, generate a stable TURN secret, and start the panel. Use the panel URL printed by the installer. The panel uses a generated self-signed HTTPS certificate unless configured otherwise, so browsers will warn on first access.

The panel also includes a Git updater. It only applies clean fast-forward updates and validates with `node RemoteCoOp/run-servers.mjs --dry-run` by default.

See `RemoteCoOp/service/README.md` for service operation details.

## All Server Nodes

For production hosting on public IP `198.12.95.48`, run every Remote Co-Op server-side Node process with broker and TURN listeners bound to that address:

```sh
node RemoteCoOp/run-servers.mjs
```

The runner starts:

- `server/broker.mjs` with `OPENNOW_REMOTE_COOP_BIND_HOST=198.12.95.48`.
- `turn/turn-server.mjs` with `OPENNOW_REMOTE_COOP_TURN_LISTENING_IP=198.12.95.48`.

It defaults printed join/TURN URLs to `198.12.95.48`, generates an ephemeral TURN shared secret when one is not provided, and injects matching `OPENNOW_REMOTE_COOP_TURN_URLS` into the broker.

The broker always serves HTTPS/WSS. It cannot serve plaintext: browsers gate `RTCPeerConnection` and
the Gamepad API behind a secure context, and `http://` on anything other than `localhost` is not one,
so a guest page served over HTTP cannot build a peer connection at all.

If the broker port is busy, the runner lets the broker fall back to the next available configured alternate and prints the actual browser/WebSocket URLs after the broker binds. By default, `32190` and `32191` are tried after `32188`.

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

## Running The Broker On The Host Mac

The broker is signaling-only and small enough to run on the same machine as OpenNOW, which is the
simplest way to test a guest join without deploying anything.

```sh
OPENNOW_REMOTE_COOP_BIND_HOST=0.0.0.0 \
OPENNOW_REMOTE_COOP_PUBLIC_HOST=127.0.0.1 \
OPENNOW_REMOTE_COOP_INVITE_SECRET='pick-something-long' \
node RemoteCoOp/server/broker.mjs
```

Then in OpenNOW, Settings > Gameplay > Remote Co-Op:

- Signaling Server: `wss://127.0.0.1:32188/remote-coop`
- Guest Join URL: `https://127.0.0.1:32188/`
- Invite Signing Secret: the same string as above

Relaunch the stream afterwards. Remote Co-Op preferences are frozen into the stream's launch
metadata, because reserved controller slots are advertised to GeForce NOW before the session starts,
so changes never apply to a session that is already running.

`OPENNOW_REMOTE_COOP_PUBLIC_HOST` sets the generated certificate's subject alternative name and is
added to the WebSocket origin allowlist. For a guest on another machine on the LAN, set it to the
host's LAN address and use that address in both URLs above.

## Local Broker

Run from the repository root:

```sh
node RemoteCoOp/server/broker.mjs
```

Default endpoints:

```text
Browser join page: http://198.12.95.48:32188/
WebSocket signaling: ws://198.12.95.48:32188/remote-coop
```

Broker environment:

```text
OPENNOW_REMOTE_COOP_BIND_HOST=198.12.95.48
OPENNOW_REMOTE_COOP_PORT=32188
OPENNOW_REMOTE_COOP_PORT_ALTERNATES=8789,8790
OPENNOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302
OPENNOW_REMOTE_COOP_TURN_URLS=turn:198.12.95.48:32189?transport=udp,turn:198.12.95.48:32189?transport=tcp
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=shared-coturn-rest-secret
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
OPENNOW_REMOTE_COOP_LOG_NETWORK=1
OPENNOW_REMOTE_COOP_LOG_MESSAGES=0
```

When `OPENNOW_REMOTE_COOP_PORT` is unavailable, the broker retries the comma-separated `OPENNOW_REMOTE_COOP_PORT_ALTERNATES` list. Keep OpenNOW's Remote Co-Op Signaling Server and Guest Join URL settings aligned with the actual broker URL printed at startup.

The broker always serves HTTPS/WSS. Supply `OPENNOW_REMOTE_COOP_BROKER_CERT` and
`OPENNOW_REMOTE_COOP_BROKER_KEY` to use your own certificate; otherwise it generates a self-signed
one into `RemoteCoOp/state/` on first run, and guests accept the browser warning once per origin.

Static TURN credentials are also supported with `OPENNOW_REMOTE_COOP_TURN_USERNAME` and `OPENNOW_REMOTE_COOP_TURN_CREDENTIAL`, but shared-secret REST credentials are preferred for production.

## Broker Network Logging

The broker writes network lifecycle logs to stdout by default. Disable them with:

```sh
OPENNOW_REMOTE_COOP_LOG_NETWORK=0 node RemoteCoOp/server/broker.mjs
```

Network logs use `[network]` lines and include HTTP request status, WebSocket upgrade decisions, socket open/close/error, host registration, guest pending/join/disconnect, room expiry/close, relay decisions, and rejection reasons. They intentionally omit invite tokens, raw SDP, TURN secrets, and full message payloads.

Full signaling message flow logs remain opt-in for short debugging windows:

```sh
OPENNOW_REMOTE_COOP_LOG_MESSAGES=1 node RemoteCoOp/server/broker.mjs
```

Message flow logs print message kind, role, room ID, participant ID, and peer signal kind only; they do not print full payloads.

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
OPENNOW_REMOTE_COOP_TURN_URLS='turn:127.0.0.1:32189?transport=udp,turn:127.0.0.1:32189?transport=tcp' \
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
32189/udp      TURN UDP
32189/tcp      TURN TCP
32443/tcp      TURNS TCP when cert/key are explicitly configured
42160-42200/udp relay allocation range by default
```

Configure the broker with the same secret:

```sh
OPENNOW_REMOTE_COOP_TURN_URLS='turn:198.12.95.48:32189?transport=udp,turn:198.12.95.48:32189?transport=tcp' \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600 \
node RemoteCoOp/server/broker.mjs
```

The Node broker terminates TLS itself with `OPENNOW_REMOTE_COOP_BROKER_CERT` and
`OPENNOW_REMOTE_COOP_BROKER_KEY`, or it can bind `127.0.0.1` behind a reverse proxy that does.

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
- A guest that joins before the host remains pending and is forwarded when the host registers.

Target an already running broker:

```sh
OPENNOW_REMOTE_COOP_TURN_URLS='turn:127.0.0.1:32189?transport=udp' \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/server/smoke-network-config.mjs --broker-url http://127.0.0.1:32188
```

Validate TURN launcher config without starting coturn:

```sh
OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=opennow-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs --dry-run
```

## Manual End-To-End Validation

Remote Co-Op hosts from both stream transports. Run the local pass once on each: Settings >
Gameplay > Streaming selects between native NVST and WebRTC, and they reach the guest through
different code. On native NVST the guest's video comes from the VideoToolbox decode callback, the
audio from the NVST audio socket, and the guest's player slot is announced to the seat with a
`0x20d` gamepad descriptor that the WebRTC path never has to send.

Local validation:

1. Start the TURN server in development mode.
2. Start the broker with matching TURN URLs and shared secret.
3. Launch OpenNOW.
4. Confirm the Invite Signing Secret matches the broker's.
5. Enable Remote Co-Op and reserve at least one guest controller.
6. Start a real GFN stream.
7. Create a Remote Co-Op invite.
8. Open the browser join page and join as a guest.
9. Approve the guest on the host.
10. Verify guest video renders.
11. Verify guest audio plays game audio.
12. Verify guest input controls the game as player 2, and that the host's own controller still
    controls player 1. Both pads moving together, or the host's pad going dead when the guest is
    approved, means the connected bitmap announced one and not the other.
13. Remove the guest and verify nothing stays held down in the game.
14. Check the browser diagnostics panel for WebRTC `connected`, a selected ICE route, inbound audio/video stats, and input packets using the data channel.

WAN validation:

1. Deploy the broker on your public IP with the selected high HTTPS/WSS port open.
2. Deploy TURN with the selected high UDP/TCP port and UDP relay range open.
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

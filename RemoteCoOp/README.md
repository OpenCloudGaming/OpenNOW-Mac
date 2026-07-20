# MacForce Now Remote Co-Op Operations

This folder contains the browser Remote Co-Op reference stack:

- `run-servers.mjs`: all-server Node runner for LAN/all-interface testing.
- `panel/control-panel.mjs`: HTTPS background control panel that manages `run-servers.mjs`.
- `server/broker.mjs`: signaling broker and static browser app server.
- `browser/`: guest join page.
- `turn/turn-server.mjs`: Node launcher/manager for a system `coturn` TURN server.

The broker is signaling-only. It relays JSON messages between the macOS host and browser guests. It does not relay media and does not validate gameplay authority. The host app validates signed invite tokens, approves guests, assigns player slots, rejects stale input, and routes accepted input through the native GFN input path.

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

- `server/broker.mjs` with `MACFORCE_NOW_REMOTE_COOP_BIND_HOST=198.12.95.48`.
- `turn/turn-server.mjs` with `MACFORCE_NOW_REMOTE_COOP_TURN_LISTENING_IP=198.12.95.48`.

It defaults printed join/TURN URLs to `198.12.95.48`, generates an ephemeral TURN shared secret when one is not provided, and injects matching `MACFORCE_NOW_REMOTE_COOP_TURN_URLS` into the broker.

Production browser invites use HTTP/WS against the public IP by default to avoid browser domain HTTPS upgrades. HTTPS/WSS remains supported when explicitly configured with a certificate that clients trust for the IP address.

If the broker port is busy, the runner lets the broker fall back to the next available configured alternate and prints the actual browser/WebSocket URLs after the broker binds. By default, `32190` and `32191` are tried after `32188`.

Dry-run without starting long-lived servers:

```sh
node RemoteCoOp/run-servers.mjs --dry-run
```

Override the advertised public host for LAN testing:

```sh
MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST=192.168.1.25 \
node RemoteCoOp/run-servers.mjs
```

For production, provide a stable TURN REST secret:

```sh
MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST=198.12.95.48 \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
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
Browser join page: http://198.12.95.48:32188/
WebSocket signaling: ws://198.12.95.48:32188/remote-coop
```

Broker environment:

```text
MACFORCE_NOW_REMOTE_COOP_BIND_HOST=198.12.95.48
MACFORCE_NOW_REMOTE_COOP_PORT=32188
MACFORCE_NOW_REMOTE_COOP_PORT_ALTERNATES=8789,8790
MACFORCE_NOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302
MACFORCE_NOW_REMOTE_COOP_TURN_URLS=turn:198.12.95.48:32189?transport=udp,turn:198.12.95.48:32189?transport=tcp
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=shared-coturn-rest-secret
MACFORCE_NOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
MACFORCE_NOW_REMOTE_COOP_LOG_NETWORK=1
MACFORCE_NOW_REMOTE_COOP_LOG_MESSAGES=0
```

When `MACFORCE_NOW_REMOTE_COOP_PORT` is unavailable, the broker retries the comma-separated `MACFORCE_NOW_REMOTE_COOP_PORT_ALTERNATES` list. Keep MacForce Now's Remote Co-Op Signaling Server and Guest Join URL settings aligned with the actual broker URL printed at startup.

If broker certificate/key paths are configured, the broker serves HTTPS/WSS. Without them, it serves HTTP/WS.

Static TURN credentials are also supported with `MACFORCE_NOW_REMOTE_COOP_TURN_USERNAME` and `MACFORCE_NOW_REMOTE_COOP_TURN_CREDENTIAL`, but shared-secret REST credentials are preferred for production.

## Broker Network Logging

The broker writes network lifecycle logs to stdout by default. Disable them with:

```sh
MACFORCE_NOW_REMOTE_COOP_LOG_NETWORK=0 node RemoteCoOp/server/broker.mjs
```

Network logs use `[network]` lines and include HTTP request status, WebSocket upgrade decisions, socket open/close/error, host registration, guest pending/join/disconnect, room expiry/close, relay decisions, and rejection reasons. They intentionally omit invite tokens, raw SDP, TURN secrets, and full message payloads.

Full signaling message flow logs remain opt-in for short debugging windows:

```sh
MACFORCE_NOW_REMOTE_COOP_LOG_MESSAGES=1 node RemoteCoOp/server/broker.mjs
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
MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=macforce-now-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs --dry-run
```

Run local development TURN:

```sh
MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=macforce-now-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs
```

Run broker against local TURN:

```sh
MACFORCE_NOW_REMOTE_COOP_TURN_URLS='turn:127.0.0.1:32189?transport=udp,turn:127.0.0.1:32189?transport=tcp' \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=macforce-now-remote-coop-local-secret \
node RemoteCoOp/server/broker.mjs
```

## Production TURN

Run TURN on the production public IP `198.12.95.48`:

```sh
MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST=198.12.95.48 \
MACFORCE_NOW_REMOTE_COOP_TURN_REALM=198.12.95.48 \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
MACFORCE_NOW_REMOTE_COOP_TURN_EXTERNAL_IP=203.0.113.10 \
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
MACFORCE_NOW_REMOTE_COOP_TURN_URLS='turn:198.12.95.48:32189?transport=udp,turn:198.12.95.48:32189?transport=tcp' \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
MACFORCE_NOW_REMOTE_COOP_TURN_TTL_SECONDS=3600 \
node RemoteCoOp/server/broker.mjs
```

The Node broker can still terminate TLS directly with `MACFORCE_NOW_REMOTE_COOP_BROKER_CERT` and `MACFORCE_NOW_REMOTE_COOP_BROKER_KEY`, or it can keep binding to `127.0.0.1` behind a reverse proxy. The default production path intentionally uses the public IP over HTTP/WS.

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
MACFORCE_NOW_REMOTE_COOP_TURN_URLS='turn:127.0.0.1:32189?transport=udp' \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=macforce-now-remote-coop-local-secret \
node RemoteCoOp/server/smoke-network-config.mjs --broker-url http://127.0.0.1:32188
```

Validate TURN launcher config without starting coturn:

```sh
MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=macforce-now-remote-coop-local-secret \
node RemoteCoOp/turn/turn-server.mjs --dry-run
```

## Manual End-To-End Validation

Local validation:

1. Start the TURN server in development mode.
2. Start the broker with matching TURN URLs and shared secret.
3. Launch MacForceNow.
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

1. Deploy broker on public IP `198.12.95.48` with the selected high HTTP/WS port open.
2. Deploy TURN with the selected high UDP/TCP port and UDP relay range open.
3. Configure MacForce Now Remote Co-Op invites to use the deployed broker URL.
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
- Use `MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET` with short-lived REST credentials.
- Keep `MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1` limited to local development.
- Keep the coturn CLI disabled.
- Bound the relay port range and firewall only the required ports.
- Treat TURN as bandwidth-relay infrastructure and monitor/limit it at the deployment layer.
- Do not log invite tokens, raw SDP, or TURN secrets.

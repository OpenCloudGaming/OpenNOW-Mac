# OpenNOW Remote Co-Op Operations

This folder contains the repo-local browser Remote Co-Op reference stack:

- `server/broker.mjs`: signaling broker and static browser app server.
- `browser/`: guest join page.
- `turn/turn-server.mjs`: Node launcher/manager for a system `coturn` TURN server.

The broker is signaling-only. It relays JSON messages between the macOS host and browser guests. It does not relay media and does not validate gameplay authority. The host app validates signed invite tokens, approves guests, assigns player slots, rejects stale input, and routes accepted input through the native GFN input path.

## Local Broker

Run from the repository root:

```sh
node RemoteCoOp/server/broker.mjs
```

Default endpoints:

```text
Browser join page: http://127.0.0.1:8787/
WebSocket signaling: ws://127.0.0.1:8787/remote-coop
```

Broker environment:

```text
OPENNOW_REMOTE_COOP_BIND_HOST=127.0.0.1
OPENNOW_REMOTE_COOP_PORT=8787
OPENNOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302
OPENNOW_REMOTE_COOP_TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp,turns:turn.example.com:443?transport=tcp
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=shared-coturn-rest-secret
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
```

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

Run TURN on a public host with DNS, for example `turn.example.com`:

```sh
OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST=turn.example.com \
OPENNOW_REMOTE_COOP_TURN_REALM=turn.example.com \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
OPENNOW_REMOTE_COOP_TURN_CERT=/etc/letsencrypt/live/turn.example.com/fullchain.pem \
OPENNOW_REMOTE_COOP_TURN_KEY=/etc/letsencrypt/live/turn.example.com/privkey.pem \
OPENNOW_REMOTE_COOP_TURN_EXTERNAL_IP=203.0.113.10 \
node RemoteCoOp/turn/turn-server.mjs
```

Expose these firewall ports on the TURN host:

```text
3478/udp       TURN UDP
3478/tcp       TURN TCP
443/tcp        TURNS TCP when cert/key are configured
49160-49200/udp relay allocation range by default
```

Configure the broker with the same secret:

```sh
OPENNOW_REMOTE_COOP_TURN_URLS='turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp,turns:turn.example.com:443?transport=tcp' \
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET='replace-with-long-random-secret' \
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600 \
node RemoteCoOp/server/broker.mjs
```

Use HTTPS/WSS for the broker in production, usually through a reverse proxy on port `443`. The broker can keep binding to `127.0.0.1` behind that proxy, or bind to `0.0.0.0` with `OPENNOW_REMOTE_COOP_BIND_HOST=0.0.0.0` if your deployment requires it.

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
node RemoteCoOp/server/smoke-network-config.mjs --broker-url http://127.0.0.1:8787
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

WAN validation:

1. Deploy broker behind HTTPS/WSS.
2. Deploy TURN with UDP/TCP `3478`, TURNS TCP `443`, and the UDP relay range open.
3. Configure OpenNOW Remote Co-Op invites to use the deployed broker URL.
4. Test host and guest on different networks.
5. Repeat in Automatic mode.
6. Repeat in Relay Only mode.

## Security Notes

- Do not run anonymous TURN in production.
- Use `OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET` with short-lived REST credentials.
- Keep `OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1` limited to local development.
- Keep the coturn CLI disabled.
- Bound the relay port range and firewall only the required ports.
- Treat TURN as bandwidth-relay infrastructure and monitor/limit it at the deployment layer.
- Do not log invite tokens, raw SDP, or TURN secrets.

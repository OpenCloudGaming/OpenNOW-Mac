# OpenNOW Remote Co-Op Broker

This folder contains the repo-local reference implementation for browser-based Remote Co-Op signaling.

Run the broker from the repository root:

```sh
node RemoteCoOp/server/broker.mjs
```

Default endpoints:

```text
Browser join page: http://127.0.0.1:8787/
WebSocket signaling: ws://127.0.0.1:8787/remote-coop
```

Network traversal environment:

```text
OPENNOW_REMOTE_COOP_PORT=8787
OPENNOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302
OPENNOW_REMOTE_COOP_TURN_URLS=turn:turn.example.com:3478?transport=udp,turns:turn.example.com:443?transport=tcp
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=shared-coturn-rest-secret
OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
```

Static TURN credentials are also supported with `OPENNOW_REMOTE_COOP_TURN_USERNAME` and `OPENNOW_REMOTE_COOP_TURN_CREDENTIAL`. Use TLS (`https`/`wss`) in production and expose the broker on port `443` so hosts and guests only need outbound HTTPS/WebSocket access through routers and firewalls.

The broker relays JSON messages between the macOS host and browser guests. It does not validate gameplay authority. The host app still validates signed invite tokens, approves guests, assigns player slots, rejects stale input, and routes accepted input through the existing native GFN path.

Automatic mode is the default: browsers try direct ICE candidates first and fall back to TURN when available. Relay Only mode forces TURN candidates and avoids exposing direct peer IP candidates to the other peer.

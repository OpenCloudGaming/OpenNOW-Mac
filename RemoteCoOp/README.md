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

The broker relays JSON messages between the macOS host and browser guests. It does not validate gameplay authority. The host app still validates signed invite tokens, approves guests, assigns player slots, rejects stale input, and routes accepted input through the existing native GFN path.

Production deployments should run the same protocol behind TLS, add persistent room telemetry, and provide TURN credentials for host-to-guest media/data WebRTC sessions.

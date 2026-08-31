# OpenNOW Remote Co-Op

Invite someone into your GeForce NOW session from a browser. They get the video and audio, and their
controller becomes a second player in the game.

OpenNOW hosts everything itself. There is no server to deploy, no account to create, and no secret
to share.

## How it works

When you create an invite, OpenNOW starts an HTTPS server on this Mac. It serves the guest page from
inside the app bundle and carries the WebRTC handshake on the same port. Once the guest is approved,
video, audio and their gamepad input flow peer-to-peer, straight between the two machines.

One port serves both the page and the signaling socket deliberately: the browser grants a
certificate exception on a top-level navigation, and that exception then covers the socket. Split
across two ports there is no way to grant one for a bare WebSocket.

## Hosting a session

1. Settings > Remote Co-Op: opt into the alpha, enable Remote Co-Op, and reserve at least one guest
   controller. Reserved slots are advertised to GeForce NOW **before** launch, so this has to be set
   before starting the stream.
2. Launch a game.
3. Open the stream HUD (⌘G) and choose **Create Invite** under CO-OP. The link is copied to your
   clipboard.
4. Send the link to your guest.
5. Approve them when they appear in the CO-OP panel.

Your guest needs a controller. Keyboard and mouse input is not supported for guests: the wire packet
carries pad state, and the seat has no second keyboard to route their keystrokes to. The guest page
says so, and prompts them to press a button — browsers do not report a gamepad until one is pressed.

### Guests on your network

The invite link points at this Mac's LAN address. Your guest accepts a browser certificate warning
once, because the certificate is self-signed — there is no certificate authority that will issue one
for a private address. The fingerprint is shown in Settings if they want to confirm it.

### Guests on another network

A guest elsewhere has to be able to reach this Mac. A tunnel is the simplest way, and it also gets a
certificate browsers already trust, so the warning disappears.

Run one against the local server:

```sh
# Cloudflare (no account needed)
cloudflared tunnel --url https://127.0.0.1:32188 --no-tls-verify

# ngrok (needs a free account)
ngrok http https://127.0.0.1:32188 --host-header=rewrite
```

Then paste the public HTTPS address it prints into Settings > Remote Co-Op > Tunnel > Public Address,
and relaunch the stream. Invites will point at the tunnel instead of the LAN address.

The don't-verify-upstream flag matters: the tunnel reaches this Mac over HTTPS with a self-signed
certificate and has to be told not to validate it. Your guest only ever sees the tunnel's own
certificate.

A forwarded port works too — point Public Address at `https://<your public address>:32188`. Note
this exposes the port to the internet, where a tunnel does not.

## Transport

**Auto** uses public STUN servers to discover a route to guests on other networks. This reveals your
Mac's public address to the guest, which is unavoidable for a direct connection.

**Same Network** offers only your machine's own interface addresses. Nothing about your public
address is shared, and only guests on your network can connect.

There is no relay option. A TURN relay is a public host with bandwidth, which cannot be the machine
running the game, so guest pairs whose routers refuse to hole-punch will not connect. That is a
deliberate trade for having nothing to operate.

## Limits

- Three guests maximum — the seat's own limit.
- Guests need a controller.
- The session lives as long as the app does. There is no persistent room, so an invite link is only
  good while the stream is running.
- Reserved slots and every other Remote Co-Op setting are frozen into the stream at launch. Changes
  apply to the next stream, not the current one.

## Troubleshooting

The guest page has a diagnostics panel behind the **i** button, with a Copy button. It reports the
WebSocket state, host approval, the selected ICE route, inbound media stats, and whether input is
flowing. That is the first thing to read when something does not work.

Common cases:

- **"Press any button"** — the browser has not seen a controller yet. This is normal.
- **`controller not detected`, 0 input packets** — no gamepad is connected on the guest's machine.
- **Stuck on connecting, no selected route** — no network path was found. A guest on another network
  needs a tunnel or a forwarded port.
- **Certificate warning** — expected without a tunnel. Accepting it once per address is enough.

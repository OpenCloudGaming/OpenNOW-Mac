# OpenNOW Remote Co-Op

Invite someone into your GeForce NOW session. They get the video and audio, and their controller
becomes a second player in the game. A guest can join from a browser, or from OpenNOW itself on
another Mac.

OpenNOW hosts everything itself. There is no server to deploy, no account to create, and no secret
to share.

## Requires the Native/NVST transport

Remote Co-Op only hosts on **Settings > Streaming > Transport > Native/NVST**. On the WebRTC transport
the stream decodes inside libwebrtc, which exposes no frame tap comparable to the native decoder's, so
hosting there meant re-rendering the guest's picture — a second decode and encode per frame on the
host, and a stream guests described as sluggish. The native path hands over the decoder's own
`CVPixelBuffer`, which is what makes the relay cheap enough to be worth having.

The Remote Co-Op settings tab says so when the WebRTC transport is selected, and the stream HUD's
CO-OP panel says it there rather than hiding, so a host who configured everything and found no invite
button knows it is the transport rather than a missing setting.

## How it works

When you create an invite, OpenNOW starts an HTTPS server on this Mac. It serves the guest page from
inside the app bundle and carries the WebRTC handshake on the same port. Once the guest is approved,
video, audio and their gamepad input flow peer-to-peer, straight between the two machines.

One port serves both the page and the signaling socket deliberately: the browser grants a
certificate exception on a top-level navigation, and that exception then covers the socket. Split
across two ports there is no way to grant one for a bare WebSocket.

A second listener on port 32189 serves guests running OpenNOW. That path skips the browser entirely:
no certificate to accept, hardware video decode, and gamepad input sampled from the HID report rather
than from the browser's polled Gamepad API.

## Hosting a session

1. Settings > Remote Co-Op: opt into the alpha, enable Remote Co-Op, and reserve at least one guest
   controller. Reserved slots are advertised to GeForce NOW **before** launch, so this has to be set
   before starting the stream.
2. Launch a game.
3. Open the stream HUD (⌘G) and choose **Create Invite** under CO-OP. The link is copied to your
   clipboard.
4. Send the link to your guest. Guests running OpenNOW can also open **Join Remote Co-Op** from the
   Home top bar.
5. Approve them when they appear in the CO-OP panel. An on-screen notice tells you when someone is
   waiting, so you do not have to keep the HUD open.

Your guest needs a controller. Keyboard and mouse input is not supported for guests: the wire packet
carries pad state, and the seat has no second keyboard to route their keystrokes to. Both guest
clients say so when no controller is connected.

A **browser** guest is additionally prompted to press a button. That is not a rule of ours — the
Gamepad API hides controllers until one is pressed, as a fingerprinting mitigation, so the page cannot
see a connected pad before a gesture. A guest in **OpenNOW** needs no such prompt: GameController
reports a pad immediately, and a Steam Controller 2 is picked up through the same HID path the host
uses, with the same mapping profile and grip combos.

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

# Tailscale Funnel (needs Tailscale, which you may already be running)
tailscale funnel --bg --https=443 https+insecure://127.0.0.1:32188
```

**Tailscale Funnel** is the best of the three if you already run Tailscale. It publishes to the open
internet — the guest needs no Tailscale of their own — on a stable `https://<machine>.<tailnet>.ts.net`
name with a certificate that is already trusted, at no cost and with no second account. `https+insecure`
is its equivalent of `--no-tls-verify`. Funnel has to be enabled for the tailnet in the admin console
first, and it can only publish on ports 443, 8443 and 10000, which is why the public side is 443 rather
than 32188.

Funnel replaces a tunnel; it does not replace a relay. It is a TLS/TCP proxy for HTTP, so it carries
the guest page and signaling and nothing else — WebRTC media never traverses it, and a guest on a
network that filters UDP still needs the relay above. That is also why its non-configurable bandwidth
limits do not matter here: signaling is a few kilobytes, and the video never touches it.

Then paste the public HTTPS address it prints into Settings > Remote Co-Op > Tunnel > Public Address,
and relaunch the stream. Invites will point at the tunnel instead of the LAN address.

The don't-verify-upstream flag matters: the tunnel reaches this Mac over HTTPS with a self-signed
certificate and has to be told not to validate it. Your guest only ever sees the tunnel's own
certificate.

A forwarded port works too — point Public Address at `https://<your public address>:32188`. Note
this exposes the port to the internet, where a tunnel does not.

## Guests running OpenNOW

A guest with OpenNOW opens the Remote Co-Op guest window and picks the host from the list. Discovery
is Bonjour, so it needs no setup at all — on the same network the host simply appears.

Both ways in are always available and there is nothing to choose between them. Creating an invite
starts the HTTPS server for browser guests **and** the native listener for OpenNOW guests, and one
session serves both at once — a friend on Windows in a browser and a friend on a Mac in the app can be
players two and three of the same game. The browser is the cross-platform option and stays the default
for anyone you just want to send a link to; the native path is the better one when the guest happens to
have OpenNOW, because it skips the certificate warning and samples their controller at its own report
rate instead of through the browser's polled Gamepad API.

### Over Tailscale

Tailscale is the free way to give a guest a real route to your Mac with no port forwarding, no tunnel
and no relay server. Both machines join the same tailnet and the guest connects to the host's
`100.x.y.z` address directly, over WireGuard.

There is one thing to know: **Bonjour does not cross a tunnel.** Discovery is multicast, and
multicast does not traverse WireGuard, so the host will never appear in the guest's list no matter how
reachable it is. Type the address instead:

1. On the host, open the stream HUD (⌘G). The CO-OP panel shows **App Guests** with the address to
   use — the tailnet address when this Mac is on a tailnet, otherwise the LAN address.
2. On the guest, use **Or connect by address or invite link** in the Remote Co-Op guest window. A
   MagicDNS name works as well as the numeric address. The port is optional; leave it off for the
   default.

Tailscale's free plan covers 3 users and 100 devices, which is more than a co-op session needs. When
its direct connection fails it falls back to a DERP relay, which still works but adds latency — the
Tailscale admin console shows which of the two you got.

No STUN or TURN server is involved on this path. The tailnet address is a plain host candidate, so
ICE selects it without asking anyone where the machines are.

### Through a tunnel

A tunnel works for guests running OpenNOW too, but not through the address field: `cloudflared` and
`ngrok` forward HTTP, and the tunnel points at the guest-page server on 32188, not the native listener
on 32189. Paste the **invite link** instead of an address, and the guest joins over the same WebSocket
a browser guest uses. That is the only route into a tunnelled host for a native guest — and it is the
easier one anyway, because the link is what the host already copied.

Which to use, in short:

| Route | What to give the guest |
|---|---|
| Same network | Nothing — the host appears in their list |
| Tailscale or a VPN | The address from the host's **App Guests** row |
| A tunnel, including Funnel | The invite link |

## Hosted signaling (optional)

A tunnel and a relay both assume something is reachable — the host, or a path to it. When the host
itself is behind carrier-grade NAT or on a cafe or hotel network, neither one helps, because there is
nothing to tunnel to and no port to map. Hosted signaling is the way out: both sides connect outward
to a channel instead, exactly the way TURN already works for media.

It is a fallback, never the default. A guest that can reach this Mac directly still does, over the
embedded server, with no third party involved and no messages billed — hosted signaling only carries
the guests who need it.

**Setup**, in Settings > Remote Co-Op > Hosted Signaling:

1. Create a free [Ably](https://ably.com) account and an API key.
2. Paste the key (`APP_ID.KEY_ID:SECRET`, from the Ably dashboard). It never leaves the keychain — a
   short-lived credential scoped to one invite's channel is what guests actually receive.

That alone covers a guest anywhere, joining a link the host copies from this Mac — the host still has
to be reachable *for the guest page itself*, since it is served locally by default.

**To remove that last requirement** — a host who is themselves unreachable, with no server for anyone
to load a page from — publish a copy of `Resources/RemoteCoOp/browser` to a static host and paste its
URL into the same settings tab. [GitHub Pages](https://pages.github.com) is free and gives it a
trusted certificate:

```sh
# From a fork or a separate repo — publish the guest page only, not the whole project.
cp -r Resources/RemoteCoOp/browser /path/to/a/gh-pages/checkout
cd /path/to/a/gh-pages/checkout
git add . && git commit -m "guest page" && git push
```

Then enable Pages for that repository in GitHub's settings and use the URL it gives you. The page is
static and self-contained — it needs no server behind it once hosted signaling is configured, since it
gets everything else from the invite link.

Free tier: 6 million messages a month, then $2.50 per million. A session runs a few hundred messages, so
this is unlikely to ever cost anything.

## Transport

**Auto** uses public STUN servers to discover a route to guests on other networks. This reveals your
Mac's public address to the guest, which is unavoidable for a direct connection.

**Direct** offers only your machine's own interface addresses, and shares nothing about your public
address. That is not restricted to the local network: a VPN address is one of your machine's own
addresses, so this mode connects over Tailscale just as well — and is the better choice there, since a
tailnet address is already directly routable and STUN would only leak your public address for nothing.
It is the wrong choice for a guest who genuinely needs hole-punching across the open internet.

Neither mode helps a guest whose network filters UDP outright — a school, a library, a cafe. STUN
does not fix that: it discovers an address nothing is allowed to route to. Only a relay does, and a
relay is a public host with bandwidth, which cannot be the machine running the game.

## Relay (optional)

Settings > Remote Co-Op > **Relay** offers three ways to get relay credentials. All three end up in
the same place — extra ICE servers appended to an invite — so pick on setup cost, not capability.

| Provider | Free tier | Setup |
| --- | --- | --- |
| **Cloudflare** | 1,000 GB/month | Account, a subscription with a card on file, an API token. Most free bandwidth, most setup. OpenNOW creates the key for you and can read your usage. |
| **ExpressTURN** | 1,000 GB/month | Paste URLs, a username and a password. Also covers Metered, Xirsys, Turnix and Twilio. |
| **coturn** | Your own server | Paste URLs and coturn's `static-auth-secret`. No API, no account. |

The last two are named for the best-known provider of their kind, not for the credential scheme, but
neither is tied to it: **ExpressTURN** is any provider handing out a username and password, and
**coturn** is any server or provider using a shared secret.

[ExpressTURN](https://www.expressturn.com/) gives 1,000 GB a month for a username and password with
no card — the same allowance as Cloudflare for far less setup, at the cost of no usage
readout. [Metered](https://www.metered.ca/tools/openrelay/) gives 20 GB, Turnix 10 GB, Xirsys 0.5 GB.
Twilio has no free tier and charges $0.40/GB, eight times Cloudflare.

A static password never expires, so treat it as a real secret: anyone holding it can spend your
allowance. It is not sent to guests — only the ICE server entry derived from it is, which amounts to
the same thing for the length of a session, so prefer a shared secret where a provider offers one.

The **coturn** option is the best of the three if you run your own [coturn](https://github.com/coturn/coturn),
which a spare VPS handles easily. Run it with `--use-auth-secret --static-auth-secret=<secret>` and
paste the same secret here. Credentials are then derived locally — `username` is
`<unix expiry>:opennow` and the password an HMAC-SHA1 of it — so there is no API to call, nothing
long-lived reaches a guest, and each credential expires after six hours on its own.

### Cloudflare

The Cloudflare provider takes a Realtime TURN key. With one configured, every
invite additionally carries relay credentials, and a guest who cannot connect directly uses them. The
relevant URL is `turns:turn.cloudflare.com:443?transport=tcp`, which is indistinguishable from HTTPS
on the wire — it gets through the networks that block everything else.

Setup is once, on the host, and takes one value:

1. Sign in to Cloudflare and **subscribe to Realtime**. Nothing is due — 1,000 GB a month is
   included, and the checkout reads `$0.00` — but it asks for a card, and the API refuses to create a
   TURN key until the account is subscribed.
2. At [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens), use
   **Create Custom Token** with three account permissions:

   | Permission | Why |
   | --- | --- |
   | **Cloudflare Calls (Edit)** | Creates the TURN key and mints relay credentials |
   | **Account Settings (Read)** | Lets setup find your account ID |
   | **Account Analytics (Read)** | The usage readout |

   Only the first is needed to relay. If your account lists **Cloudflare Realtime** instead of
   Cloudflare Calls, that is the same permission under its newer name.

   Set **Account Resources** to *Include* and pick the account you want. *All Accounts* works too,
   but grants the token more than this needs, and leaves the account ID ambiguous if you have more
   than one — setup then has to ask you for it.
3. Paste the token into Settings > Remote Co-Op > Relay and press **Set Up Relay**. OpenNOW finds your
   account ID and creates the TURN key itself.

### Does anything give you both?

A tunnel and a relay solve different layers, which is why they are usually two products: signaling is
HTTPS to *your machine*, so it wants a reverse proxy, while media is UDP between two peers through a
*third-party* box, which is a TURN server. Three ways to avoid running both:

**Tailscale, if your guest will install it.** It is the one option that genuinely covers both — the
guest reaches this Mac by tailnet address, and Tailscale's own DERP relay carries the traffic when
hole-punching fails. Free, no card, nothing to configure here at all.

Note that Funnel and DERP do not combine to cover a browser guest: Funnel gives reachability to
someone *without* Tailscale, DERP only relays for someone *with* it. A browser guest reached through
Funnel still needs a TURN relay if their network blocks a direct connection.

**One VPS, if you would rather your guests installed nothing.** A single box running
[coturn](https://github.com/coturn/coturn) alongside a tunnel terminator such as Caddy or frp fills
both roles, and pairs with the **coturn** relay provider above. Oracle's free tier covers it, as does
roughly $5/month anywhere.

**Cloudflare** is one vendor for both — `cloudflared` for the tunnel, Realtime for the relay — but
they remain two separate setups with two separate accounts' worth of configuration.

### Testing a relay

**Test Relay** in the Relay card asks the configured relay for a real allocation: it gathers ICE with
the transport policy restricted to `relay`, so any candidate that comes back was issued by the TURN
server itself. Nothing else proves the credentials — a wrong password, a URL with no TLS variant and
an unactivated account all look identical from the host's side, and the symptom is a session that
works for everyone except the one guest who needed the relay, on a network you cannot test from.

It reports which URL produced each candidate, so a relay that allocates only over `turn:` is called
out rather than passed: that relay still fails the guest on a filtering network, which is the guest
the relay exists for. A pass mentioning a `turns:` candidate is the one to look for.

### If Set Up Relay is refused

Cloudflare answers `POST /calls/turn_keys` with *"Authorization Failure: The authentication
credentials are not authorized to perform the request"* when the account is not subscribed to
Realtime — the same wording it uses for a genuinely unauthorized token, which is what makes it
misleading. Subscribing is step 1 above and costs nothing.

If it persists on a subscribed account, make the key by hand; it is identical, only the making of it
differs. Go to **Realtime > TURN** in the dashboard, create a key, and paste both halves into the
**TURN Key ID** and **TURN Key Token** fields. Cloudflare shows the token once, at creation, so copy
it then.

To confirm whether the refusal is Cloudflare's rather than OpenNOW's:

```sh
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/<account id>/calls/turn_keys" \
  -H "Authorization: Bearer <api token>" -H "Content-Type: application/json" \
  -d '{"name":"manual test"}'
```

A relay needs only the TURN key. The API token and account ID are for the usage readout, so a
hand-pasted key relays perfectly well with neither.

### If the account ID is not detected

Without Account Settings the account ID cannot be detected — `GET /accounts` is user-scoped, so a
token lacking it gets an empty list back rather than an error. Paste the ID into the Account ID field
instead; it is the hex string in your dashboard URL, `dash.cloudflare.com/<account id>`. Do the same
if the token can see several accounts, since setup cannot guess which one you mean.

Guests configure nothing. Both secrets stay in the host's keychain and are never sent anywhere; only
the short-lived credentials the TURN key mints, which expire on their own, travel with an invite.

Cloudflare uses two credentials that are not interchangeable, which the setup flow hides but is worth
knowing if you wire it up by hand: a **TURN key** (`uid` plus a bearer `key`) authenticates minting at
`rtc.live.cloudflare.com`, while a **Cloudflare API token** authenticates `api.cloudflare.com`, where
the TURN key is created and usage is read. Cloudflare reveals a TURN key's bearer token once, at
creation — listing keys does not return it — so pressing Set Up Relay again keeps the stored key
rather than stranding a new one on your account.

The relay is **added to** the ICE list, not substituted for it. A guest who can connect directly still
does — ICE prefers the cheaper candidate — so a relay costs bandwidth only for the guest who
genuinely needs it.

### Quota

Cloudflare includes **1,000 GB a month**, shared between Realtime's SFU and TURN, then $0.05/GB.
Roughly 200 hours of relayed 720p60 or 140 of 1080p60, and only relayed guests count against it.

Subscribing puts a card on file and **overage is billed automatically, with no warning at the
threshold** — which is what the usage readout in the Relay card is for. The pricing docs say only "a
free tier of 1,000 GB before any charges start" and name no reset period; the subscribe page is
where it is stated plainly, as "1,000GB / month free" on "a monthly usage-based model".

The Relay card reads month-to-date usage and estimates the hours left. That needs the **Account
Analytics** permission; without it Cloudflare answers with HTTP 200 and an error in the body, so the
row reports the permission rather than showing zero bytes used. Two caveats the UI repeats: the query
is calendar month-to-date, which need not match your billing cycle, and the allowance is shared with
the SFU, so the number is a floor rather than a bill.

Tailscale remains the option that costs nothing and runs nothing: its own DERP relay is the fallback
when hole-punching fails, and it is included.

## Quality and latency

The guest stream is a transcode, not a passthrough. The host decodes the seat's video, scales it to
the guest preset and re-encodes with hardware H264. That costs a generation of quality and a few
milliseconds, and it buys the thing that matters: the guest's link is decoupled from the seat's, so a
guest on a slow connection cannot drag the host's own picture down with them.

**A preset is a ceiling on size, not a shape.** The guest gets the seat's own aspect ratio scaled to
fit the preset, and their player letterboxes it if their window is a different shape. Nothing crops:
an ultrawide seat reaches an ultrawide guest whole, and a guest on a 16:9 screen sees bars rather than
a picture with its sides missing. OpenNOW never asks what shape the guest's window is, because a
window can be resized at any moment and re-encoding to chase it would cost a keyframe each time.

Presets run from 720p30 to 4K60, including 1080p120 and 1440p120. Settings > Remote Co-Op sets the
default for the session, and like every other Remote Co-Op setting it is frozen into the stream at
launch.

**Quality is per guest.** Each connected guest has a quality menu in the CO-OP panel of the stream HUD,
so a friend on Ethernet next door can be on 1440p120 while a friend on a hotel connection is on 720p30
in the same session. Guests left on *Session Default* follow the Settings value, including later
changes to it; a guest given an explicit preset keeps it. Changing a guest's quality takes effect
immediately and does not interrupt their picture — resolution, frame rate and bitrate are sender-side
in WebRTC, so there is no renegotiation.

**A guest can lower their own quality**, from the slider button in their window. They cannot raise it:
the picture is encoded and uploaded by the host, so raising it would spend someone else's bandwidth and
encoder. Anything above what the host allowed simply is not offered, and the host can put them back up
at any time.

### Why a guest may not be getting the preset you set

A preset is a **ceiling, not a promise**, and there are three separate reasons a guest sits below it.
The CO-OP panel shows what each guest is actually receiving, with the reason, under their name.

- **`source limit`** — the seat is not sending that much. The relay never upscales, so a 1440p session
  cannot produce a 4K guest however the preset is set.
- **A shorter picture than you expected** — the preset is a bounding box and aspect ratio is preserved.
  A 5120x2160 ultrawide session on the 4K preset delivers 3840x1620, which is the correct fit.
- **`network limited` / `encoder limited`** — libwebrtc downscaled. In Low Latency mode it is
  deliberately allowed to trade resolution away to hold the frame rate, so a link or a Mac that cannot
  keep up gives a smaller picture rather than a stuttering one. Quality mode makes the opposite trade.

Raising one guest costs the others nothing. Each guest has their own encoder, so nobody is capped by
the worst connection in the room. The one shared cost is the host scaling its decoded frame once for
everyone, which follows the most demanding guest — and that scale, along with the pixel format
conversion after it, is done once per frame no matter how many guests are watching.

**Latency mode** is the important one. *Low Latency* holds nothing back anywhere in the path:

- Guest gamepad state is sampled from the HID report itself, not polled on a timer, so a pad reporting
  at 1000 Hz is read 1000 times a second. A 200 Hz safety poll covers a lost packet or a driver that
  does not fire the callback.
- Input packets go out as a 62-byte binary frame instead of JSON, and the host routes each one the
  moment it arrives rather than buffering it.
- The encoder opens at three quarters of its cap instead of probing upward, because the receiver
  remembers the worst pacing delay it sees during a ramp and takes tens of seconds to forget it.

*Quality* raises the bitrate ceiling and is the better choice for someone watching rather than
playing.

Audio is stereo Opus at up to 256 kbit/s in 10 ms packets. libwebrtc's conversational defaults — mono,
~32 kbit/s, 20 ms packets — would lose the positional mix and add 10 ms for nothing.

To see what you are actually getting, click the gauge in the guest window. It shows route round-trip,
jitter buffer depth, decode time and decoded frame rate. Those four numbers separate a slow route from
a deep buffer from slow decoding from a host that is not sending frames, which nothing else can.

## Limits

- Three guests maximum — the seat's own limit.
- Guests need a controller.
- The session lives as long as the app does. There is no persistent room, so an invite link is only
  good while the stream is running.
- Reserved slots and every other Remote Co-Op setting are frozen into the stream at launch. Changes
  apply to the next stream, not the current one.
- A relay is optional and off unless a Cloudflare key is configured; without one, a guest on a network
  that filters UDP will not connect at all.

## Troubleshooting

The guest page has a diagnostics panel behind the **i** button, with a Copy button. It reports the
WebSocket state, host approval, the selected ICE route, inbound media stats, and whether input is
flowing. That is the first thing to read when something does not work.

Common cases:

- **"Press any button"** — the browser has not seen a controller yet. This is normal.
- **`controller not detected`, 0 input packets** — no gamepad is connected on the guest's machine.
- **Stuck on connecting, no selected route** — no network path was found. A guest on another network
  needs Tailscale, a tunnel, or a forwarded port.
- **Stuck on connecting from a school, library or cafe network** — that network is filtering UDP.
  Nothing on the host side fixes it; configure a relay key, or have the guest use Tailscale.
- **Certificate warning** — expected without a tunnel. Accepting it once per address is enough.
- **The host never appears in an OpenNOW guest's list** — discovery is multicast and does not cross a
  VPN or tunnel. Use **Or connect by address** with the address from the host's CO-OP panel.
- **Guest video is smooth but input feels late** — check the guest's gauge. A high round-trip is the
  route (over Tailscale, confirm you got a direct connection rather than a DERP relay); a high jitter
  buffer with a low round-trip means something upstream is delivering frames unevenly.

# Remote Co-Op without WebRTC — M0 spike runbook

M0 answers one question before any session, adaptation or NAT-traversal work:

> Can a native guest decode the host's **source** compressed video — the access unit the seat
> encoded — after it travels a UDP link, and how good and fast is it?

It is deliberately narrow: one-way (host → guest), plaintext, LAN only, no adaptation, no session,
no keyframe recovery. It is a measuring instrument, not the transport, and must not ship as one.

## What it does

```
seat ──NVST──▶ OpenNOW host
                 ├─ decodes locally (unchanged; the spike taps beside this)
                 └─ forwards to the spike destination (default 127.0.0.1:9000)
                        compressed access units → fragmenter → UDP
                                                     ▼
                                          OpenNOWBenchmarks coop-spike-guest
                                            reassemble → VideoToolbox decode → stats + PNG
```

The host forwards the **same `NativeNVSTVideoFrame` the decoder gets**, unmodified, so the guest
decodes the source stream rather than a re-encode of the decoded picture. The framing is
`OPNRemoteCoOpCompressedVideoTransport`; the host side is `OPNRemoteCoOpSpikeForwarder`.

## Run it

### Same Mac, from Xcode (no setup)

1. Start the guest in a terminal (first run builds the CLI, then it listens):

   ```sh
   swift run --scratch-path .build/shared OpenNOWBenchmarks coop-spike-guest --port 9000
   ```

2. Run the app from Xcode and start a stream. The host forwards to `127.0.0.1:9000` by default, so
   the guest prints a stats line every two seconds and writes PNGs to
   `$TMPDIR/opennow-coop-spike/`.

### Same Mac, in-app native guest window (no terminal)

Open **Stream ▸ Join Remote Co-Op as Native Guest…**, enter the port the host forwards to (default
`9000`), and click **Listen**. The window renders the forwarded source stream live through the
stream's own Metal surface and shows codec, resolution, fps, Mbps, decoded and missed counts. This
is the same `RemoteCoOpNativeGuestReceiver` the CLI runs, so the two cannot drift.

### Two Macs on a LAN

Point the host at the guest's address, either with the environment variable (launch the app binary
from the terminal so it inherits it — `open -a` does not carry your environment) or a one-line
`defaults` write:

```sh
defaults write io.github.opencloudgaming.opennow OpenNOW.CoOpSpikeForward -string "<mac-b-ip>:9000"
```

On the guest, run `coop-spike-guest --port 9000` as above.

## Reading the output

| Field | Meaning |
|---|---|
| `reassembled` | Access units delivered intact. Should track the source frame rate. |
| `decoded/window` | Frames VideoToolbox produced on the guest. |
| `2560x1440` | The **source** resolution the guest decoded — not a re-encode. |
| `Mbps` | Guest-side received bitrate; compare against the seat's stream bitrate. |
| `failures` | Decode failures. A few at startup before the first keyframe are expected. |

The PNGs are the visual check: they should match what the host sees, at full source resolution.

## M0 result (2026-09-24, one Mac, loopback)

**Proven: the guest decoded the host's source HEVC stream at 5120x2160, with zero decode failures.**

- Host: `frames=2031 dropped=0 datagrams=37215 bytes=44.9 MB`
- Guest: `decoded=1840 failures=0`, sustained 30–118 fps depending on content, 1.6–33.8 Mbps
- PNGs written at 5120x2160

Bugs found and fixed while getting here, each now covered by a test: a `Data.subdata(in:)` index
trap on sliced access units; the guest guessing H.264 against an HEVC seat; no keyframe for a
mid-stream join (the host now requests an IDR); and a stream restart looking like stale fragments
(the header now carries a session ID).

## Open items this spike does not cover

- **Adaptation** — a slow guest gets the whole stream or losses; there is no cap or transcode yet.
- **Keyframe-on-join** — a guest joining mid-stream waits for the next keyframe.
- **Recovery** — a lost fragment drops a frame; there is no NACK/FEC.
- **Security** — plaintext UDP; the real transport encrypts per guest.
- **Reachability** — LAN only; NAT traversal and relay are the decisive later milestone.

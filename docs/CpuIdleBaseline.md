# CPU baseline

Phase 0 of the performance epic (NEC-39) is a hard gate on every later change: without a recorded
CPU number, a Wave 3 "improvement" is unfalsifiable and a regression is invisible. This document is
that baseline. It records what the app measured on one named machine and one named build
configuration, and how to reproduce it.

## What is measured

The capture script lives in `scripts/profiling/`, next to the other measurement tooling rather than
with the build, release and codegen steps in `scripts/`. It is not in `Benchmarks/`: that directory
is a SwiftPM executable target (`swift run OpenNOWBenchmarks`), so a non-Swift file there needs an
`exclude` entry in `Package.swift` and would otherwise warn on every build.

`scripts/profiling/cpu-baseline.py` samples the process's cumulative `user + sys` CPU time once a second for a
fixed window and reports `cpu seconds / wall seconds` as a percentage. 100% is one saturated core;
a value above 100% means several threads' worth, which the stream state does reach.

CPU time comes from `ps -o cputime`, which is the same counter Activity Monitor and `top` show as
TIME. It reports centiseconds, so a 60 s window resolves to about 0.02%, and the whole capture needs
no sudo, no debugger and no Instruments trace.

Three states are captured, each from a fresh launch:

| State | On screen | Input |
|---|---|---|
| `catalog-idle` | the catalog, splash gone | none; the cursor is parked outside the app window |
| `catalog-scroll` | the catalog | 8 px per scroll event at 20 Hz (160 px/s) with the cursor at the window centre |
| `stream-idle` | a live GeForce NOW stream | none |

## Why `ps`, and not `powermetrics`, Instruments or `sample`

| Tool | Why not |
|---|---|
| `powermetrics` | needs root. A contributor-run script cannot ask for a password, and a sudo-gated baseline is one nobody re-runs. |
| Instruments (`xctrace`) | needs a recording round trip and an export pass to get a number out, and the UI templates need a grant the shell does not have. |
| `sample` | produces a call tree, not CPU accounting: idle threads are sampled too, so the sample count is elapsed time, not CPU time. |
| `top` | samples the same counter, but rounds the per-sample value to 0.1%. At idle that reads 0.0% for a process using 0.4%, which is exactly the signal this baseline exists to resolve. |
| `ps -o cputime` | the raw counter, 0.01 s resolution, no privilege, no extra install. |

`libproc`'s `proc_pid_rusage` would be the obvious in-process equivalent, but it does not report CPU
time correctly on this system: measured against `/usr/bin/time -l` on a busy loop that used 1.19 s of
user time, it returned 0.0 ms. `ps` agreed with `/usr/bin/time`. That is why the script shells out.

## Machine and build configuration

| | |
|---|---|
| Machine | Mac Studio (Mac14,14), Apple M2 Ultra, 24 cores (16P/8E), 64 GB unified memory |
| OS | macOS 27.0 (build 26A428) |
| Toolchain | Xcode 27.0 (27A266a), Apple Swift 6.4 |
| Tree | `1a5bc7cb` (the change that adds this document touches `scripts/profiling/` and `docs/` only) |
| Configuration | **Debug** |
| App | `OpenNOW Dev.app`, `io.github.opencloudgaming.opennow.dev` |
| App binary fingerprint | `1d67d34797f7692f`, built 2026-10-01T01:37:23Z |
| Display | 5120x2160, single display |
| App window | `x=1370 y=359 w=2197 h=1106`, never moved or resized |

The window geometry matters: the idle cursor anchor and the scroll anchor are both derived from it,
so a different window size moves the cursor to a different place over the same UI.

## Measured

Three runs per state, 60 s each, on the machine above. The reported number is the median of the
three; the per-second columns are medians of the per-second samples across the runs.

| State | CPU % | run range | CPU s (60 s) | per-second median | per-second p95 | per-second max | seconds above 1% |
|---|---|---|---|---|---|---|---|
| `catalog-idle` | **2.47** | 2.32 - 2.48 | 1.48 | 0.98 | 11.77 | 15.69 | 14/59 |
| `catalog-scroll` | **10.20** | 10.10 - 10.96 | 6.12 | 8.83 | 17.71 | 18.69 | 59/59 |
| `stream-idle` | **14.35** | single run | 8.61 | 12.84 | 29.61 | 101.31 | 60/60 |

An earlier capture of the two catalog states, taken ten minutes before this one on the same build,
read `catalog-idle` 2.38 (2.12 - 2.42) and `catalog-scroll` 9.50 (8.56 - 10.01). Both states
reproduce to within about 0.1 points of their medians, so a change of a few tenths is measurable and
a change of one point is well clear of the noise.

### What the numbers say

The idle catalog is not flat. Its per-second series sits at a 0.98% floor and spikes to about 11%
roughly every six seconds:

```
0.98  0.98  0.00  0.00  0.98  0.00  10.79  0.98  0.98  0.00  0.00  9.81  1.98  0.98  0.98  ...
```

The mean over 60 s therefore moves by a few tenths depending on how many spikes land inside it, which
is why this baseline reports a median of three runs and keeps the per-second series in the JSON
output. A change that removes a periodic wakeup shows up as a drop in the spike count and the
per-second p95 long before it moves the mean.

`stream-idle` is a different shape: sustained work with a median of 12.84%/s and one second above
100%, which is a 5120x2160 stream at a negotiated 120 fps. It is the largest CPU number the app
produces while nobody is touching it.

`catalog-scroll` at 10.2% is close to `stream-idle`, and every one of its 59 sampled seconds is above
1% - the catalog scroll never idles.

## Reproducing

```sh
scripts/profiling/cpu-baseline.py --state all --json /tmp/cpu-baseline.json
```

`--state catalog-idle,catalog-scroll` skips the stream state for a machine with no GeForce NOW
account. `--runs`, `--seconds`, `--settle` and the two scroll parameters are all flags; the values
above are the defaults except for `--runs`, which defaults to 3.

## How the states are controlled

A re-run is only comparable if the window, the cursor and the input are in the same place, so the
script fixes all three rather than asking the operator to.

- **Fresh launch, one process per run.** The app is launched with `open -a` and quit between runs.
  A run refuses to start while another `OpenNOW Dev` is already running.
- **Readiness is read from the app's own diagnostics log**, not from a sleep: `catalog-visible` for
  the two catalog states, `stream-connected` for the stream state. The script waits for the log to
  be cleared for this launch first, so a milestone left by the previous run cannot satisfy the gate.
- **The window is never moved or resized.** Its bounds are read with `CGWindowListCopyWindowInfo`
  and recorded in the report. The app is made frontmost before every window, because macOS throttles
  an occluded window and that would read as an improvement.
- **The cursor anchor is derived from those bounds.** `catalog-idle` parks the cursor 60 pt outside
  the window's top-left corner, so it cannot be over a tile or a rail; `catalog-scroll` parks it at
  the window's centre and posts scroll events there.
- **Input is synthetic CoreGraphics scroll events**, posted to the HID event tap at a fixed rate, so
  the scroll distance and speed are identical every run instead of depending on how someone flicks a
  trackpad. This needs Accessibility permission for the terminal running the script.
- **The settle is fixed at 30 s** after the state is ready. Ten seconds is not enough: the catalog is
  still decoding its first frame's worth of artwork, and the same state then reads 6.5% instead of
  2.5%. The launch burst is a real cost, but it belongs to a launch measurement, not this one.
- **A `caffeinate` assertion is held for the whole capture.** Without it the display sleeps after its
  idle timeout and a window that is no longer on screen stops taking scroll events: the scroll run
  then reports the idle catalog's CPU, which is worse than failing because it looks like a number.
- **A state that does not hold for the whole window is rejected, not reported.** The script checks
  the stream's teardown marker against the log position of its connect marker after the settle and
  again after the window, and drops the run if the session ended inside it.

## The `stream-idle` number is one run, not three

The seat ended the session about one second after connect on 9 of the 10 attempts made while
building this baseline, across two titles (Streets of Rage 4 `100688311`, Manor Lords `101729111`):

```
NVST native bundle seat terminated the session: 0x800e840f len=4
```

The app is behaving correctly here - it reports the seat's end and releases the session - and the
same build ran sessions of 1.5 to 40 minutes on 2026-09-29 and 2026-09-30. The refusal is an account
or service-side condition on this machine, not something the app or this script controls. The script
detects it and refuses to report a number rather than measuring a catalog and calling it a stream.

The 14.35% above is the one attempt that connected and stayed up for the whole settle plus window.
Re-run `scripts/profiling/cpu-baseline.py --state stream-idle --runs 3` when the seat accepts sessions again
and replace the row; the procedure is identical, so the numbers will be comparable.

## Caveats to carry into any comparison

- **Debug, not Release.** This is a named configuration and a valid like-for-like baseline, but it is
  not the shipping build. Release numbers will be lower; capture a Release baseline of its own before
  attributing a Wave 3 change.
- **These are single-process numbers.** The script measures the app, not the machine. It does not
  attribute CPU to threads, and it does not measure GPU or energy.
- **`catalog-scroll` measures one scroll rate.** 160 px/s at 20 Hz is a slow, steady scroll. A fast
  flick will read higher; a different rate is a different state and belongs in a row of its own.
- **`stream-idle` depends on what the seat negotiates.** The app requested 5120x2160 at 120 fps here;
  a session that negotiates 60 fps or a lower resolution will decode less and read lower. Record the
  negotiated profile alongside any stream number.
- **A run needs the catalog to be reachable.** A signed-out catalog is fine for the two catalog
  states, but a machine with no network reads lower still, because nothing is being fetched.

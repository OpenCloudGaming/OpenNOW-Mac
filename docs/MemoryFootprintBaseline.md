# Memory footprint baseline

Phase 0 of the performance epic (NEC-39) is a hard gate on every later change: without a recorded
footprint, a Wave 2 or Wave 3 "improvement" is unfalsifiable and a regression is invisible. This
document is that baseline. It records what the app measured on one named machine and one named build
configuration, and how to reproduce it.

## What is measured

`OPNMemoryFootprint.currentBytes()` (`OPN/Telemetry/OPNMemoryFootprint.swift`) reads
`task_vm_info.phys_footprint` with `task_info`. That is the number Activity Monitor reports and the
number the kernel enforces a memory limit against. The read is a single Mach call against a counter
the kernel already keeps: it allocates nothing, takes no lock and touches no file.

One milestone series is logged per launch, through the ordinary `OPNLog` path, so the numbers land in
the diagnostics log a user can already send:

```
[OPN][info][Memory] Memory footprint milestone=pre-main bytes=4260488 mib=4.1
```

| Milestone token | Taken at |
|---|---|
| `pre-main` | `OPNApp.init()`, the first statement after the diagnostics log is cleared for the run, and before Sentry is initialised |
| `first-frame` | `AppRootViewModel.bootstrapIfNeeded`, the root view's first task run - AppKit has built the window and SwiftUI has built the view tree, and the catalog bootstrap has not started |
| `catalog-visible` | `OPNStartupTrace.recordContentReady`, when the splash's hold ends with content |
| `stream-connected` | `NativeNVSTStreamingPath`, once the transport is running and the session is published |

## Machine and build configuration

| | |
|---|---|
| Machine | Mac Studio (Mac14,14), Apple M2 Ultra, 24 cores (16P/8E), 64 GB unified memory |
| OS | macOS 27.0 (build 26A428) |
| Toolchain | Xcode 27.0 (27A266a), Apple Swift 6.4 |
| Tree | `619abf5d` plus the NEC-40 sampler (the change that adds this document) |
| Configuration | **Debug** |
| Build | `xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug -destination 'platform=macOS,arch=arm64' build` |
| Product | `OpenNOW Dev.app` (`io.github.opencloudgaming.opennow.dev`) |
| Launch | `open` from an Aqua session, five consecutive launches, each quit before the next |

## Measured

Five consecutive launches on the machine above. Values are MiB; bytes are in the diagnostics log.

| Run | `pre-main` | `first-frame` | `catalog-visible` |
|---|---|---|---|
| 1 (first launch after the build) | 4.1 | 45.8 | 149.5 |
| 2 | 4.1 | 55.0 | 168.2 |
| 3 | 4.1 | 53.9 | 163.6 |
| 4 | 4.1 | 54.8 | 165.8 |
| 5 | 4.1 | 55.1 | 167.2 |
| **median** | **4.1** | **54.8** | **165.8** |
| **steady-state range (runs 2-5)** | - | 53.9 - 55.1 | 163.6 - 168.2 |

`stream-connected` is **not measured here**. It requires a live GFN session on this account, which
this baseline deliberately did not start.

Run 1 read ~9 MiB lower at `first-frame` than every later run. It was the first launch after the
build, so treat it as a cold-start outlier and the runs 2-5 range as the number to compare against.

## Reproducing

```sh
xcodebuild -project OpenNOW.xcodeproj -scheme OpenNOW -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-dd build
open ".build/xcode-dd/Build/Products/Debug/OpenNOW Dev.app"
grep "Memory footprint" ~/Library/Caches/OpenNOW/OpenNOW-diagnostics-current.log
```

The same lines are in the in-app diagnostics log (Settings -> Diagnostics), which is the copy a
support request carries.

To capture `stream-connected`, start a stream in that build and read the same file: the milestone is
logged when the native NVST transport connects, once per session.

## Caveats to carry into any comparison

- **Debug, not Release.** This is a named configuration and a valid like-for-like baseline, but it is
  not the shipping build. Release numbers will be lower; capture a Release baseline of its own before
  attributing a Wave 2 or Wave 3 change.
- **`catalog-visible` is network-bound.** It lands when the hero panel arrives, so it includes
  whatever artwork had decoded by then. On a cold catalog and image cache it reads higher, and on a
  slow network higher still. Compare it run-to-run on the same machine, not across machines.
- **`first-frame` is a boundary, not a timestamp.** It is taken at the root view's first task run,
  before the first frame's layout and render finish. It is stable enough to compare, not precise
  enough to reconcile against a signpost interval.
- **A menu-bar-only launch logs neither `first-frame` nor `catalog-visible`.** There is no window and
  no splash, so there is no first frame and nothing the splash holds for. Three milestones, not four.
- **A signed-out launch logs `catalog-visible` before `first-frame`.** `recordContentReady` fires
  immediately with `gate=notHeld` because the splash holds for nothing. The four numbers are still
  logged; the order is not the launch order.
- **The sampler adds no synchronous disk I/O.** The sample is one `task_info` call and the line rides
  `OPNLog`'s existing path, whose diagnostics-file append is already on its own async queue.

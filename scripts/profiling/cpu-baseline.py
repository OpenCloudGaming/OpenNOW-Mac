#!/usr/bin/env python3
"""Capture the app's CPU use over a fixed window in three reproducible states.

The states are the ones the performance epic compares against::

    catalog-idle    the catalog on screen, no input, the cursor parked off any tile
    catalog-scroll  the catalog on screen, scrolling continuously
    stream-idle     a live stream on screen, no input

Every run launches the app fresh, drives it into the state, waits for it to settle, then samples
the process's cumulative CPU time once a second for ``--seconds`` (60 by default). The headline
number is ``cpu seconds / wall seconds``, so 100% is one saturated core and a value above 100% is
several threads' worth. Each state is captured ``--runs`` times (3 by default) and reported as the
median of those runs, because the idle catalog is bursty: its mean over one 60 s window moves by a
few points depending on how many of its periodic spikes land inside it. The per-second series is in
the JSON output for the same reason - a mean alone hides a wakeup that recurs every few seconds.

CPU time is read from ``ps -o cputime``, the process's ``user + sys`` rusage counter, which is the
same number Activity Monitor and ``top`` show as TIME. Nothing here needs sudo or a debugger:
``powermetrics`` wants root, an Instruments trace needs a recording round trip and a grant, and
``sample`` produces a call tree rather than CPU accounting. ``ps`` reports centiseconds, so a 60 s
window resolves to about 0.02%.

Every number is only comparable against a run of the same build, on the same machine, with the
same window geometry. The report records the commit, the build configuration, the app binary
fingerprint, the display size, the app window's bounds, and the exact cursor anchor used.

Examples::

    scripts/profiling/cpu-baseline.py --state all
    scripts/profiling/cpu-baseline.py --state catalog-scroll --seconds 120 --runs 5
    scripts/profiling/cpu-baseline.py --state stream-idle --cms-id 101729111 --json /tmp/cpu.json

The capture holds a ``caffeinate`` assertion for its whole run. Without it the display sleeps after
its idle timeout and a window that is no longer on screen stops taking scroll events - a scroll run
then reports the idle catalog's CPU instead of a scroll's, which is worse than a failure because it
looks like a number.

Only ``stream-idle`` needs a signed-in GeForce NOW account and a launchable title; the two catalog
states run against a signed-out catalog as well. Requires Xcode (for the built app and ``ps``) and,
for synthetic input, Accessibility permission for the terminal running the script.

Lives under ``scripts/profiling/`` because it measures the app rather than building or shipping it:
``scripts/`` proper holds the build, release and codegen steps, and ``Benchmarks/`` is a SwiftPM
executable target that cannot take a non-Swift file without an ``exclude`` entry in ``Package.swift``.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

STATES = ("catalog-idle", "catalog-scroll", "stream-idle")

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DIAGNOSTICS_LOG = Path.home() / "Library/Caches/OpenNOW/OpenNOW-diagnostics-current.log"
DERIVED_DATA = Path.home() / "Library/Developer/Xcode/DerivedData"
AUTOPILOT_DIR = Path.home() / "Library/Logs/OpenNOW/autopilot"
APP_NAME = "OpenNOW Dev"

DEFAULT_SECONDS = 60
DEFAULT_RUNS = 3
DEFAULT_SETTLE_SECONDS = 30
DEFAULT_CATALOG_TIMEOUT = 90
DEFAULT_STREAM_TIMEOUT = 300
DEFAULT_SCROLL_PIXELS = 8
DEFAULT_SCROLL_HZ = 20

# Streets of Rage 4: small and quick to reach the picture, so a session is cheap to start.
DEFAULT_CMS_ID = "100688311"
DEFAULT_CMS_SHORT_NAME = "streets_of_rage_4_gfn_pc"

CATALOG_READY_MARKER = "milestone=catalog-visible"
STREAM_READY_MARKER = "milestone=stream-connected"
STREAM_END_MARKER = "nvst.stream.performance_mode.end"

UTF8 = 0x08000100
CF_NUMBER_INT = 3
WINDOW_LIST_ON_SCREEN = 1
WINDOW_LIST_EXCLUDE_DESKTOP = 16
SCROLL_UNIT_PIXEL = 0
HID_EVENT_TAP = 0


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGSize)]


class CoreGraphics:
    """The CoreGraphics calls the harness needs: window bounds, display size, and synthetic input."""

    def __init__(self) -> None:
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        void_p = ctypes.c_void_p
        self.cf.CFStringCreateWithCString.restype = void_p
        self.cf.CFStringCreateWithCString.argtypes = [void_p, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringGetCString.restype = ctypes.c_bool
        self.cf.CFStringGetCString.argtypes = [void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        self.cf.CFArrayGetCount.restype = ctypes.c_long
        self.cf.CFArrayGetCount.argtypes = [void_p]
        self.cf.CFArrayGetValueAtIndex.restype = void_p
        self.cf.CFArrayGetValueAtIndex.argtypes = [void_p, ctypes.c_long]
        self.cf.CFDictionaryGetValue.restype = void_p
        self.cf.CFDictionaryGetValue.argtypes = [void_p, void_p]
        self.cf.CFNumberGetValue.restype = ctypes.c_bool
        self.cf.CFNumberGetValue.argtypes = [void_p, ctypes.c_int, void_p]
        self.cf.CFRelease.argtypes = [void_p]
        self.cg.CGWindowListCopyWindowInfo.restype = void_p
        self.cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        self.cg.CGRectMakeWithDictionaryRepresentation.restype = ctypes.c_bool
        self.cg.CGRectMakeWithDictionaryRepresentation.argtypes = [void_p, ctypes.c_void_p]
        self.cg.CGMainDisplayID.restype = ctypes.c_uint32
        self.cg.CGMainDisplayID.argtypes = []
        self.cg.CGDisplayBounds.restype = CGRect
        self.cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
        self.cg.CGWarpMouseCursorPosition.restype = ctypes.c_int
        self.cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]
        self.cg.CGEventCreateScrollWheelEvent.restype = void_p
        self.cg.CGEventCreateScrollWheelEvent.argtypes = [void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32]
        self.cg.CGEventPost.argtypes = [ctypes.c_uint32, void_p]

    def _string(self, value: str) -> ctypes.c_void_p:
        return ctypes.c_void_p(self.cf.CFStringCreateWithCString(None, value.encode(), UTF8))

    def _text(self, reference: ctypes.c_void_p) -> str:
        if not reference:
            return ""
        buffer = ctypes.create_string_buffer(1024)
        if not self.cf.CFStringGetCString(reference, buffer, 1024, UTF8):
            return ""
        return buffer.value.decode("utf-8", "replace")

    def frontmost_window_bounds(self, pid: int) -> CGRect | None:
        """Bounds of the app's frontmost on-screen window, or None when it has none."""
        keys = {name: self._string(name) for name in ("kCGWindowOwnerPID", "kCGWindowBounds")}
        try:
            windows = self.cg.CGWindowListCopyWindowInfo(
                WINDOW_LIST_ON_SCREEN | WINDOW_LIST_EXCLUDE_DESKTOP, 0
            )
            if not windows:
                return None
            bounds = None
            for index in range(self.cf.CFArrayGetCount(windows)):
                window = self.cf.CFArrayGetValueAtIndex(windows, index)
                owner = ctypes.c_int(0)
                self.cf.CFNumberGetValue(
                    self.cf.CFDictionaryGetValue(window, keys["kCGWindowOwnerPID"]),
                    CF_NUMBER_INT,
                    ctypes.byref(owner),
                )
                if owner.value != pid:
                    continue
                rect = CGRect()
                if self.cg.CGRectMakeWithDictionaryRepresentation(
                    self.cf.CFDictionaryGetValue(window, keys["kCGWindowBounds"]), ctypes.byref(rect)
                ):
                    bounds = rect
                    break
            return bounds
        finally:
            for reference in keys.values():
                self.cf.CFRelease(reference)
            if windows:
                self.cf.CFRelease(windows)

    def main_display_bounds(self) -> CGRect:
        return self.cg.CGDisplayBounds(self.cg.CGMainDisplayID())

    def warp(self, point: CGPoint) -> None:
        self.cg.CGWarpMouseCursorPosition(point)

    def scroll(self, pixels: int) -> None:
        event = self.cg.CGEventCreateScrollWheelEvent(None, SCROLL_UNIT_PIXEL, 1, pixels)
        if not event:
            return
        self.cg.CGEventPost(HID_EVENT_TAP, event)
        self.cf.CFRelease(event)


def run(command: list[str], timeout: float = 30.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


def git_metadata() -> dict[str, object]:
    def git(*arguments: str) -> str:
        result = run(["git", "-C", str(REPO_ROOT), *arguments])
        return result.stdout.strip() if result.returncode == 0 else ""

    return {
        "commit": git("rev-parse", "HEAD"),
        "commit_short": git("rev-parse", "--short", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "subject": git("log", "-1", "--format=%s"),
        "dirty": bool(git("status", "--porcelain")),
    }


def find_app(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    elif os.environ.get("OPN_BASELINE_APP"):
        candidates.append(Path(os.environ["OPN_BASELINE_APP"]))
    else:
        # Newest binary wins: a Debug build keeps its code in the ``.debug.dylib`` beside the
        # launcher, and the bundle directory's own timestamp does not move when only that changes.
        candidates.extend(
            sorted(
                DERIVED_DATA.glob(f"OpenNOW-*/Build/Products/*/{APP_NAME}.app"),
                key=app_build_time,
                reverse=True,
            )
        )
        candidates.extend(sorted((REPO_ROOT / "build").glob(f"*/{APP_NAME}.app")))
    for candidate in candidates:
        executable = app_executable(candidate)
        if executable and executable.is_file() and executable.stat().st_size > 0:
            return candidate.resolve()
    searched = "\n  ".join(str(candidate) for candidate in candidates) or "(none)"
    raise SystemExit(
        f"{APP_NAME}.app not found. Build it and pass --app.\nSearched:\n  {searched}"
    )


def app_build_time(app: Path) -> float:
    macos_dir = app / "Contents/MacOS"
    if not macos_dir.is_dir():
        return 0.0
    return max((path.stat().st_mtime for path in macos_dir.iterdir() if path.is_file()), default=0.0)


def app_executable(app: Path) -> Path | None:
    plist = app / "Contents/Info.plist"
    name = None
    if plist.is_file():
        result = run(["plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", str(plist)])
        if result.returncode == 0:
            name = result.stdout.strip()
    return app / "Contents/MacOS" / (name or APP_NAME)


def app_metadata(app: Path) -> dict[str, object]:
    macos_dir = app / "Contents/MacOS"
    digest = hashlib.sha256()
    if macos_dir.is_dir():
        for binary in sorted(path for path in macos_dir.iterdir() if path.is_file()):
            digest.update(binary.name.encode())
            with binary.open("rb") as handle:
                for block in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(block)
    plist = app / "Contents/Info.plist"
    bundle_id = ""
    if plist.is_file():
        result = run(["plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", str(plist)])
        bundle_id = result.stdout.strip() if result.returncode == 0 else ""
    return {
        "path": str(app),
        "bundle_id": bundle_id,
        "configuration": app.parent.name,
        "binary_sha256_16": digest.hexdigest()[:16],
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(app_build_time(app))),
    }


def machine_metadata() -> dict[str, object]:
    def sysctl(name: str) -> str:
        result = run(["sysctl", "-n", name])
        return result.stdout.strip() if result.returncode == 0 else ""

    version = run(["sw_vers"]).stdout
    fields = dict(re.findall(r"^(\w+):\s*(.+)$", version, re.MULTILINE))
    return {
        "model": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "physical_cores": sysctl("hw.physicalcpu"),
        "memory_bytes": sysctl("hw.memsize"),
        "os": f"{fields.get('ProductName', '')} {fields.get('ProductVersion', '')} ({fields.get('BuildVersion', '')})",
        "toolchain": run(["xcodebuild", "-version"]).stdout.strip().replace("\n", ", "),
    }


def display_size(graphics: CoreGraphics) -> dict[str, int]:
    bounds = graphics.main_display_bounds()
    return {"width": int(bounds.size.width), "height": int(bounds.size.height)}


def app_pid() -> int | None:
    result = run(["pgrep", "-x", APP_NAME])
    pids = [int(value) for value in result.stdout.split()]
    return pids[0] if pids else None


def cpu_seconds(pid: int) -> float:
    """The process's cumulative user + sys CPU time in seconds, as ``ps`` reports it."""
    result = run(["ps", "-p", str(pid), "-o", "cputime="])
    text = result.stdout.strip()
    if result.returncode != 0 or not text:
        raise ProcessLookupError(f"process {pid} is gone")
    days = 0
    if "-" in text:
        days_text, text = text.split("-", 1)
        days = int(days_text)
    parts = [float(part) for part in text.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return days * 86400 + seconds


def diagnostics_log() -> str:
    if not DIAGNOSTICS_LOG.is_file():
        return ""
    try:
        return DIAGNOSTICS_LOG.read_text(errors="replace")
    except OSError:
        return ""


def first_log_line() -> str:
    return diagnostics_log().split("\n", 1)[0]


def wait_for_new_session(previous_first_line: str, timeout: float = 30.0) -> int:
    """Offset where this launch's log lines start.

    The app clears the diagnostics log as its first act, so a marker left by the previous run is
    still on disk when ``open`` returns. Waiting for the first line to change is what makes the
    readiness gate below mean *this* launch.
    """
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        if first_log_line() != previous_first_line:
            return 0
        time.sleep(0.2)
    raise TimeoutError("the diagnostics log was not cleared for this launch")


def wait_for_marker(marker: str, timeout: float, offset: int = 0) -> float:
    """Seconds until the diagnostics log carries the milestone, or raises on timeout."""
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        if marker in diagnostics_log()[offset:]:
            return time.monotonic() - started
        if app_pid() is None:
            raise RuntimeError(f"{APP_NAME} exited before reporting {marker}")
        time.sleep(0.5)
    raise TimeoutError(f"{marker} did not appear within {timeout:.0f}s")


def marker_end_offset(marker: str, offset: int = 0) -> int:
    """Where the log stands just after the last occurrence of ``marker``."""
    text = diagnostics_log()
    index = text.rfind(marker, offset)
    return index + len(marker) if index >= 0 else len(text)


def wait_for_window(graphics: CoreGraphics, pid: int, timeout: float = 30.0) -> CGRect:
    """The app's window, which AppKit creates a moment after the catalog reports ready."""
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        bounds = graphics.frontmost_window_bounds(pid)
        if bounds is not None:
            return bounds
        time.sleep(0.5)
    raise TimeoutError("the app has no on-screen window to pin the cursor against")


def sample(pid: int, seconds: float, interval: float = 1.0) -> dict[str, object]:
    """CPU time of ``pid`` sampled once a second for ``seconds``."""
    samples: list[tuple[float, float]] = [(0.0, cpu_seconds(pid))]
    started = time.monotonic()
    deadline = started + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(interval, remaining))
        samples.append((time.monotonic() - started, cpu_seconds(pid)))
    wall = time.monotonic() - started
    cpu = samples[-1][1] - samples[0][1]
    per_second = [
        (right[1] - left[1]) / (right[0] - left[0]) * 100
        for left, right in zip(samples, samples[1:])
        if right[0] > left[0]
    ]
    ordered = sorted(per_second)
    return {
        "wall_seconds": round(wall, 2),
        "cpu_seconds": round(cpu, 2),
        "cpu_percent": round(cpu / wall * 100, 2) if wall > 0 else None,
        "samples": len(per_second),
        "min_percent": round(ordered[0], 2) if ordered else None,
        "median_percent": round(statistics.median(ordered), 2) if ordered else None,
        "p95_percent": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 2) if ordered else None,
        "max_percent": round(ordered[-1], 2) if ordered else None,
        "seconds_above_1_percent": sum(1 for value in per_second if value > 1.0),
        "per_second_percent": [round(value, 2) for value in per_second],
    }


def quit_app(pid: int, timeout: float = 20.0) -> None:
    run(["osascript", "-e", f'tell application "{APP_NAME}" to quit'])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if app_pid() is None:
            return
        time.sleep(0.5)
    run(["kill", "-TERM", str(pid)])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if app_pid() is None:
            return
        time.sleep(0.5)
    raise RuntimeError(f"{APP_NAME} did not exit")


def launch(app: Path, environment: dict[str, str], arguments: list[str]) -> int:
    command = ["open", "-a", str(app)]
    for key, value in environment.items():
        command += ["--env", f"{key}={value}"]
    command += arguments
    result = run(command, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"open failed: {result.stderr.strip()}")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        pid = app_pid()
        if pid is not None:
            return pid
        time.sleep(0.5)
    raise RuntimeError(f"{APP_NAME} did not start")


def ensure_frontmost() -> bool:
    result = run(
        ["osascript", "-e", f'tell application "System Events" to set frontmost of first process whose name is "{APP_NAME}" to true']
    )
    if result.returncode != 0:
        return False
    time.sleep(0.5)
    result = run(
        ["osascript", "-e", 'tell application "System Events" to get name of first process whose frontmost is true']
    )
    return result.stdout.strip() == APP_NAME


def idle_anchor(bounds: CGRect) -> CGPoint:
    """A point outside the app window, so the cursor cannot be over a tile or a rail."""
    return CGPoint(bounds.origin.x - 60, bounds.origin.y - 60)


def scroll_anchor(bounds: CGRect) -> CGPoint:
    return CGPoint(
        bounds.origin.x + bounds.size.width / 2, bounds.origin.y + bounds.size.height / 2
    )


def capture_catalog_idle(
    graphics: CoreGraphics, pid: int, seconds: float, settle: float, bounds: CGRect
) -> dict[str, object]:
    anchor = idle_anchor(bounds)
    graphics.warp(anchor)
    time.sleep(settle)
    if not ensure_frontmost():
        raise RuntimeError("could not make the app frontmost; an occluded window is throttled")
    result = sample(pid, seconds)
    result["cursor_anchor"] = {"x": round(anchor.x, 1), "y": round(anchor.y, 1)}
    result["cursor_inside_window"] = False
    return result


def capture_catalog_scroll(
    graphics: CoreGraphics,
    pid: int,
    seconds: float,
    settle: float,
    bounds: CGRect,
    pixels: int,
    hz: float,
) -> dict[str, object]:
    """Scroll at a fixed rate from a thread while the main thread samples CPU time."""
    anchor = scroll_anchor(bounds)
    graphics.warp(anchor)
    time.sleep(settle)
    if not ensure_frontmost():
        raise RuntimeError("could not make the app frontmost; scroll events would go elsewhere")
    stop = threading.Event()
    events = [0]

    def drive() -> None:
        interval = 1.0 / hz
        due = time.monotonic()
        while not stop.is_set():
            graphics.scroll(pixels)
            events[0] += 1
            due += interval
            delay = due - time.monotonic()
            if delay > 0:
                stop.wait(delay)
            else:
                due = time.monotonic()

    driver = threading.Thread(target=drive, daemon=True)
    driver.start()
    try:
        result = sample(pid, seconds)
    finally:
        stop.set()
        driver.join(timeout=5)
    result["scroll_events"] = events[0]
    result["scroll_pixels_per_second"] = pixels * hz
    result["cursor_anchor"] = {"x": round(anchor.x, 1), "y": round(anchor.y, 1)}
    result["cursor_inside_window"] = True
    return result


def capture_stream_idle(
    app: Path,
    seconds: float,
    settle: float,
    timeout: float,
    cms_id: str,
    short_name: str,
) -> dict[str, object]:
    AUTOPILOT_DIR.mkdir(parents=True, exist_ok=True)
    shortcut = AUTOPILOT_DIR / f"cpu-baseline-{short_name}.gfnpc"
    shortcut.write_text(
        json.dumps(
            {
                "url-route": (
                    f"#?cmsId={cms_id}&launchSource=External"
                    f"&shortName={short_name}&parentGameId={short_name}"
                )
            }
        )
    )
    previous_first_line = first_log_line()
    pid = launch(
        app,
        {
            "OPN_NVST_AUTOPILOT_SECONDS": str(int(settle + seconds + 30)),
            "OPN_NVST_AUTOPILOT_SNAPSHOT_DIR": str(AUTOPILOT_DIR),
        },
        [str(shortcut)],
    )
    offset = wait_for_new_session(previous_first_line)
    connect_seconds = wait_for_marker(STREAM_READY_MARKER, timeout, offset)
    # Anchored to the connect marker, not to the log length: a seat can end the session in the same
    # second it connects, and then the teardown line is already on disk when the wait returns.
    connected_at = marker_end_offset(STREAM_READY_MARKER, offset)
    time.sleep(settle)
    if STREAM_END_MARKER in diagnostics_log()[connected_at:]:
        raise RuntimeError("the stream ended before the measurement window opened")
    result = sample(pid, seconds)
    if STREAM_END_MARKER in diagnostics_log()[connected_at:]:
        raise RuntimeError(
            "the stream ended inside the measurement window, so the sample is not in-stream idle"
        )
    result["connect_seconds"] = round(connect_seconds, 1)
    # The autopilot ends the stream itself shortly after the window closes, which releases the seat
    # the way the End Stream button does. Quitting mid-stream would not.
    if not wait_for_exit(90):
        quit_app(pid)
    return result


def wait_for_exit(timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if app_pid() is None:
            return True
        time.sleep(1)
    return False


def capture_state(
    state: str, arguments: argparse.Namespace, graphics: CoreGraphics, app: Path
) -> tuple[dict[str, object], str | None]:
    """Launch the app, drive it into ``state``, sample one window. Returns the sample and the window."""
    if state == "stream-idle":
        outcome = capture_stream_idle(
            app, arguments.seconds, arguments.settle, arguments.stream_timeout,
            arguments.cms_id, arguments.short_name,
        )
        outcome["input"] = "none; OPN_NVST_AUTOPILOT_* starts the stream so nobody touches the keyboard"
        outcome["window_control"] = "autopilot activates the app; the stream fills the display it opens on"
        return outcome, None
    previous_first_line = first_log_line()
    pid = launch(app, {}, [])
    offset = wait_for_new_session(previous_first_line)
    wait_for_marker(CATALOG_READY_MARKER, arguments.catalog_timeout, offset)
    bounds = wait_for_window(graphics, pid)
    window = (
        f"x={bounds.origin.x:.0f} y={bounds.origin.y:.0f} "
        f"w={bounds.size.width:.0f} h={bounds.size.height:.0f}"
    )
    if state == "catalog-idle":
        outcome = capture_catalog_idle(graphics, pid, arguments.seconds, arguments.settle, bounds)
        outcome["input"] = (
            f"none; cursor warped to ({outcome['cursor_anchor']['x']}, "
            f"{outcome['cursor_anchor']['y']}), outside the window"
        )
    else:
        outcome = capture_catalog_scroll(
            graphics, pid, arguments.seconds, arguments.settle, bounds,
            arguments.scroll_pixels, arguments.scroll_hz,
        )
        rate = arguments.scroll_pixels * arguments.scroll_hz
        outcome["input"] = (
            f"{arguments.scroll_pixels} px per event at {arguments.scroll_hz:g} Hz "
            f"({rate:g} px/s) with the cursor at the window centre"
        )
    outcome["window_control"] = "fresh launch, window never moved or resized, app frontmost"
    if state == "catalog-scroll" and not ensure_frontmost():
        raise RuntimeError("the app lost focus during the scroll; the sample is not comparable")
    return outcome, window


def summarise_runs(runs: list[dict[str, object]]) -> dict[str, object]:
    def median(key: str) -> float | None:
        values = [run[key] for run in runs if run.get(key) is not None]
        return round(statistics.median(values), 2) if values else None

    means = [run["cpu_percent"] for run in runs]
    return {
        "runs": runs,
        "cpu_percent": round(statistics.median(means), 2),
        "cpu_percent_range": [min(means), max(means)],
        "median_percent": median("median_percent"),
        "p95_percent": median("p95_percent"),
        "max_percent": median("max_percent"),
        "min_percent": median("min_percent"),
        "cpu_seconds": median("cpu_seconds"),
        "wall_seconds": median("wall_seconds"),
        "seconds_above_1_percent": median("seconds_above_1_percent"),
        "samples": median("samples"),
        "input": runs[0]["input"],
        "window_control": runs[0]["window_control"],
    }


def format_report(report: dict[str, object]) -> str:
    git = report["git"]
    app = report["app"]
    machine = report["machine"]
    lines = [
        f"# CPU baseline capture started {report.get('started_at', report['captured_at'])}"
        f", finished {report['captured_at']}",
        "",
        "| | |",
        "|---|---|",
        f"| Tree | `{git['commit_short']}` ({git['branch']})"
        f"{' + uncommitted changes' if git['dirty'] else ''} |",
        f"| Commit subject | {git['subject']} |",
        f"| App | `{app['path']}` |",
        f"| Configuration | {app['configuration']} (`{app['bundle_id']}`) |",
        f"| Binary fingerprint | `{app['binary_sha256_16']}`, built {app['built_at']} |",
        f"| Machine | {machine['model']}, {machine['chip']}, {machine['physical_cores']} cores |",
        f"| OS | {machine['os']} |",
        f"| Toolchain | {machine['toolchain']} |",
        f"| Display | {report.get('display', {}).get('width', '?')}x{report.get('display', {}).get('height', '?')} |",
        f"| Window | {report.get('window', 'not found')} |",
        f"| Window seconds | {report['seconds']} |",
        f"| Settle seconds | {report['settle']} |",
        f"| Runs per state | {report['runs']} |",
        "",
        "| State | CPU % (median of runs) | run range | per-second median | per-second p95 | "
        "per-second max | s > 1% |",
        "|---|---|---|---|---|---|---|",
    ]
    for state, outcome in report["states"].items():
        if "error" in outcome:
            lines.append(f"| {state} | FAILED: {outcome['error']} | | | | | |")
            continue
        low, high = outcome["cpu_percent_range"]
        lines.append(
            f"| {state} | {outcome['cpu_percent']} | {low} - {high} | {outcome['median_percent']} | "
            f"{outcome['p95_percent']} | {outcome['max_percent']} | "
            f"{outcome['seconds_above_1_percent']}/{outcome['samples']} |"
        )
    if report["runs"] > 1:
        lines += ["", "| State | run | CPU % | CPU s | median/s | p95/s | max/s | s > 1% |", "|---|---|---|---|---|---|---|---|"]
        for state, outcome in report["states"].items():
            for index, run in enumerate(outcome.get("runs", [])):
                lines.append(
                    f"| {state} | {index + 1} | {run['cpu_percent']} | {run['cpu_seconds']} | "
                    f"{run['median_percent']} | {run['p95_percent']} | {run['max_percent']} | "
                    f"{run['seconds_above_1_percent']}/{run['samples']} |"
                )
    lines += ["", "| State | Input |", "|---|---|"]
    for state, outcome in report["states"].items():
        if "error" in outcome:
            continue
        lines.append(f"| {state} | {outcome.get('input', '')} |")
    lines.append("")
    return "\n".join(lines)


def parse_states(values: list[str]) -> list[str]:
    states: list[str] = []
    for value in values:
        for part in value.split(","):
            part = part.strip()
            if not part:
                continue
            if part == "all":
                states.extend(STATES)
            elif part in STATES:
                states.append(part)
            else:
                raise SystemExit(f"unknown state '{part}'; choose from {', '.join(STATES)}, all")
    ordered: list[str] = []
    for state in STATES:
        if state in states and state not in ordered:
            ordered.append(state)
    return ordered


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture the app's CPU over a fixed window in the catalog and stream states.",
        epilog="See the module docstring in this file for the procedure and the tooling rationale.",
    )
    parser.add_argument("--state", action="append", default=[], metavar="STATE",
                        help=f"comma-separated: {', '.join(STATES)}, all (default: all)")
    parser.add_argument("--seconds", type=float, default=DEFAULT_SECONDS,
                        help=f"measurement window per state (default: {DEFAULT_SECONDS})")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS,
                        help=f"fresh launches per state; the reported CPU %% is the median of the "
                             f"runs that produced a number (default: {DEFAULT_RUNS})")
    parser.add_argument("--settle", type=float, default=DEFAULT_SETTLE_SECONDS,
                        help=f"seconds to let the state settle before sampling (default: {DEFAULT_SETTLE_SECONDS})")
    parser.add_argument("--app", help="path to the built .app (default: newest Debug build)")
    parser.add_argument("--cms-id", default=DEFAULT_CMS_ID, help="GFN title for stream-idle")
    parser.add_argument("--short-name", default=DEFAULT_CMS_SHORT_NAME, help="GFN short name for stream-idle")
    parser.add_argument("--stream-timeout", type=float, default=DEFAULT_STREAM_TIMEOUT,
                        help=f"seconds to wait for the stream to connect (default: {DEFAULT_STREAM_TIMEOUT})")
    parser.add_argument("--catalog-timeout", type=float, default=DEFAULT_CATALOG_TIMEOUT,
                        help=f"seconds to wait for the catalog to be ready (default: {DEFAULT_CATALOG_TIMEOUT})")
    parser.add_argument("--scroll-pixels", type=int, default=DEFAULT_SCROLL_PIXELS,
                        help=f"pixels per scroll event (default: {DEFAULT_SCROLL_PIXELS})")
    parser.add_argument("--scroll-hz", type=float, default=DEFAULT_SCROLL_HZ,
                        help=f"scroll events per second (default: {DEFAULT_SCROLL_HZ})")
    parser.add_argument("--json", help="also write the report as JSON to this path")
    parser.add_argument("--keep-running", action="store_true",
                        help="leave the app running after the last state")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    states = parse_states(arguments.state) or list(STATES)
    app = find_app(arguments.app)
    graphics = CoreGraphics()
    keep_awake = subprocess.Popen(
        ["caffeinate", "-d", "-i", "-w", str(os.getpid())],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    report: dict[str, object] = {
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "git": git_metadata(),
        "app": app_metadata(app),
        "machine": machine_metadata(),
        "display": display_size(graphics),
        "seconds": arguments.seconds,
        "settle": arguments.settle,
        "runs": arguments.runs,
        "states": {},
    }
    report["started_at"] = report["captured_at"]
    failures = 0
    for state in states:
        print(f"== {state}: up to {arguments.runs} run(s) of {arguments.seconds:g}s", file=sys.stderr)
        completed: list[dict[str, object]] = []
        error_message = ""
        for index in range(arguments.runs):
            running = app_pid()
            if running is not None:
                quit_app(running)
            try:
                outcome, window = capture_state(state, arguments, graphics, app)
            except (RuntimeError, TimeoutError, ProcessLookupError) as error:
                # An attempt, not a sample: a seat that refuses the session is transient, so the
                # remaining attempts are still spent. The last error is reported if none succeed.
                error_message = str(error)
                print(f"   attempt {index + 1}: failed: {error}", file=sys.stderr)
                continue
            finally:
                running = app_pid()
                if running is not None and not arguments.keep_running:
                    quit_app(running)
            completed.append(outcome)
            if window:
                report["window"] = window
            print(
                f"   run {index + 1}/{arguments.runs}: {outcome['cpu_percent']}% over "
                f"{outcome['wall_seconds']}s (per-second median {outcome['median_percent']}%, "
                f"max {outcome['max_percent']}%)",
                file=sys.stderr,
            )
        if completed:
            report["states"][state] = summarise_runs(completed)
        else:
            failures += 1
            report["states"][state] = {"error": error_message or "no run completed"}
    report["captured_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    keep_awake.terminate()
    if arguments.json:
        Path(arguments.json).write_text(json.dumps(report, indent=2) + "\n")
    print(format_report(report))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

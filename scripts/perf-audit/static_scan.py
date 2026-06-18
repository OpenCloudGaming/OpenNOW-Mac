#!/usr/bin/env python3

import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = [
    "OpenNOW",
    "GFN.CloudMatch",
    "GFN.GDN",
    "GFN.Jarvis",
    "GFN.LCARS",
    "GFN.NesAuth",
    "GFN.NetworkTest",
    "GFN.Ragnarok",
    "GFN.Starfleet",
    "GFN.UDS",
    "OPN.Auth",
    "OPN.Common",
    "OPN.GameServices",
    "OPN.SignalLinkKit",
    "OPN.Telemetry",
    "OPN.WebRTC.Media",
]

PATTERNS = {
    "swiftui_body": r"body:\s+some\s+View",
    "published_state": r"@Published",
    "main_dispatch": r"DispatchQueue\.main\.(async|sync|asyncAfter)",
    "main_sync": r"DispatchQueue\.main\.sync",
    "json_decoder": r"JSONDecoder\(",
    "json_encoder": r"JSONEncoder\(",
    "json_serialization": r"JSONSerialization",
    "disk_read": r"contentsOf:|Data\(contentsOf:",
    "image_disk_read": r"NSImage\(contentsOf:",
    "timer": r"Timer\(|DispatchSource\.makeTimerSource|TimelineView|CADisplayLink",
    "repeat_animation": r"repeatForever|\.animation\(|withAnimation\(",
    "geometry_reader": r"GeometryReader",
    "task_modifier": r"\.task\(",
    "url_session": r"URLSession\.shared\.dataTask",
}

def scan_package(package: str) -> dict:
    base = ROOT / package
    files = [path for path in base.rglob("*.swift") if ".build" not in path.parts and "Tests" not in path.parts]
    counts = defaultdict(int)
    samples = defaultdict(list)
    line_count = 0
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        for index, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
            line_count += 1
            for name, pattern in PATTERNS.items():
                if re.search(pattern, line):
                    counts[name] += 1
                    if len(samples[name]) < 12:
                        samples[name].append({"file": relative, "line": index, "text": line.strip()})
    return {
        "package": package,
        "swiftFiles": len(files),
        "swiftLines": line_count,
        "counts": dict(sorted(counts.items())),
        "samples": {key: value for key, value in sorted(samples.items())},
    }

def main() -> None:
    output = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "packages": [scan_package(package) for package in PACKAGES],
    }
    print(json.dumps(output, indent=2, sort_keys=True))

if __name__ == "__main__":
    main()

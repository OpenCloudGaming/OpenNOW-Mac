#!/usr/bin/env python3
"""Summarize sanitized OpenNOW protocol captures for parity validation."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


KNOWN_NATIVE_RELEVANT_KEYS = {
    "accountLinked",
    "adMediaFiles",
    "adState",
    "appId",
    "availableBandwidthKbps",
    "availableBandwidthMbps",
    "availableSupportedControllers",
    "bandwidthKbps",
    "bandwidthMbps",
    "bitDepth",
    "blockLaunch",
    "chromaFormat",
    "clientDisplayHdrCapabilities",
    "clientMeasuredLatencyMs",
    "clientRequestMonitorSettings",
    "continueAllowed",
    "continueRecommended",
    "displayData",
    "downloadBandwidthKbps",
    "downloadBandwidthMbps",
    "enableAV1",
    "enableHDR",
    "enableH265",
    "enableHevc",
    "enableL4S",
    "enableReflex",
    "enabledL4S",
    "failLaunch",
    "gracePeriodSeconds",
    "gpuName",
    "gpuType",
    "hdrEnabled",
    "hdrSupported",
    "isAdsRequired",
    "jitter",
    "jitterMs",
    "latencyMs",
    "maxBitrateKbps",
    "maxBitrateMbps",
    "measuredBandwidthKbps",
    "measuredBandwidthMbps",
    "message",
    "monitorId",
    "networkJitterMs",
    "networkLatencyMs",
    "networkTestRequestData",
    "networkTestSessionId",
    "networkType",
    "packetLoss",
    "packetLossPercent",
    "packetLossPercentage",
    "queuePaused",
    "queuePosition",
    "recommendedBitrateKbps",
    "recommendedBitrateMbps",
    "recommendedMaxBitrateKbps",
    "recommendedMaxBitrateMbps",
    "remoteControllersBitmap",
    "requestStatus",
    "requestedMaxBitrateKbps",
    "requestedStreamingFeatures",
    "result",
    "rttMs",
    "sdrHdrMode",
    "seatSetupInfo",
    "seatSetupStep",
    "session",
    "sessionAds",
    "sessionAdsRequired",
    "sessionProgress",
    "sessionRequestData",
    "shouldContinue",
    "shouldWarn",
    "state",
    "status",
    "statusCode",
    "statusDescription",
    "stopLaunch",
    "streamMaxBitrateKbps",
    "streamMaxBitrateMbps",
    "supportedHdrModes",
    "ttlSeconds",
    "trueHdr",
    "trueHdrEnabled",
    "warning",
    "warningDescription",
    "warningMessage",
}

SENSITIVE_KEY_RE = re.compile(
    r"(token|secret|password|credential|device.*id|devicehashid|userid|clientid|sessionid|subsessionid|serverip|signaling|sdp|candidate|authorization|cookie|email)",
    re.IGNORECASE,
)


def value_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int) and not isinstance(value, bool):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "redacted-string" if value == "<redacted>" else "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def flatten(value: Any, prefix: str = "") -> dict[str, set[str]]:
    paths: dict[str, set[str]] = {}
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            path = f"{prefix}.{key_text}" if prefix else key_text
            paths.setdefault(path, set()).add(value_type(child))
            for child_path, child_types in flatten(child, path).items():
                paths.setdefault(child_path, set()).update(child_types)
    elif isinstance(value, list):
        path = f"{prefix}[]" if prefix else "[]"
        paths.setdefault(path, set()).add("array")
        for child in value:
            for child_path, child_types in flatten(child, path).items():
                paths.setdefault(child_path, set()).update(child_types)
    return paths


def basename_key(path: str) -> str:
    cleaned = path.replace("[]", "")
    return cleaned.rsplit(".", 1)[-1]


def label_from_filename(path: Path) -> str:
    stem = path.stem
    match = re.match(r"\d{8}-\d{6}-\d{3}-\d{6}-(.+)", stem)
    return match.group(1) if match else stem


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def analyze_directory(directory: Path) -> int:
    files = sorted(directory.glob("*.json"))
    if not files:
        print(f"No JSON captures found in {directory}", file=sys.stderr)
        return 1

    exit_code = 0
    for file_path in files:
        try:
            payload = load_json(file_path)
        except json.JSONDecodeError as error:
            print(f"{file_path.name}: invalid JSON: {error}", file=sys.stderr)
            exit_code = 1
            continue

        paths = flatten(payload)
        unknown_native_candidates = [
            path for path in sorted(paths)
            if basename_key(path) not in KNOWN_NATIVE_RELEVANT_KEYS and not SENSITIVE_KEY_RE.search(basename_key(path))
        ]
        redacted_paths = [path for path in sorted(paths) if "redacted-string" in paths[path]]

        print(f"Capture: {file_path.name}")
        print(f"  label: {label_from_filename(file_path)}")
        print(f"  key_paths: {len(paths)}")
        print(f"  redacted_paths: {len(redacted_paths)}")
        if redacted_paths:
            print("  redacted:")
            for path in redacted_paths:
                print(f"    - {path}")
        if unknown_native_candidates:
            print("  review_candidates:")
            for path in unknown_native_candidates:
                types = ",".join(sorted(paths[path]))
                print(f"    - {path} ({types})")
        else:
            print("  review_candidates: none")
    return exit_code


def run_self_test() -> int:
    sample = {
        "sessionRequestData": {
            "networkTestSessionId": "<redacted>",
            "requestedStreamingFeatures": {"trueHdr": True},
            "newNativeField": 12,
        }
    }
    paths = flatten(sample)
    if "sessionRequestData.networkTestSessionId" not in paths:
        return 1
    candidates = [path for path in paths if basename_key(path) not in KNOWN_NATIVE_RELEVANT_KEYS and not SENSITIVE_KEY_RE.search(basename_key(path))]
    if "sessionRequestData.newNativeField" not in candidates:
        return 1
    if "sessionRequestData.networkTestSessionId" in candidates:
        return 1
    print("self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize sanitized OpenNOW protocol captures.")
    parser.add_argument("capture_dir", nargs="?", type=Path, help="Directory created by OPN_PROTOCOL_CAPTURE_DIR")
    parser.add_argument("--self-test", action="store_true", help="Run analyzer self-test")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if not args.capture_dir:
        parser.error("capture_dir is required unless --self-test is used")
    if not args.capture_dir.is_dir():
        print(f"Capture directory does not exist: {args.capture_dir}", file=sys.stderr)
        return 1
    return analyze_directory(args.capture_dir)


if __name__ == "__main__":
    raise SystemExit(main())

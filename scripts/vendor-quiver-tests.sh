#!/usr/bin/env bash
#
# Runs upstream Quiver's own test suite against the patched sources in
# Vendor/Quiver/Sources. Upstream's Tests/ tree is deliberately not committed
# here; this borrows it from a pristine clone so our patches are exercised by
# upstream's coverage at no repository cost.
#
# Usage: scripts/vendor-quiver-tests.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor/Quiver"
UPSTREAM_URL="https://github.com/hironichu/quiver.git"
PIN="d3b0cdc56b57775adebd771558245913b4a7e728"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$UPSTREAM_URL" "$WORK/quiver"
git -C "$WORK/quiver" checkout --quiet "$PIN"

rm -rf "$WORK/quiver/Sources"
cp -R "$VENDOR_DIR/Sources" "$WORK/quiver/Sources"

# The QUICBenchmarks target asserts throughput thresholds that vary by machine;
# this harness covers upstream's functional suites only.
swift test --package-path "$WORK/quiver" --scratch-path "$WORK/.build" --skip 'Benchmarks'

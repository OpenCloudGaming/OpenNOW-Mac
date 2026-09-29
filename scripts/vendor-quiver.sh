#!/usr/bin/env bash
#
# Rebuilds Vendor/Quiver from the pinned upstream commit plus the committed
# patch series in Vendor/Quiver/Patches, then fails if the result differs from
# the tree in this repository. Provenance and the patch list live in
# Vendor/Quiver/VENDORING.md.
#
# Usage: scripts/vendor-quiver.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor/Quiver"
UPSTREAM_URL="https://github.com/hironichu/quiver.git"
PIN="d3b0cdc56b57775adebd771558245913b4a7e728"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$UPSTREAM_URL" "$WORK/quiver"
git -C "$WORK/quiver" checkout --quiet "$PIN"

# Documentation and non-library trees are stripped from the vendored copy by
# the recipe; the committed patches carry every source change.
rm -rf \
    "$WORK/quiver/Tests" \
    "$WORK/quiver/Examples" \
    "$WORK/quiver/Benchmarks" \
    "$WORK/quiver/Docs" \
    "$WORK/quiver/assets" \
    "$WORK/quiver/certs" \
    "$WORK/quiver/README.md" \
    "$WORK/quiver/RFC_COMPLIANCE.md"
find "$WORK/quiver/Sources" -type d -name '*.docc' -prune -exec rm -rf {} +
rm -f "$WORK/quiver/Sources/QUICCrypto/TLS/TLS_SECURITY.md"

for patch in "$VENDOR_DIR"/Patches/*.patch; do
    git -C "$WORK/quiver" apply --whitespace=nowarn "$patch"
done

status=0
diff -r "$WORK/quiver/Sources" "$VENDOR_DIR/Sources" || status=1
diff -u "$WORK/quiver/Package.swift" "$VENDOR_DIR/Package.swift" || status=1
diff -u "$WORK/quiver/LICENSE" "$VENDOR_DIR/LICENSE" || status=1

if [ "$status" -ne 0 ]; then
    echo "Vendor/Quiver does not match the pinned commit plus the committed patch series." >&2
    echo "Record every vendor change as a patch in Vendor/Quiver/Patches." >&2
    exit 1
fi

echo "Vendor/Quiver matches the pinned commit plus the committed patch series."

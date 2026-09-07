#!/usr/bin/env bash
# Provisions Vendor/WebRTC.xcframework from the published OpenNOW WebRTC artifact.
#
# The artifact is the stasel/WebRTC 152.0.0 release xcframework (built by the open-source
# stasel/WebRTC GitHub Actions pipeline from official WebRTC source, unmodified) with one
# header overlay: the upstream sdk/objc/components/audio/RTCAudioDevice.h, which stock
# stasel distributions omit even though the binary implements the ObjC audio device layer.
#
# Integrity chain: GitHub release tag -> SHA-256 below -> unpacked framework. Re-verify the
# checksum against the release page when bumping WebRTC and update THIRD_PARTY_NOTICES.md.
set -euo pipefail

ARTIFACT_URL="https://github.com/OpenCloudGaming/openNOW-Mac/releases/download/webrtc-m152-opnow.1/WebRTC-M152-opnow.xcframework.zip"
EXPECTED_SHA256="de20898c4b17b190829a4536d472b51c35507e51a24170d2c89b9cdbf2d3c85e"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_DIR="$ROOT/Vendor/WebRTC.xcframework"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -d "$FRAMEWORK_DIR" ]; then
    echo "Vendor/WebRTC.xcframework already present; delete it to re-fetch."
    exit 0
fi

echo "Fetching WebRTC xcframework..."
curl -fL --retry 3 -o "$TMP/webrtc.xcframework.zip" "$ARTIFACT_URL"

echo "Verifying SHA-256..."
echo "$EXPECTED_SHA256  $TMP/webrtc.xcframework.zip" | shasum -a 256 -c -

echo "Unpacking..."
mkdir -p "$ROOT/Vendor"
unzip -q "$TMP/webrtc.xcframework.zip" -d "$ROOT/Vendor/"

# stasel releases ship unsigned. Ad-hoc sign every slice so Xcode's embed phase and the
# final app codesign accept the framework. Apple-slice frameworks are versioned and sign
# at Versions/A; iOS slices are flat and sign at the bundle root.
echo "Ad-hoc signing slices..."
while IFS= read -r -d '' framework; do
    if [ -d "$framework/Versions/A" ]; then
        codesign --force --sign - "$framework/Versions/A"
    else
        codesign --force --sign - "$framework"
    fi
done < <(find "$FRAMEWORK_DIR" -name "WebRTC.framework" -print0)

echo "Provisioned $FRAMEWORK_DIR"

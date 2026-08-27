#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: $0 <path/to/OpenNOW.app> [output.dmg]}"
OUTPUT_DMG="${2:-OpenNOW.dmg}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKGROUND_PNG="${SCRIPT_DIR}/../Resources/OpenNOW/dmg-background.png"
VOLNAME="OpenNOW"
TMP_DIR="$(mktemp -d -t opennow-dmg)"
STAGING="${TMP_DIR}/staging"
RAW_DMG="${TMP_DIR}/OpenNOW_raw.dmg"
MOUNT_POINT=""

function cleanup {
  if [ -n "${MOUNT_POINT:-}" ] && mount | grep -q "on ${MOUNT_POINT}"; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
  if [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

if [ ! -d "${APP_PATH}" ]; then
  echo "Error: app bundle not found at ${APP_PATH}"
  exit 1
fi

if [ ! -f "${BACKGROUND_PNG}" ]; then
  echo "Error: background image not found at ${BACKGROUND_PNG}"
  exit 1
fi

mkdir -p "${STAGING}/.background"
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
cp "${BACKGROUND_PNG}" "${STAGING}/.background/background.png"

hdiutil create -volname "${VOLNAME}" \
  -srcfolder "${STAGING}" \
  -format UDRW \
  -ov "${RAW_DMG}"

python3 -c "
import subprocess, sys
volname = sys.argv[1]
info = subprocess.check_output(['hdiutil', 'info'], text=True)
for line in info.splitlines():
    parts = line.split('\t')
    if len(parts) >= 3 and parts[2].startswith('/Volumes/' + volname):
        subprocess.run(['hdiutil', 'detach', parts[0]], capture_output=True)
" "${VOLNAME}"

hdiutil attach -readwrite -noverify -plist "${RAW_DMG}" > "${TMP_DIR}/attach.plist"
MOUNT_POINT=$(python3 - <<PY
import plistlib
with open("${TMP_DIR}/attach.plist", "rb") as f:
    p = plistlib.load(f)
for entity in p.get("system-entities", []):
    if "mount-point" in entity:
        print(entity["mount-point"])
        break
PY
)

open "${MOUNT_POINT}"

osascript <<EOF
  tell application "Finder"
    tell disk "${VOLNAME}"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {100, 100, 900, 600}
      set viewOptions to icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      set background picture of viewOptions to POSIX file "${MOUNT_POINT}/.background/background.png"
      set position of item "OpenNOW.app" of container window to {180, 250}
      set position of item "Applications" of container window to {620, 250}
      update without registering applications
      delay 2
      close
    end tell
  end tell
EOF

hdiutil detach "${MOUNT_POINT}"
rm -f "${OUTPUT_DMG}"
hdiutil convert "${RAW_DMG}" -format UDZO -ov -o "${OUTPUT_DMG}"

echo "Created ${OUTPUT_DMG}"

#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: $0 <path/to/OpenNOW.app> [output.dmg]}"
OUTPUT_DMG="${2:-OpenNOW.dmg}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="${SCRIPT_DIR}/dmgbuild-settings.py"
BACKGROUND_PNG="${SCRIPT_DIR}/../Resources/OpenNOW/dmg-background.png"
VOLNAME="OpenNOW"

if ! command -v dmgbuild >/dev/null 2>&1; then
  echo "Error: dmgbuild not found on PATH. Install it with: pip install dmgbuild"
  exit 1
fi

if [ ! -d "${APP_PATH}" ]; then
  echo "Error: app bundle not found at ${APP_PATH}"
  exit 1
fi

if [ ! -f "${BACKGROUND_PNG}" ]; then
  echo "Error: background image not found at ${BACKGROUND_PNG}"
  exit 1
fi

APP_PATH_ABS="$(cd "$(dirname "${APP_PATH}")" && pwd)/$(basename "${APP_PATH}")"
BACKGROUND_ABS="$(cd "$(dirname "${BACKGROUND_PNG}")" && pwd)/$(basename "${BACKGROUND_PNG}")"

dmgbuild \
  -s "${SETTINGS}" \
  -D app_path="${APP_PATH_ABS}" \
  -D background="${BACKGROUND_ABS}" \
  "${VOLNAME}" "${OUTPUT_DMG}"

echo "Created ${OUTPUT_DMG}"

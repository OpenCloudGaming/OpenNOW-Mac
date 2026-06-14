#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OpenNOW"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
RELEASE_DIR="${BUILD_DIR}/release"
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_NAME}.app"
ZIP_PATH="${RELEASE_DIR}/${APP_NAME}-macOS-arm64.zip"
DMG_PATH="${RELEASE_DIR}/${APP_NAME}-macOS-arm64.dmg"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 1
  fi
}

require_tool xcodebuild
require_tool codesign
require_tool ditto
require_tool hdiutil

printf 'Building %s with Xcode...\n' "${APP_NAME}"
rm -rf "${DERIVED_DATA_DIR}" "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"
xcodebuild \
  -project "${ROOT_DIR}/OpenNOW.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  -destination 'platform=macOS,arch=arm64' \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  printf 'Expected app bundle not found: %s\n' "${APP_PATH}" >&2
  exit 1
fi

printf 'Signing app ad-hoc...\n'
codesign --force --deep --sign - "${APP_PATH}" >/dev/null

printf 'Verifying app bundle...\n'
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

printf 'Packaging release artifacts...\n'
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_PATH}" -ov -format UDZO "${DMG_PATH}" >/dev/null
hdiutil verify "${DMG_PATH}" >/dev/null

printf '\nRelease complete:\n'
du -sh "${APP_PATH}" "${ZIP_PATH}" "${DMG_PATH}"
printf '%s\n%s\n' "${ZIP_PATH}" "${DMG_PATH}"

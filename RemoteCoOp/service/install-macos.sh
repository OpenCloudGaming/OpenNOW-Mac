#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
NODE_BIN=${NODE_BIN:-$(command -v node)}
SUDO=${SUDO:-sudo}
ADMIN_GROUP=${ADMIN_GROUP:-opennow-coop-admin}
SERVICE_USER=${SERVICE_USER:-$(stat -f %Su "$REPO_ROOT")}
PLIST=/Library/LaunchDaemons/com.opennow.remote-coop.panel.plist
HELPER=/usr/local/libexec/opennow-remote-coop-pam-auth-helper

if [ "$(id -u)" -eq 0 ]; then SUDO=; fi

if ! dscl . -read "/Groups/$ADMIN_GROUP" >/dev/null 2>&1; then
  $SUDO dseditgroup -o create "$ADMIN_GROUP"
fi
if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  $SUDO dseditgroup -o edit -a "$SUDO_USER" -t user "$ADMIN_GROUP"
fi
$SUDO dseditgroup -o edit -a "$SERVICE_USER" -t user "$ADMIN_GROUP"

$SUDO mkdir -p /usr/local/libexec
"$REPO_ROOT/RemoteCoOp/panel/auth/build-pam-auth-helper.sh" /tmp/opennow-remote-coop-pam-auth-helper
$SUDO install -o root -g "$ADMIN_GROUP" -m 4750 /tmp/opennow-remote-coop-pam-auth-helper "$HELPER"
rm -f /tmp/opennow-remote-coop-pam-auth-helper

if [ ! -f /etc/pam.d/opennow-remote-coop ]; then
  $SUDO install -o root -g wheel -m 0644 "$REPO_ROOT/RemoteCoOp/panel/auth/opennow-remote-coop.macos.pam.example" /etc/pam.d/opennow-remote-coop
fi

TMP_PLIST=/tmp/com.opennow.remote-coop.panel.plist
sed "s#__REPO_ROOT__#$REPO_ROOT#g; s#__NODE__#$NODE_BIN#g; s#__SERVICE_USER__#$SERVICE_USER#g" "$REPO_ROOT/RemoteCoOp/service/macos/com.opennow.remote-coop.panel.plist" > "$TMP_PLIST"
$SUDO install -o root -g wheel -m 0644 "$TMP_PLIST" "$PLIST"
rm -f "$TMP_PLIST"

if launchctl print system/com.opennow.remote-coop.panel >/dev/null 2>&1; then
  $SUDO launchctl bootout system "$PLIST" || true
fi
$SUDO launchctl bootstrap system "$PLIST"
$SUDO launchctl enable system/com.opennow.remote-coop.panel
$SUDO launchctl kickstart -k system/com.opennow.remote-coop.panel

echo "OpenNOW Remote Co-Op panel installed: https://198.12.95.48:8787/"
echo "Panel access group: $ADMIN_GROUP"
echo "Panel service user: $SERVICE_USER"

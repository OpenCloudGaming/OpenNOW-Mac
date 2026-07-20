#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SUDO=${SUDO:-sudo}
REMOVE_STATE=${REMOVE_STATE:-0}
REMOVE_GROUPS=${REMOVE_GROUPS:-0}
ADMIN_GROUP=${ADMIN_GROUP:-macforce-now-coop-admin}
LABEL=com.macforce-now.remote-coop.panel
PLIST=/Library/LaunchDaemons/$LABEL.plist
HELPER=/usr/local/libexec/macforce-now-remote-coop-pam-auth-helper
PAM_FILE=/etc/pam.d/macforce-now-remote-coop
STATE_DIR=$REPO_ROOT/RemoteCoOp/panel/state

if [ "$(id -u)" -eq 0 ]; then SUDO=; fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  $SUDO launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
fi

$SUDO rm -f "$PLIST" "$HELPER" "$PAM_FILE"

if [ "$REMOVE_STATE" = "1" ]; then
  find "$STATE_DIR" -mindepth 1 ! -name .gitkeep -exec rm -f {} +
fi

if [ "$REMOVE_GROUPS" = "1" ] && dscl . -read "/Groups/$ADMIN_GROUP" >/dev/null 2>&1; then
  $SUDO dseditgroup -o delete "$ADMIN_GROUP" >/dev/null 2>&1 || true
fi

echo "MacForce Now Remote Co-Op panel service uninstalled."
if [ "$REMOVE_STATE" != "1" ]; then
  echo "Kept generated panel state under $STATE_DIR. Rerun with REMOVE_STATE=1 to remove generated panel secrets and certificates."
fi

#!/bin/sh
set -eu

SUDO=${SUDO:-sudo}
REMOVE_STATE=${REMOVE_STATE:-0}
REMOVE_GROUPS=${REMOVE_GROUPS:-0}
SERVICE_NAME=macforce-now-remote-coop-panel.service
SERVICE_GROUP=${SERVICE_GROUP:-macforce-now-coop}
ADMIN_GROUP=${ADMIN_GROUP:-macforce-now-coop-admin}
ENV_FILE=/etc/macforce-now/remote-coop-panel.env
ENV_DIR=/etc/macforce-now
HELPER=/usr/local/libexec/macforce-now-remote-coop-pam-auth-helper
PAM_FILE=/etc/pam.d/macforce-now-remote-coop
UNIT_FILE=/etc/systemd/system/$SERVICE_NAME

if [ "$(id -u)" -eq 0 ]; then SUDO=; fi

if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  $SUDO systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

$SUDO rm -f "$UNIT_FILE" "$HELPER" "$PAM_FILE"

if [ "$REMOVE_STATE" = "1" ]; then
  $SUDO rm -f "$ENV_FILE"
  $SUDO rmdir "$ENV_DIR" >/dev/null 2>&1 || true
fi

if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl daemon-reload
  $SUDO systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

if [ "$REMOVE_GROUPS" = "1" ]; then
  $SUDO groupdel "$ADMIN_GROUP" >/dev/null 2>&1 || true
  $SUDO groupdel "$SERVICE_GROUP" >/dev/null 2>&1 || true
fi

echo "MacForce Now Remote Co-Op panel service uninstalled."
if [ "$REMOVE_STATE" != "1" ]; then
  echo "Kept $ENV_FILE. Rerun with REMOVE_STATE=1 to remove generated service secrets."
fi

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
NODE_BIN=${NODE_BIN:-$(command -v node)}
SUDO=${SUDO:-sudo}
SERVICE_GROUP=${SERVICE_GROUP:-opennow-coop}
ADMIN_GROUP=${ADMIN_GROUP:-opennow-coop-admin}
ENV_DIR=/etc/opennow
ENV_FILE=$ENV_DIR/remote-coop-panel.env
HELPER=/usr/local/libexec/opennow-remote-coop-pam-auth-helper

if [ "$(id -u)" -eq 0 ]; then SUDO=; fi

SERVICE_USER=${SERVICE_USER:-$(stat -c %U "$REPO_ROOT")}
$SUDO groupadd -f "$SERVICE_GROUP"
$SUDO usermod -a -G "$SERVICE_GROUP" "$SERVICE_USER"
$SUDO groupadd -f "$ADMIN_GROUP"
if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  $SUDO usermod -a -G "$ADMIN_GROUP" "$SUDO_USER"
fi

$SUDO mkdir -p "$ENV_DIR" /usr/local/libexec
if [ ! -f "$ENV_FILE" ]; then
  SECRET=$(node -e 'console.log(require("crypto").randomBytes(48).toString("base64url"))')
  $SUDO sh -c "cat > '$ENV_FILE'" <<EOF
OPENNOW_REMOTE_COOP_PANEL_BIND_HOST=0.0.0.0
OPENNOW_REMOTE_COOP_PANEL_PORT=8787
OPENNOW_REMOTE_COOP_PANEL_ALLOWED_GROUPS=$ADMIN_GROUP
OPENNOW_REMOTE_COOP_PANEL_UPDATE_AUTOMATIC=1
OPENNOW_REMOTE_COOP_PUBLIC_HOST=198.12.95.48
OPENNOW_REMOTE_COOP_PORT=8788
OPENNOW_REMOTE_COOP_AUTOSTART=1
OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=$SECRET
EOF
  $SUDO chmod 640 "$ENV_FILE"
  $SUDO chown root:"$SERVICE_GROUP" "$ENV_FILE"
fi

"$REPO_ROOT/RemoteCoOp/panel/auth/build-pam-auth-helper.sh" /tmp/opennow-remote-coop-pam-auth-helper
$SUDO install -o root -g "$SERVICE_GROUP" -m 4750 /tmp/opennow-remote-coop-pam-auth-helper "$HELPER"
rm -f /tmp/opennow-remote-coop-pam-auth-helper

if [ ! -f /etc/pam.d/opennow-remote-coop ]; then
  $SUDO install -o root -g root -m 0644 "$REPO_ROOT/RemoteCoOp/panel/auth/opennow-remote-coop.pam.example" /etc/pam.d/opennow-remote-coop
fi

$SUDO sh -c "sed 's#__REPO_ROOT__#$REPO_ROOT#g; s#__NODE__#$NODE_BIN#g; s#__SERVICE_USER__#$SERVICE_USER#g; s#__SERVICE_GROUP__#$SERVICE_GROUP#g' '$REPO_ROOT/RemoteCoOp/service/linux/opennow-remote-coop-panel.service' > /etc/systemd/system/opennow-remote-coop-panel.service"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now opennow-remote-coop-panel.service

echo "OpenNOW Remote Co-Op panel installed: https://198.12.95.48:8787/"
echo "Panel access group: $ADMIN_GROUP"
echo "Panel service user: $SERVICE_USER"

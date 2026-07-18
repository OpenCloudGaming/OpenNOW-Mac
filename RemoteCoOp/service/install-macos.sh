#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
NODE_BIN=${NODE_BIN:-$(command -v node)}
SUDO=${SUDO:-sudo}
ADMIN_GROUP=${ADMIN_GROUP:-opennow-coop-admin}
SERVICE_USER=${SERVICE_USER:-$(stat -f %Su "$REPO_ROOT")}
LOGIN_USER=${LOGIN_USER:-${SUDO_USER:-$(id -un)}}
PLIST=/Library/LaunchDaemons/com.opennow.remote-coop.panel.plist
HELPER=/usr/local/libexec/opennow-remote-coop-pam-auth-helper
PANEL_PORT=${OPENNOW_REMOTE_COOP_PANEL_PORT:-}
BROKER_PORT=${OPENNOW_REMOTE_COOP_PORT:-}
TURN_PORT=${OPENNOW_REMOTE_COOP_TURN_PORT:-}
TURN_MIN_PORT=${OPENNOW_REMOTE_COOP_TURN_MIN_PORT:-}
TURN_MAX_PORT=${OPENNOW_REMOTE_COOP_TURN_MAX_PORT:-}

high_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 20000 ] && [ "$1" -le 60999 ]
}

tcp_port_available() {
  PORT_TO_CHECK=$1 node <<'EOF'
const port = Number.parseInt(process.env.PORT_TO_CHECK || "", 10);
if (!Number.isInteger(port)) process.exit(1);
const server = require("node:net").createServer();
server.once("error", () => process.exit(1));
server.once("listening", () => server.close(() => process.exit(0)));
server.listen(port, "0.0.0.0");
setTimeout(() => process.exit(1), 1000).unref();
EOF
}

udp_port_available() {
  PORT_TO_CHECK=$1 node <<'EOF'
const port = Number.parseInt(process.env.PORT_TO_CHECK || "", 10);
if (!Number.isInteger(port)) process.exit(1);
const socket = require("node:dgram").createSocket("udp4");
socket.once("error", () => process.exit(1));
socket.once("listening", () => socket.close(() => process.exit(0)));
socket.bind(port, "0.0.0.0");
setTimeout(() => process.exit(1), 1000).unref();
EOF
}

port_is_avoided() {
  CANDIDATE=$1
  shift
  for USED_PORT in "$@"; do
    if [ "$CANDIDATE" = "$USED_PORT" ]; then return 0; fi
  done
  return 1
}

select_tcp_port() {
  START=$1
  END=$2
  PREFERRED=$3
  shift 3
  if high_port "$PREFERRED" && ! port_is_avoided "$PREFERRED" "$@" && tcp_port_available "$PREFERRED"; then
    echo "$PREFERRED"
    return
  fi
  CANDIDATE=$START
  while [ "$CANDIDATE" -le "$END" ]; do
    if ! port_is_avoided "$CANDIDATE" "$@" && tcp_port_available "$CANDIDATE"; then
      echo "$CANDIDATE"
      return
    fi
    CANDIDATE=$((CANDIDATE + 1))
  done
  echo "error: no unused TCP port found in $START-$END" >&2
  exit 1
}

select_turn_port() {
  START=$1
  END=$2
  PREFERRED=$3
  shift 3
  if high_port "$PREFERRED" && ! port_is_avoided "$PREFERRED" "$@" && tcp_port_available "$PREFERRED" && udp_port_available "$PREFERRED"; then
    echo "$PREFERRED"
    return
  fi
  CANDIDATE=$START
  while [ "$CANDIDATE" -le "$END" ]; do
    if ! port_is_avoided "$CANDIDATE" "$@" && tcp_port_available "$CANDIDATE" && udp_port_available "$CANDIDATE"; then
      echo "$CANDIDATE"
      return
    fi
    CANDIDATE=$((CANDIDATE + 1))
  done
  echo "error: no unused TCP/UDP TURN port found in $START-$END" >&2
  exit 1
}

udp_range_available() {
  RANGE_START=$1
  RANGE_END=$2
  CANDIDATE=$RANGE_START
  while [ "$CANDIDATE" -le "$RANGE_END" ]; do
    if ! udp_port_available "$CANDIDATE"; then return 1; fi
    CANDIDATE=$((CANDIDATE + 1))
  done
  return 0
}

select_udp_range() {
  START=$1
  END=$2
  WIDTH=$3
  PREFERRED_START=$4
  PREFERRED_END=$5
  if high_port "$PREFERRED_START" && high_port "$PREFERRED_END" && [ $((PREFERRED_END - PREFERRED_START + 1)) -eq "$WIDTH" ] && udp_range_available "$PREFERRED_START" "$PREFERRED_END"; then
    echo "$PREFERRED_START $PREFERRED_END"
    return
  fi
  CANDIDATE=$START
  while [ $((CANDIDATE + WIDTH - 1)) -le "$END" ]; do
    RANGE_END=$((CANDIDATE + WIDTH - 1))
    if udp_range_available "$CANDIDATE" "$RANGE_END"; then
      echo "$CANDIDATE $RANGE_END"
      return
    fi
    CANDIDATE=$((CANDIDATE + WIDTH))
  done
  echo "error: no unused UDP relay range found in $START-$END" >&2
  exit 1
}

select_service_ports() {
  PANEL_PORT=$(select_tcp_port 32187 32250 "${PANEL_PORT:-32187}")
  BROKER_PORT=$(select_tcp_port 32188 32299 "${BROKER_PORT:-32188}" "$PANEL_PORT")
  TURN_PORT=$(select_turn_port 32189 32350 "${TURN_PORT:-32189}" "$PANEL_PORT" "$BROKER_PORT")
  set -- $(select_udp_range 42160 42999 41 "${TURN_MIN_PORT:-42160}" "${TURN_MAX_PORT:-42200}")
  TURN_MIN_PORT=$1
  TURN_MAX_PORT=$2
}

if [ "$(id -u)" -eq 0 ]; then SUDO=; fi

select_service_ports

if ! dscl . -read "/Groups/$ADMIN_GROUP" >/dev/null 2>&1; then
  $SUDO dseditgroup -o create "$ADMIN_GROUP"
fi
if [ -n "$LOGIN_USER" ] && id "$LOGIN_USER" >/dev/null 2>&1; then
  $SUDO dseditgroup -o edit -a "$LOGIN_USER" -t user "$ADMIN_GROUP"
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
sed "s#__REPO_ROOT__#$REPO_ROOT#g; s#__NODE__#$NODE_BIN#g; s#__SERVICE_USER__#$SERVICE_USER#g; s#__PANEL_PORT__#$PANEL_PORT#g; s#__BROKER_PORT__#$BROKER_PORT#g; s#__BROKER_ALTERNATES__#$((BROKER_PORT + 1)),$((BROKER_PORT + 2))#g; s#__TURN_PORT__#$TURN_PORT#g; s#__TURN_MIN_PORT__#$TURN_MIN_PORT#g; s#__TURN_MAX_PORT__#$TURN_MAX_PORT#g" "$REPO_ROOT/RemoteCoOp/service/macos/com.opennow.remote-coop.panel.plist" > "$TMP_PLIST"
$SUDO install -o root -g wheel -m 0644 "$TMP_PLIST" "$PLIST"
rm -f "$TMP_PLIST"

if launchctl print system/com.opennow.remote-coop.panel >/dev/null 2>&1; then
  $SUDO launchctl bootout system "$PLIST" || true
fi
$SUDO launchctl bootstrap system "$PLIST"
$SUDO launchctl enable system/com.opennow.remote-coop.panel
$SUDO launchctl kickstart -k system/com.opennow.remote-coop.panel

echo "OpenNOW Remote Co-Op panel installed: https://198.12.95.48:$PANEL_PORT/"
echo "Broker WebSocket port: $BROKER_PORT"
echo "TURN port: $TURN_PORT"
echo "TURN relay UDP range: $TURN_MIN_PORT-$TURN_MAX_PORT"
echo "Panel access group: $ADMIN_GROUP"
echo "Panel service user: $SERVICE_USER"
echo "Panel login user: $LOGIN_USER"

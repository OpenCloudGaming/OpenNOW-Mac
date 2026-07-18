# Remote Co-Op Background Service

The background service runs `RemoteCoOp/panel/control-panel.mjs`. The panel is the supervised parent process and manages `RemoteCoOp/run-servers.mjs` as a child.

## Install

Linux with systemd:

```sh
RemoteCoOp/service/install-linux.sh
```

macOS with launchd:

```sh
RemoteCoOp/service/install-macos.sh
```

The installers are non-interactive. They create the panel access group, build and install the PAM helper, install the service, and start the panel. The Linux installer installs compiler and PAM development packages automatically when needed. Linux stores a generated TURN secret in `/etc/opennow/remote-coop-panel.env`; macOS lets the panel create its stable secret under `RemoteCoOp/panel/state/` on first boot.

## Uninstall

Linux:

```sh
RemoteCoOp/service/uninstall-linux.sh
```

macOS:

```sh
RemoteCoOp/service/uninstall-macos.sh
```

Uninstall is non-interactive and removes the service, PAM helper, and PAM config. It keeps generated secrets/state by default so reinstalling preserves TURN credentials and panel TLS/session material. Remove generated state with:

```sh
REMOVE_STATE=1 RemoteCoOp/service/uninstall-linux.sh
REMOVE_STATE=1 RemoteCoOp/service/uninstall-macos.sh
```

The uninstall scripts leave users and groups intact by default. Remove the installer-created groups with `REMOVE_GROUPS=1`.

## Open The Panel

```text
https://198.12.95.48:8787/
```

The panel uses a generated self-signed HTTPS certificate unless `OPENNOW_REMOTE_COOP_PANEL_CERT` and `OPENNOW_REMOTE_COOP_PANEL_KEY` are configured. Browsers will warn on first access to a self-signed certificate.

## Login

Use a system username and password. Access is allowed for members of `opennow-coop-admin`. If that group does not exist, the panel falls back to local administrator groups.

The installers create `opennow-coop-admin` and add the user running `sudo` to it when possible.

## Controls

The authenticated panel can:

- Start, stop, and restart the Remote Co-Op broker/TURN child process.
- Show child status, broker endpoint, and recent logs.
- Fetch and apply Git updates with fast-forward-only pulls.

## Git Updates

Updates are intentionally conservative:

- Dirty worktrees are refused.
- Branches without upstreams are refused.
- Pulls use `git pull --ff-only`.
- Validation defaults to `node RemoteCoOp/run-servers.mjs --dry-run`.
- If panel files changed, the panel exits after update so systemd or launchd restarts it.

Automatic update checks are enabled by default every 300 seconds. Override with:

```sh
OPENNOW_REMOTE_COOP_PANEL_UPDATE_AUTOMATIC=0
```

## Linux Service Commands

```sh
sudo systemctl status opennow-remote-coop-panel
sudo journalctl -u opennow-remote-coop-panel -f
sudo systemctl restart opennow-remote-coop-panel
```

## macOS Service Commands

```sh
sudo launchctl print system/com.opennow.remote-coop.panel
tail -f /var/log/opennow-remote-coop-panel.log
sudo launchctl kickstart -k system/com.opennow.remote-coop.panel
```

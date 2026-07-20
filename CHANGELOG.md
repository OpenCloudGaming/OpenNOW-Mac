# Changelog

## [Unreleased]

### chore: rename project OpenNOW → MacForce Now

Renamed the application, codebase, build artifacts, and service subsystem from `OpenNOW` to `MacForce Now`.

- Display name changed to `MacForce Now`; bundle identifier changed to `com.necorico.macforce-now`; URL scheme changed to `macforce-now`; UserDefaults domain changed to `io.github.opencloudgaming.macforce-now`.
- Swift symbols prefixed `OpenNOW*` renamed to `MacForceNow*`; project, plist, entitlements, and source files renamed.
- RemoteCoOp service identifiers renamed to `com.macforce-now.remote-coop.panel` (macOS) and `macforce-now-remote-coop-panel.service` (Linux); environment variables renamed to `MACFORCE_NOW_REMOTE_COOP_*`.
- Existing user preferences, keychain credentials, OAuth tokens, and recording metadata are not migrated; users must re-authenticate and reconfigure after upgrading.
- Upstream `OpenCloudGaming/OpenNOW-Mac` sync source unchanged; fork remains mergeable with manual resolution on renamed files.

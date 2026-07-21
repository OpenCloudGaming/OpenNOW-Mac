# Changelog

## [0.2.0](https://github.com/anderson-oki/macforce-now/compare/v0.1.0...v0.2.0) (2026-07-21)


### Features

* add improved stretch layout ([4c12512](https://github.com/anderson-oki/macforce-now/commit/4c1251259c961fd9e3990469b9c28eb81c948a6f))
* add steam controller menu navigation ([749ec6f](https://github.com/anderson-oki/macforce-now/commit/749ec6f042aee7af68ba2709bb9b680ebf464dc3))


### Bug Fixes

* **ci:** bust SwiftPM cache on repo rename ([34493dc](https://github.com/anderson-oki/macforce-now/commit/34493dcc40a21ffb22fb6a419c14245795088957))
* controller catalog view ([a5f13da](https://github.com/anderson-oki/macforce-now/commit/a5f13dae9762d8f5f971086d5645aeed199d1b2a))
* locked aspect ratio outside streaming ([2329e39](https://github.com/anderson-oki/macforce-now/commit/2329e399b5382a04a87d9c16767b472bd8f7eb80))
* steam controller permission display ([db5bef1](https://github.com/anderson-oki/macforce-now/commit/db5bef12358051587e6c3ea770a127ccb1fd3979))

## [Unreleased]

### chore: rename project OpenNOW → MacForce Now

Renamed the application, codebase, build artifacts, and service subsystem from `OpenNOW` to `MacForce Now`.

- Display name changed to `MacForce Now`; bundle identifier changed to `com.necorico.macforce-now`; URL scheme changed to `macforce-now`; UserDefaults domain changed to `io.github.opencloudgaming.macforce-now`.
- Swift symbols prefixed `OpenNOW*` renamed to `MacForceNow*`; project, plist, entitlements, and source files renamed.
- RemoteCoOp service identifiers renamed to `com.macforce-now.remote-coop.panel` (macOS) and `macforce-now-remote-coop-panel.service` (Linux); environment variables renamed to `MACFORCE_NOW_REMOTE_COOP_*`.
- Existing user preferences, keychain credentials, OAuth tokens, and recording metadata are not migrated; users must re-authenticate and reconfigure after upgrading.
- Upstream `OpenCloudGaming/OpenNOW-Mac` sync source unchanged; fork remains mergeable with manual resolution on renamed files.

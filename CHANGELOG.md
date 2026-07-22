# Changelog

## [0.2.2](https://github.com/anderson-oki/macforce-now/compare/v0.2.1...v0.2.2) (2026-07-22)


### Bug Fixes

* catalog image duplication ([abb24c9](https://github.com/anderson-oki/macforce-now/commit/abb24c922684fecc2c93422564a4f03dab2e2c5c))
* catalog view alignment ([da606e5](https://github.com/anderson-oki/macforce-now/commit/da606e55898bad8e5e5d2181fe653f5daf40659b))
* checkout repo so release-please can resolve tag refs ([de0625a](https://github.com/anderson-oki/macforce-now/commit/de0625a9c318eb5bedae5696dd25738ab0971a56))
* harden Remote Co-Op security (token binding, origin checks, ATS scoping, signer pinning, constant-time HMAC) ([26cc0c0](https://github.com/anderson-oki/macforce-now/commit/26cc0c0daabb94116a297a651518f6d38e28b9fb))
* **remote-coop:** bind admin panel to loopback by default ([296615c](https://github.com/anderson-oki/macforce-now/commit/296615c33e4182d47581163cafe55cea6a915cd6))
* **remote-coop:** default broker to HTTPS/WSS with auto-generated self-signed certificates ([cb718b6](https://github.com/anderson-oki/macforce-now/commit/cb718b60efb0cf79bea11f7888cb9d40b3525075))
* **remote-coop:** disable auto-update by default and require signed commits ([b42739c](https://github.com/anderson-oki/macforce-now/commit/b42739c85c11e9ba8c57537e3ec9d9bff1315ce8))
* **remote-coop:** harden admin panel cookie access, timing-safe comparisons and path traversal guard ([fb27c08](https://github.com/anderson-oki/macforce-now/commit/fb27c0876550fd4d65322c73e03e97856069beaf))
* **remote-coop:** harden WebSocket with frame limits, buffer caps, and message validation ([6f163f2](https://github.com/anderson-oki/macforce-now/commit/6f163f234ceee347dc3c261690e83a82725e3653))
* **remote-coop:** reduce TURN credential TTL from 1 hour to 10 minutes ([ef31073](https://github.com/anderson-oki/macforce-now/commit/ef31073a5f16e172488947212b9c213423f5730f))
* **remote-coop:** strengthen login rate limiting and redact IP addresses in logs ([c0c76f6](https://github.com/anderson-oki/macforce-now/commit/c0c76f6ce962d159f7092d824daf34995937c88c))
* **remote-coop:** verify invite token signatures server-side to prevent session hijacking ([af8af21](https://github.com/anderson-oki/macforce-now/commit/af8af219503b30de513e83336c7ae564a36238de))
* steam controller permission display ([10f1e80](https://github.com/anderson-oki/macforce-now/commit/10f1e808d59aa27d85cd42d6bac4c72835932a7e))
* **updater:** pin Team ID in code signature verification and validate before clearing quarantine ([a2ea7fe](https://github.com/anderson-oki/macforce-now/commit/a2ea7feaa45c092d3b926f5ab40d9ea21ac075bf))

## [0.2.1](https://github.com/anderson-oki/macforce-now/compare/v0.2.0...v0.2.1) (2026-07-21)


### Bug Fixes

* derive marketing version from tag at build time ([cfff413](https://github.com/anderson-oki/macforce-now/commit/cfff4136c2e0eaa16e8c24d093fad68711b5e730))
* switch release-please to xcode release-type for pbxproj ([08b4d9e](https://github.com/anderson-oki/macforce-now/commit/08b4d9e10b12f84fc0a7357374ee0d60ba0236ca))
* sync marketing version to 0.2.0 and pin xcode updater ([10c01e1](https://github.com/anderson-oki/macforce-now/commit/10c01e18ede7bb5148123f437ad47f7e145ea6ba))

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

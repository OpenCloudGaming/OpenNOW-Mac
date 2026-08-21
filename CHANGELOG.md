# Changelog

## [0.17.0](https://github.com/anderson-oki/macforce-now/compare/v0.16.1...v0.17.0) (2026-08-21)


### Features

* add nvst av1 ([#60](https://github.com/anderson-oki/macforce-now/issues/60)) ([737b2bd](https://github.com/anderson-oki/macforce-now/commit/737b2bdf5d4a28e6112644ecd3b7f0f71a2daed7))
* add on screen keyboard ([6767b5b](https://github.com/anderson-oki/macforce-now/commit/6767b5b2dd9e10b4a93a3accb3c4f8560a3dad86))

## [0.16.1](https://github.com/anderson-oki/macforce-now/compare/v0.16.0...v0.16.1) (2026-08-20)


### Bug Fixes

* restore app-relative install names on vendored NVST dylibs ([364e08f](https://github.com/anderson-oki/macforce-now/commit/364e08f26147e06675ee4262b11988e39f03b82a))
* revamp store picker ownership flow to match design system ([c68c21c](https://github.com/anderson-oki/macforce-now/commit/c68c21c88ea0810e2a20ef3b543f14c31a677617))
* stabilize dispatcher and gamepad navigator tests ([237b9f6](https://github.com/anderson-oki/macforce-now/commit/237b9f6e9dca07f6f35008ceaf476e3a4699d9c8))

## [0.16.0](https://github.com/anderson-oki/macforce-now/compare/v0.15.0...v0.16.0) (2026-08-20)


### Features

* add catalog proxy ([337df3a](https://github.com/anderson-oki/macforce-now/commit/337df3accebe128d3f49cbb15915e2a188c4d259))
* increase catalog view thumbnail size ([f2378a9](https://github.com/anderson-oki/macforce-now/commit/f2378a990bf90f1fcbd84e7cd25577e48a1545c7))


### Bug Fixes

* remove production crash paths in app launch, NVST runtime, and stream recording ([7a59c79](https://github.com/anderson-oki/macforce-now/commit/7a59c79c79b9390aeb0319bba426dcacdabf87d2))

## [0.15.0](https://github.com/anderson-oki/macforce-now/compare/v0.14.1...v0.15.0) (2026-08-19)


### Features

* Add nsvt pillarbox filters ([b9b7e9a](https://github.com/anderson-oki/macforce-now/commit/b9b7e9a146fafedadfa026911b96d499fc3b7201))
* add nsvt steam controller hud ([ec72b7a](https://github.com/anderson-oki/macforce-now/commit/ec72b7a11b5383fe23fc33b12721c671b8aeee5e))
* add settings controller category ([461d7ac](https://github.com/anderson-oki/macforce-now/commit/461d7ac0f7453140a65f9c1a3cf6ce24cf7cf7d2))
* catalog performance improvements ([10b0b4f](https://github.com/anderson-oki/macforce-now/commit/10b0b4ffa5f3a0ac5bdcfbc5f3f622a6267c7663))
* Improve catalog performance ([77973e9](https://github.com/anderson-oki/macforce-now/commit/77973e96c0214db4c8eec029ab03197dace61340))


### Bug Fixes

* align launch screen, menu panels, and settings buttons with design spec ([be878fc](https://github.com/anderson-oki/macforce-now/commit/be878fcfa1e40391472ccfe934826312f783c1a9))
* align native NVST decoder and prepare ABI ([1e0562e](https://github.com/anderson-oki/macforce-now/commit/1e0562e466f2d635f1ca4fb4569365e93fd57078))
* authenticate NVST before prepare [skip ci] ([c122517](https://github.com/anderson-oki/macforce-now/commit/c122517fd72e7da8a8d54043dd114c9fd9da3dd6))
* authenticate NVST before prepare [skip ci] ([671a194](https://github.com/anderson-oki/macforce-now/commit/671a19493b9b650cb7f32c1dcc62a9e50980b8f8))
* catalog view hover ([91ff7b0](https://github.com/anderson-oki/macforce-now/commit/91ff7b06317d67dc0b7d67bf4d34883014e74bc9))
* complete synchronous NVST prepare inline ([9cafb68](https://github.com/anderson-oki/macforce-now/commit/9cafb6849c0058519291b7f6c3ce4b22da775e1b))
* full-width tile tray and collapse details on re-click, document uiScale sync rules ([6f6d654](https://github.com/anderson-oki/macforce-now/commit/6f6d654cf0940ba015f3c804de1bcefc459dd758))
* harden native NVST launch diagnostics ([51f53ec](https://github.com/anderson-oki/macforce-now/commit/51f53ecf35033978abd2ffca7a5aa8a507d61c27))
* keep asynchronous Geronimo prepare after upstream sync ([39d999b](https://github.com/anderson-oki/macforce-now/commit/39d999bb06818a3e3a64259cbeacca04d01ccf34))
* Native NVST cursor handling ([#47](https://github.com/anderson-oki/macforce-now/issues/47)) ([d48879b](https://github.com/anderson-oki/macforce-now/commit/d48879baa0e487346fe8b707708b31a58752cf31))
* NVST actions HUD ([92777d0](https://github.com/anderson-oki/macforce-now/commit/92777d0ceb77a6088144c55abb4ee1a3692d2212))
* nvst cycle ([fea9321](https://github.com/anderson-oki/macforce-now/commit/fea93215fc8021deaf3c29595af7b0f50635ec51))
* restore fork async prepare auth flow and loading screen blur ([a6eb08b](https://github.com/anderson-oki/macforce-now/commit/a6eb08b9d8760fea7c37e87459f3dff8312bce74))
* Special keys ([ba33e57](https://github.com/anderson-oki/macforce-now/commit/ba33e57fcf4be4246cd8e9582e4cb90af6d52f33))

## [0.14.1](https://github.com/anderson-oki/macforce-now/compare/v0.14.0...v0.14.1) (2026-08-17)


### Bug Fixes

* ensure CatalogImageCache.swift ends with newline ([41e6226](https://github.com/anderson-oki/macforce-now/commit/41e6226ea37772d398caf7c6d72751ebe0ac38ca))

## [0.14.0](https://github.com/anderson-oki/macforce-now/compare/v0.13.0...v0.14.0) (2026-08-17)


### Features

* adjust new session layout ([3a18234](https://github.com/anderson-oki/macforce-now/commit/3a1823446b8cea767859c6f57f20861d94303de8))
* close native NVST parity gaps ([d3b6d85](https://github.com/anderson-oki/macforce-now/commit/d3b6d85e49aa347cfed9473e6193c25c9dfaa1ed))


### Bug Fixes

* apply verified NVST packet controls ([a7ee856](https://github.com/anderson-oki/macforce-now/commit/a7ee856a047fade0073f5b0e0f0d5227936ed49c))
* grant workflows permission to sync-fork job ([1b2c57e](https://github.com/anderson-oki/macforce-now/commit/1b2c57e54a871dbeae5a54bd14447b23c088dfa9))
* keep HDR preference intact when display lacks HDR support ([caa3e9d](https://github.com/anderson-oki/macforce-now/commit/caa3e9d4549026484cf14f5a7fd3b2e59129f4da))
* preserve Bifrost session initialization ([f539a04](https://github.com/anderson-oki/macforce-now/commit/f539a04ed75571525c0a54ee47fa97b084fa42b9))
* preserve bound Bifrost imports ([6a99347](https://github.com/anderson-oki/macforce-now/commit/6a99347ce698ac79425613e724ba54f5e6125e95))
* rename OpenNOW to MacForceNow in CI workflow ([0b8acdb](https://github.com/anderson-oki/macforce-now/commit/0b8acdb1e2aba67e2cf64894d0d3c956637c5eeb))
* restore fork bundle identity and AGENTS.md after identifier sweep ([ca6d18b](https://github.com/anderson-oki/macforce-now/commit/ca6d18b1802a6f640aba977f14c282949b78c3e4))
* restore fork stream HUD features lost in merge ([4757bf9](https://github.com/anderson-oki/macforce-now/commit/4757bf9d8b879f5c8a52b178d5527ec7a696019d))
* restore quickAccess HUD interception lost in merge ([e3d9784](https://github.com/anderson-oki/macforce-now/commit/e3d978492649e0276a764164593d96fbcb3ccf82))
* stabilize NVST callback and test lifecycle ([f28bdd5](https://github.com/anderson-oki/macforce-now/commit/f28bdd5ea4a0d1af654dad7703f1a79c5eeda879))
* use fork bundle ID for MacForceNowTests target ([cced687](https://github.com/anderson-oki/macforce-now/commit/cced687d406dc9702601d21a075a7826e14fbca2))
* weak-capture window in deferred aspect restoration ([75f8f6f](https://github.com/anderson-oki/macforce-now/commit/75f8f6fb8485f01e80f980b5c6ab240ff52b85df))

## [0.13.0](https://github.com/anderson-oki/macforce-now/compare/v0.12.0...v0.13.0) (2026-08-16)


### Features

* improve loading stream screen ui ([bbb95ee](https://github.com/anderson-oki/macforce-now/commit/bbb95eeeca2d9f095efc40bdee7af41d678e993e))

## [0.12.0](https://github.com/anderson-oki/macforce-now/compare/v0.11.1...v0.12.0) (2026-08-16)


### Features

* add pillarbox modes ([dfecc46](https://github.com/anderson-oki/macforce-now/commit/dfecc468b5b8b2564c83cc67ea0f4655db56fb44))

## [0.11.1](https://github.com/anderson-oki/macforce-now/compare/v0.11.0...v0.11.1) (2026-08-11)


### Bug Fixes

* missing accessibility permission prompt ([2d9b4d4](https://github.com/anderson-oki/macforce-now/commit/2d9b4d4d4fc46b59f01a0d46a180ce4fee75ffcf))
* quick access open overlay ([e783ada](https://github.com/anderson-oki/macforce-now/commit/e783ada1513780a69bcfd7cc0ac2f632004e15a0))

## [0.11.0](https://github.com/anderson-oki/macforce-now/compare/v0.10.0...v0.11.0) (2026-08-10)


### Features

* add steam controller haptic ([d7f4705](https://github.com/anderson-oki/macforce-now/commit/d7f4705e6cd83f11b6e7f285581d42b34f66b8be))
* add steam controller mapping ([8199337](https://github.com/anderson-oki/macforce-now/commit/8199337a7bf3fa1b5ab1bdf9be914ea117575389))


### Bug Fixes

* controller mode catalog close details ([3a14fe6](https://github.com/anderson-oki/macforce-now/commit/3a14fe63b5ddf85e039c5c815c37684b6fac08ad))
* ui scaling ([ff1bd88](https://github.com/anderson-oki/macforce-now/commit/ff1bd88a5ba64bf5339d85062f9122cb3fe5f535))

## [0.10.0](https://github.com/anderson-oki/macforce-now/compare/v0.9.0...v0.10.0) (2026-08-10)


### Features

* add Starfleet device code auth parity ([5cce21e](https://github.com/anderson-oki/macforce-now/commit/5cce21e2646e3bb27864ed399e2f239e5cbc1407))
* expand stream hud controls ([8f86437](https://github.com/anderson-oki/macforce-now/commit/8f86437f99678ee01f5fa14e5553c44bc50c48b0))


### Bug Fixes

* align CloudMatch session create handling ([3e904fa](https://github.com/anderson-oki/macforce-now/commit/3e904faa16aa972a159dd65af6577d6228c3cd6c))
* align GFN catalog and client parity ([07d381a](https://github.com/anderson-oki/macforce-now/commit/07d381aa76abd5051758729f0380d8423192e4ad))
* align GFN client metadata with vendor ([89c720e](https://github.com/anderson-oki/macforce-now/commit/89c720eaf5f8dda53e3e95573d3cb5e5564e1275))
* apply live session timers ([bab26db](https://github.com/anderson-oki/macforce-now/commit/bab26db20a9fee2a1d10722adbfb1930af4d188c))
* catalog scale ([f9ccdc0](https://github.com/anderson-oki/macforce-now/commit/f9ccdc012b1d386cff1a046708f4749b17f4e920))
* complete catalog store parity ([82618f1](https://github.com/anderson-oki/macforce-now/commit/82618f15d52cf80b431f511048df1c4613264878))
* complete GFN catalog parity gaps ([e6d768e](https://github.com/anderson-oki/macforce-now/commit/e6d768ee1ebe92acf5f0402935a9edfc4c1e822f))
* copy diagnostics logs on upload failure ([ed226ea](https://github.com/anderson-oki/macforce-now/commit/ed226ead6e0dc61211dd86062d9dbb4696b7c6ea))
* downgrade expected network telemetry ([4defe0d](https://github.com/anderson-oki/macforce-now/commit/4defe0d81fcbb2d99060d82afd95c891ee9ad017))
* embed required session ads ([ecafc3f](https://github.com/anderson-oki/macforce-now/commit/ecafc3fe0602d6207a9d2faaaf8374484a4ed37e))
* gate membership badges by subscription tier ([f2d9d7d](https://github.com/anderson-oki/macforce-now/commit/f2d9d7d3e1b52f72201e6b195893ed81895af7bc))
* handle CloudMatch limited mode failures ([db1950c](https://github.com/anderson-oki/macforce-now/commit/db1950cfdc2a1e810e3cfc28e4d84f2f081c8133))
* honor server session limit timers ([766ed3a](https://github.com/anderson-oki/macforce-now/commit/766ed3ae4d3e33893bbcd8933f51e48ba8d7d30a))
* match GFN store picker layout ([0f1abbd](https://github.com/anderson-oki/macforce-now/commit/0f1abbd362457937670bb5ee987fad64302dc393))
* move catalog scrim sampling off main thread ([df79358](https://github.com/anderson-oki/macforce-now/commit/df793584e34602093559ce5c113499297054b0f0))
* parse nested session ads ([79b5342](https://github.com/anderson-oki/macforce-now/commit/79b5342e2354fe39fd1f449e61a76aa926c5007c))
* persist free tier session timer ([b265ccb](https://github.com/anderson-oki/macforce-now/commit/b265ccbbb0f5dd749150f27b40de68fdd18ad779))
* play required session ads ([4c70a87](https://github.com/anderson-oki/macforce-now/commit/4c70a878653e0bcb7fd8c83b088fc31c94801970))
* reduce catalog hangs and cache crashes ([9e14f8c](https://github.com/anderson-oki/macforce-now/commit/9e14f8c20b3f28d3fc15004bb887e3b95e4ebd89))
* require confirmed free tier for badges ([ec8c8a7](https://github.com/anderson-oki/macforce-now/commit/ec8c8a790a2de5dcaafb2a7723cacb237bbeafa2))
* retry catalog load after auth refresh ([0383549](https://github.com/anderson-oki/macforce-now/commit/0383549716938fb653f268135025367d1c52803a))
* satisfy xcode shortcut concurrency checks ([5f372a6](https://github.com/anderson-oki/macforce-now/commit/5f372a62e9e92dd2311c78c6bb551ca6eb2b76e1))
* show current session timer in sidebar ([158d02c](https://github.com/anderson-oki/macforce-now/commit/158d02c1a198e7fb1cf1d53e8346481bff0259dd))
* show free tier session countdown ([ba5fa70](https://github.com/anderson-oki/macforce-now/commit/ba5fa7087ce227422ef89f57bbebd41b81655a6d))
* show locked badge for paid membership games ([c341956](https://github.com/anderson-oki/macforce-now/commit/c3419568087d30b07ab322120e06de3b4b9eac85))
* unify catalog platform selection state ([978e1c6](https://github.com/anderson-oki/macforce-now/commit/978e1c6bf1ea0cce83463b2806d9af6da196494f))

## [0.9.0](https://github.com/anderson-oki/macforce-now/compare/v0.8.1...v0.9.0) (2026-08-02)


### Features

* add steam controller shape on tester ([b92a3c8](https://github.com/anderson-oki/macforce-now/commit/b92a3c85f9269688a6946164f2b9671817104632))
* add turn off steam controller on steam + y shortcut ([1e3f273](https://github.com/anderson-oki/macforce-now/commit/1e3f273fcfc51ca4a2b2dccfebb6da34604d1b71))


### Bug Fixes

* hero aspect ratio ([4e0bd2f](https://github.com/anderson-oki/macforce-now/commit/4e0bd2fc7903224f5a83067e221934c5aded97d2))
* my favories catalog filter ([15a9ec4](https://github.com/anderson-oki/macforce-now/commit/15a9ec45c871a7f10e51709668fbd33acbd19e9d))

## [0.8.1](https://github.com/anderson-oki/macforce-now/compare/v0.8.0...v0.8.1) (2026-08-02)


### Bug Fixes

* stop detail image hit-spill and add styled overflow menu ([64e21e7](https://github.com/anderson-oki/macforce-now/commit/64e21e7352af1d20c1887b5e459a64da9b900061))

## [0.8.0](https://github.com/anderson-oki/macforce-now/compare/v0.7.0...v0.8.0) (2026-08-02)


### Features

* add discord rich presence ([#22](https://github.com/anderson-oki/macforce-now/issues/22)) ([6771a4a](https://github.com/anderson-oki/macforce-now/commit/6771a4a7723f218c99504f498237bb58061956b7))
* add live clock to stream HUD footer ([c4a76ab](https://github.com/anderson-oki/macforce-now/commit/c4a76ab2c512142e8845df71d03a9105b5c5b844))
* add ui scaling configuration ([6438fa6](https://github.com/anderson-oki/macforce-now/commit/6438fa65745b2fda14ee0f7ce53fe3ddaa4f0177))
* re-style quit game dialog ([3cfbabc](https://github.com/anderson-oki/macforce-now/commit/3cfbabcc3860427cb9a7e60113eab788312379ba))


### Bug Fixes

* harden CI SwiftPM cache against corrupt restores ([ee61ecf](https://github.com/anderson-oki/macforce-now/commit/ee61ecf17b4102f73e07f5c90cdd25d18126c410))
* refresh expired session before initial catalog load and reload after 401 recovery ([4798fa8](https://github.com/anderson-oki/macforce-now/commit/4798fa84e3b98330a27f087bafa026432bfebd74))
* restore pointer lock on hide hud ([6bde82e](https://github.com/anderson-oki/macforce-now/commit/6bde82eca02e03d4bffb48af627a81fa3afd360c))

## [0.7.0](https://github.com/anderson-oki/macforce-now/compare/v0.6.0...v0.7.0) (2026-07-31)


### Features

* add steam controller mapping ([#18](https://github.com/anderson-oki/macforce-now/issues/18)) ([4287982](https://github.com/anderson-oki/macforce-now/commit/42879820943cfc6f15d62951ab3792efa3beabd4))


### Bug Fixes

* controller mode performance ([#19](https://github.com/anderson-oki/macforce-now/issues/19)) ([0561eb2](https://github.com/anderson-oki/macforce-now/commit/0561eb2d4d428dffa4d80aeee30de8e7dbf85df9))

## [0.6.0](https://github.com/anderson-oki/macforce-now/compare/v0.5.0...v0.6.0) (2026-07-29)


### Features

* add Applications folder and background layout to DMG ([a887b05](https://github.com/anderson-oki/macforce-now/commit/a887b05b3f2c79a25ff74f937f8494450bc2baf3))
* add library and favorites catalog view ([de38224](https://github.com/anderson-oki/macforce-now/commit/de382248f8f752eb9512d704bd313ad89b4e361e))


### Bug Fixes

* catalog loading state ([aa43718](https://github.com/anderson-oki/macforce-now/commit/aa437185dbc5bfb5bb55f72e0fc05606c344256d))

## [0.5.0](https://github.com/anderson-oki/macforce-now/compare/v0.4.0...v0.5.0) (2026-07-28)


### Features

* improve catalog performance ([#15](https://github.com/anderson-oki/macforce-now/issues/15)) ([b3b942c](https://github.com/anderson-oki/macforce-now/commit/b3b942c9bcf44a4023947bc656e68328ea4b07b9))


### Bug Fixes

* app signature validation ([ca873c1](https://github.com/anderson-oki/macforce-now/commit/ca873c1f1fa9a750302989c8058015d262214c42))

## [0.4.0](https://github.com/anderson-oki/macforce-now/compare/v0.3.0...v0.4.0) (2026-07-27)


### Features

* add controller battery display ([3c53569](https://github.com/anderson-oki/macforce-now/commit/3c53569b3b97024971e44785aae4669ba6706f57))
* add custom profile context menu ([9b8e09b](https://github.com/anderson-oki/macforce-now/commit/9b8e09b444c6e50ada8818d9a53923bd831f18a0))
* ui improvements ([b599f2d](https://github.com/anderson-oki/macforce-now/commit/b599f2d1238ed67eb784e9a3eb7adb199ad0055a))

## [0.3.0](https://github.com/anderson-oki/macforce-now/compare/v0.2.2...v0.3.0) (2026-07-26)


### Features

* add 5120x2160 ultrawide resolution to 21:9 options ([c7880c2](https://github.com/anderson-oki/macforce-now/commit/c7880c2b9cd0ac4a0d7d7b9f70c2e48b76a0db7f))
* add check for updates menu button ([4b425f4](https://github.com/anderson-oki/macforce-now/commit/4b425f4d8164e94d54b36621122bde62e6ca40ea))
* implement Steam Controller input capture to suppress lizard mode ([309deb9](https://github.com/anderson-oki/macforce-now/commit/309deb9cfcfb2bac37821d681410922ee5e713c4))


### Bug Fixes

* render client and native resolution ([89e9f54](https://github.com/anderson-oki/macforce-now/commit/89e9f54d48614a7a449ff98f24c513b039630e84))
* **stream:** stream H265 over WebRTC instead of downscaled or AV1 ([558bd94](https://github.com/anderson-oki/macforce-now/commit/558bd940659170feeac31c1a4d7199900aa71adc))

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

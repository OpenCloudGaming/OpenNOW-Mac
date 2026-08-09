# Native NVST ABI Notes

This file records verified NVIDIA ABI facts used to keep the native NVST path safe. Do not treat missing fields as inferred.

## Runtime Artifacts

- `libBifrost2.dylib` exports the raw `nvst*` API and higher-level `nvb*` API.
- `libGeronimo.dylib` imports `nvb*` from `libBifrost2.dylib` and provides the macOS integration layer around session control, VideoToolbox, audio, SDL/input, and GridApp callbacks.
- `libGeronimo.dylib`, `libBifrost2.dylib`, `libGsAudioWebRTC.dylib`, and `SDL2.framework` use `@executable_path/../Frameworks` install names, matching OpenNOW.app embedding.

## Verified Raw `nvst*` Primitives

- `nvstGetVersion()` returns the C string `"14"`.
- `nvstPrepareSignalingServerEndpoint(char const *host, UInt16 port, NvstServerEndpoint_t *out) -> NvstResult_t` returns `0` for a valid host/port.
- `NvstServerEndpoint_t` fields verified through `nvstPrepareSignalingServerEndpoint`:
- `0x00`: host pointer.
- `0x08`: `UInt16` port.
- `0x0c`: `UInt32` transfer protocol, initialized to `5`.
- `0x10`: `UInt32` port usage, initialized to `5`.
- `nvstInitializeStreamConfig(UInt32 mediaType, UInt32 direction, NvstStreamConfig_t *out) -> NvstResult_t` returns `0` for video/audio receiver configs.

## Verified `nvb*` Calling Conventions

- `nvbCreateClient()` takes no arguments and returns an opaque client pointer.
- `nvbStartSession` is not Swift-callable directly because it uses the arm64 C++ struct-return convention.
- Verified arm64 register use at `_nvbStartSession`:
- `x8`: result storage pointer for `NVbResult_t`.
- `x0`: opaque client pointer.
- `x1`: `NVbSessionParams_t const *`.
- `NVbResult_t` is copied as `0x14` bytes by Geronimo callsites after `nvbStartSession` returns.

## Verified `NVbSessionParams_t` Layout

`GridApp::start` and `SessionControl::SessionControllerImpl::startSession(SessionParameters, tracing)` both stack-allocate an `NVbSessionParams_t`, zero it with `bzero(params, 0x208)`, populate it, and pass it to `nvbStartSession`.

- Size: `0x208` bytes.
- `0x00`: `UInt32` app id.
- `0x08`: server address C string pointer.
- `0x10`: server port stored as 16-bit value.
- `0x18`: settings-controlled flag from `GeronimoSettingsImpl`.
- `0x1c`: connection protocol / transport-related integer copied from `SessionParameters + 0x24`.
- `0x20`: `NVbStreamSettings_t *`.
- `0x28`: stream settings count.
- `0x2c`: codec enum, currently set to `3` by Geronimo before start.
- `0x30`: session-ready boolean, set to `1` before start.
- `0x38...0x13f`: `NVbVideoDecoder_t` / decoder configuration block copied from Geronimo platform state.
- `0x170`: gamepad bitmap.
- `0x174`: copied from `SessionParameters + 0x1cc` / Geronimo session state.
- `0x178`: pointer copied from Geronimo metadata state, then source is cleared.
- `0x180`: count/size copied from Geronimo metadata state, then source is cleared.
- `0x184`: boolean copied from `SessionParameters + 0x234`.
- `0x188`: C string pointer from a Geronimo-owned string at `GridApp + 0x488`.
- `0x1b8`: string pointer copied from `SessionParameters + 0x1e8` when present.
- `0x1c0`: client locale C string pointer copied from `SessionParameters + 0x218` when present.
- `0x1c8`: keyboard layout C string pointer copied from `SessionParameters + 0x200` when present.
- `0x1d0`: boolean copied from `SessionParameters + 0x230`.
- `0x1d1`: audio channel count / audio support byte copied from Geronimo state.
- `0x1d2`: boolean copied from `SessionParameters + 0x234`.
- `0x1d4`: connection info count.
- `0x1d8`: `NVbConnectionInfo_t *`.
- `0x1e0`: session id C string pointer copied from `SessionParameters + 0x250` when present.
- `0x1e8`: integer copied from `SessionParameters + 0x280`.

## Verified `SessionControl::SessionParameters` Facts

- `SessionParameters` contains non-trivial C++ ownership (`std::string`, vectors). Backing storage must outlive `GridApp::start` until Geronimo/Bifrost no longer references copied C string and vector pointers.
- `GridApp::setNVbSessionParams` copies from `SessionParameters` into GridApp-owned storage before setting `NVbSessionParams_t` pointers.
- `GFNQueryHandler::OnQueryNative` constructs `SessionParameters` at `sp + 0x4d0` and passes it to `GridApp::start` or `GridApp::resume`.
- NVIDIA query fields seen in the start path include `serverAddress`, `tokenType`, `token`, `appId`, `streamingProfile`, `audioModeFormat`, and `session`.

## Integration Constraints

- Do not call `nvbStartSession` directly from Swift.
- Use a C++/Objective-C++ shim for any `nvb*` API returning or accepting non-trivial C++/large result structs.
- Do not replace the current safe-fail path until `SessionParameters`, `NVbStreamSettings_t`, `NVbConnectionInfo_t`, callback lifetimes, and media/input callbacks are fully verified.

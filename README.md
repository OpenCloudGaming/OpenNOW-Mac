# OpenNOW

OpenNOW is a cloud gaming client codebase. The previous native macOS frontend has been removed so the UI can be rebuilt from zero.

## Current State

The repository currently keeps the service, protocol, authentication, streaming, and shared package modules. There is no app target, frontend source tree, or bundled UI asset set in this reset state.

## Packages

- `Backend`
- `CloudMatch`
- `Common`
- `GDN`
- `Jarvis`
- `LCARS`
- `NesAuth`
- `NetworkTest`
- `Ragnarok`
- `SignalLinkKit`
- `Starfleet`
- `UDS`

## Testing

Run package tests from an individual package directory:

```sh
swift test
```

The `Backend` package still depends on a macOS WebRTC framework at `third_party/webrtc-official`.

## Contributing

Open issues for bugs or feature requests and submit pull requests for improvements.

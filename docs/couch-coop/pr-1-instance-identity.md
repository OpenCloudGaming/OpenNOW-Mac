# PR 1: plan, flag, instance identity, storage isolation

Base: `main`. Inert unless the `couchCoop` Labs flag is on and a second instance is started with `--opn-instance N`.

## Changes

- `docs/couch-coop/`: this plan.
- `OPNLabs.couchCoop` flag (`OPN/Services/OPNLabs.swift`).
- `OPN/Core/OPNAppInstance.swift`:
  - `number`, `isPrimary`, `storageIdentifier` (bundle ID for instance 1, `<bundleId>.instance<N>` otherwise), `defaults`, `supportDirectory`, `keychainAccountPrefix`.
  - Resolved from `--opn-instance N` only while the flag is on. Without the argument, or with N of 1, the process is instance 1 and takes no lock.
  - Instances above 1 hold `flock` on `Application Support/OpenNOW/instances/N.lock` for the life of the process (`O_CLOEXEC`), so a crash frees the number. If the lock is already held, the new process activates the running copy and quits.
- Keychain: `GFNTokenStore` keeps the single service. Account names get `keychainAccountPrefix`. `deleteAll` removes only the caller's accounts.
- Storage routed through the instance:
  - auth store URL (`OPNApp.authStoreURL`),
  - `OPNAuthService+Storage.swift` defaults and support directory (legacy session path off for secondaries),
  - `OPNDeviceIdentity` file and `generateOPNDeviceId` seed,
  - `OpenNOW.Stream.ActiveSessionId` (both definitions) and `CatalogPreviousGameSession`,
  - stream window frame defaults,
  - catalog image cache store, diagnostics log, clipboard history.
- Replay retention (one saved replay per game) is namespaced in PR 2.

## Tests

- `OPNAppInstanceTests`: argument parsing, flag off means primary, lowest free lock, held lock, storage identifiers.
- Keychain account naming for instance 1 and instance N, and `deleteAll` scoped to the prefix.
- Device ID for instance 1 unchanged, instance 2 differs.
- Auth store URL and support directory per instance.

## Verification

`swift build` and `swift test` with `--scratch-path .build/shared`; flag off, the app is byte-for-byte the same storage layout as today.

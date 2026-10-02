# PR 2: launch, presence, secondary-instance behaviour, settings

Base: PR 1.

- "Start Couch Co-op" in the Stream menu (flag on only), via `OPN/Services/OPNCouchCoopLauncher.swift`: `NSWorkspace.openApplication` with `createsNewApplicationInstance`, arguments `--opn-instance 2 -ApplePersistenceIgnoreState YES`. `OPNApp.swift` only calls into the launcher.
- `OPN/Services/OPNCouchCoopPresence.swift`: `isActive` from `NSRunningApplication` plus NSWorkspace launch and terminate notifications; instance number, screen ID and assignment revision over `DistributedNotificationCenter` (post with `deliverImmediately`, observe with `.deliverImmediately`).
- Secondary instances: no updater, iCloud sync, capture migration, launch-at-login row, Discord presence, menu bar item or Remote Co-Op hosting; always open a window; quit with the last window; microphone off by default; sign-in modal opens on the QR tab.
- Update installs blocked in every instance while co-op is active.
- Instant Replay retention keyed by game plus instance, so each player keeps their own replay of the same game.
- "Player N" window titles and a "P2" dock tile mark.
- Couch Co-Op card on the Remote Co-Op settings page: layout choice (side by side, top and bottom, manual) and the flag. All views use `uiScale` and DESIGN.md patterns.

Tests: presence state, launcher arguments, secondary-instance feature gating, settings storage.

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

## How it is built

- `OPNInstanceFeatureGate` holds every secondary-instance decision as a pure value, so the rules are tested without launching a second copy. The preference getters (`OPNMenuBarPreferences.showsStatusItem`, `OPNWindowClosePreferences.behavior`, `OPNLaunchPreferences.resolvedStartupPresentation`, `OPNRemoteCoOpPreferencesStore.load`) read it, which keeps the menu bar item, the keep-running choices, the windowless launch and Remote Co-Op hosting off in a secondary instance without touching their call sites.
- The "Start Couch Co-op" item is `OPNCouchCoopStartButton`, which calls `OPNCouchCoopLauncher`. The launcher caps the stack at two copies for now.
- Presence announcements use the name `<bundleId>.couchCoop.presence`, so a dev build and the release build never see each other. A copy that hears an unknown process announces itself again, which is how a copy launched second learns about the first.
- Replay retention is keyed by game plus instance number. A manifest written before this change has no instance number and belongs to instance 1.
- Window titles read `<title> · Player N` and the Dock tile gets a `PN` pill. Instance 1 only shows them while co-op is active.
- Update installs are refused in every instance while co-op is active, with a message naming the reason. Update checks, iCloud sync, capture migration, Launch at Login, Discord presence, the menu bar item and Remote Co-Op hosting are off in secondary instances.
- The Couch Co-Op card sits at the top of the Remote Co-Op page and is also reachable from settings search.

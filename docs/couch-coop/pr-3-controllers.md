# PR 3: controllers

Base: PR 2.

- `Model/Stream/OPNCouchCoopControllerAssignment.swift` (pure): ordered descriptors (`<vendorName>#<ordinal>` for native pads, `steam-controller-<id>` for Steam pads), overrides, active flag and instance number in, owned descriptors out. Native pads first, then Steam. Instance 1 decides and publishes overrides plus a revision; others follow. A reconnecting pad goes to the instance with no pad.
- `ControllerMappingDevices` exposes `streamOrder` (owned pads only); `NativeGamepadMonitor.refreshControllerSlots` and `connectedGamepadCount` use it, so a player's pad is slot 0 of their own session.
- While co-op is active: `GCController.shouldMonitorBackgroundEvents` on, gamepad events accepted without focus (`acceptsWhileNotFrontmost`, `ControllerMappingFocusPolicy`), focus loss releases only keyboard and mouse. Keyboard and mouse stay focus-gated.
- A pad that changes owner is neutralised first so no button stays down.
- `ControllerInputRouter` and `GamepadUINavigator` filter to owned pads. Steam seize, lizard mode, motion, heartbeat and rumble apply only to owned pads; the Steam cursor injector is off in co-op.
- Cmd-G HUD Controllers section: a Swap tile, a row per connected pad (cycle Player 1, Player 2, Off), Identify rumble, live press highlight polled while the HUD is open. Tiles are declared in both the view and the focus entries, with the parity test extended. Dropdowns, if any, use `StreamHUDDropdown`.
- Reassigning never restarts the session; only the slot topology is re-announced.

Tests: assignment, slot mapping, input routing, focus policy, HUD parity, Steam capture filtering.
Early hardware check: runtime toggling of `shouldMonitorBackgroundEvents`, and `GCController.controllers()` order across processes with identical pads.

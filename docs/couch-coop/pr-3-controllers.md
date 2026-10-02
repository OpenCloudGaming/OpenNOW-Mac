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

## How it is built

- `OPNCouchCoopControllerAssignment` is a pure value. Given the connected descriptors, the overrides and the instance numbers in the roster, it says which instance gets which pad. Without overrides the first pad goes to the first instance, the second to the second, and any extra pad stays off. A pad with an override keeps it. Instance 1 pins the resolved result into its overrides whenever the pads change, so a pad that leaves does not shuffle the other player's pad, and a pad that comes back goes to the instance with no pad.
- Overrides ride on instance 1's presence announcement as a small JSON payload, next to the revision it already bumps. A change made in another copy's HUD is sent to instance 1 as an assignment request, which instance 1 applies and republishes.
- `OPNControllerOwnership` is the lock-guarded state every thread reads: whether co-op is active and which descriptors this copy owns. `OPNCouchCoopControllerCoordinator` is the only writer. When ownership changes it asks `ControllerMappingDevices` to recompute `streamOrder`, which makes `NativeGamepadMonitor` rebuild its slots, and it tells the Steam monitor to seize or release the pads that moved. The usual slot-change path neutralises every pad first, so nothing stays held across the move.
- Seat rumble only reaches slot pads, so it only reaches owned pads. The Settings rumble test and the HUD identify button pulse a pad directly and are not filtered.
- Keyboard and mouse keep the focus gate. `ControllerMappingFocusPolicy` names the two exceptions: gamepad events pass while the window is not frontmost in Picture in Picture or couch co-op, and focus loss only releases gamepad state when co-op is off.
- The Steam cursor injector is off while co-op is active, since two copies would fight over one system cursor.

## Not verified yet

- Whether `GCController.shouldMonitorBackgroundEvents` can be toggled at runtime, and whether `GCController.controllers()` returns identical pads in the same order in both processes, were not checked on hardware. The descriptor scheme and the "swap once after pairing" limit in the README assume both.

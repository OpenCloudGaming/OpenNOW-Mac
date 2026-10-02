# PR 4: layout and window placement

Base: PR 3. No 8:9 resolution in this stack.

- `OPN/Stream/OPNCouchCoopLayout.swift` (pure): tile rect from the shared screen, layout and instance number.
- `OPN/Core/OPNCouchCoopVideoPolicy.swift`: applied at the end of `OPNStreamPreferences.launchProfile`. Letterbox leaves the profile alone; top and bottom with fill picks the largest fitting 32:9 preset and sets both `resolution` and `aspect`. Locked at launch through a `coopTile` on `StreamLaunchConfiguration`, so a partner quitting never changes a running stream.
- `OPNStreamWindowPresenter.present`: tiled layouts keep `.titled`, hide the window buttons, zero the top inset, override `constrainFrameRect`, set `autoHideMenuBar` and `autoHideDock`, stop persisting the frame, and release the aspect lock. Manual adds `.fullScreenAllowsTiling` and drops the lock.
- No automatic native fullscreen while tiled; the fullscreen HUD tile is disabled. The catalog window tiles to the same half when co-op starts.

Tests: layout geometry, video policy, frame store skips saves while tiled.
Manual: side by side, top and bottom, Split View; pointer mapping after tiling; UI scale 1.25 and 1.5.

# PR 4: layout and window placement

Base: PR 3. No 8:9 resolution in this stack.

- `OPN/Stream/OPNCouchCoopTile.swift` (pure geometry): `OPNCouchCoopTileGeometry.rect` takes an area, a layout and an instance number and returns that player's tile. `OPNCouchCoopTile` carries the layout, the instance, the tile frame and the backing scale. The existing `OPNCouchCoopLayout` enum (the user's choice) keeps its name, so the geometry lives next to it under a different one.
- `OPN/Core/OPNCouchCoopVideoPolicy.swift`: applied at the end of `OPNStreamPreferences.launchProfile`. Side by side and manual leave the profile alone. Top and bottom picks the largest existing 32:9 preset that fits the tile's pixel size (the smallest when none does) and sets both `resolution` and `aspect`. The tile is stamped on `StreamLaunchConfiguration.coopTile` once, when the launch starts, so a partner quitting never changes a running stream.
- `OPNStreamWindowPresenter.present` hands tiled configurations to `OPNCouchCoopWindowPlacement`: the window keeps `.titled`, hides its buttons, takes the tile frame, overrides `constrainFrameRect`, stops persisting its frame, and releases the aspect lock. The app sets `autoHideMenuBar` and `autoHideDock` while the tiled window exists and restores the previous options on dismissal. Manual adds `.fullScreenAllowsTiling` and drops the lock.
- No automatic native fullscreen while a tile is set, and the fullscreen HUD tile is disabled for tiled layouts. The stage reserves no titlebar inset when tiled.
- `OPNCouchCoopCatalogTiler` moves the catalog window to the same half (of the visible frame) when co-op becomes active.

Tests: layout geometry, video policy, the tile surviving the launch configuration, window placement, the frame store skipping saves while tiled.
Manual: side by side, top and bottom, Split View; pointer mapping after tiling; UI scale 1.25 and 1.5.

## Known limits

- A stream that was already running when the partner started keeps its untiled window and profile.
- Picture in Picture is not blocked in a tiled layout and shows the window buttons again on exit.
- The full build and the on-screen behaviour were not run when this was written.

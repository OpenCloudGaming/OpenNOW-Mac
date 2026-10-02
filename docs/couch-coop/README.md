# Couch co-op: two OpenNOW instances side by side

Two people on one Mac play the same online-only co-op game. Each runs their own copy of OpenNOW signed into their own GeForce NOW account. The copies sit on halves of one screen and each is driven by its own controller.

Pitch and maintainer discussion: OpenCloudGaming/OpenNOW-Mac#65.

## Decisions

- One process per player. A single process hosting two sessions would mean reworking the process-wide singletons (auth service, controller monitors, stream window, pointer lock, audio), so it is out of scope.
- Everything ships behind the `couchCoop` flag in `OPNLabs`. With the flag off the app behaves exactly as before.
- Instance 1 is the app as it is today: same storage, same keychain service, no migration.
- One keychain service for every instance (`OpenNOW.GFN`, as the maintainer asked). Instances other than 1 prefix their keychain account names with `instance<N>.` so they cannot read or purge each other's tokens.
- Every other piece of per-instance state (auth store, `accounts.plist`, device ID, auth defaults, active-session keys, diagnostics log) is namespaced by `<bundleId>.instance<N>`.
- Controllers are assigned by connection order (pad N goes to instance N) with overrides in the Cmd-G HUD.
- Layouts: side by side with a letterboxed 16:9 stream, top and bottom with a 32:9 stream filling each half, and manual (native Split View). The experimental 8:9 resolution is not part of this work, at the maintainer's request.
- Nothing from the Qt desktop client is brought over. It is a separate codebase.

## Stack

| PR | Plan | Scope |
| --- | --- | --- |
| 1 | [pr-1-instance-identity.md](pr-1-instance-identity.md) | Plan docs, `couchCoop` flag, instance identity, storage isolation |
| 2 | [pr-2-launch-presence.md](pr-2-launch-presence.md) | Launch command, presence, labels, secondary-instance behaviour, settings card |
| 3 | [pr-3-controllers.md](pr-3-controllers.md) | Controller ownership, background input, HUD assignment |
| 4 | [pr-4-layout.md](pr-4-layout.md) | Tile geometry, stream window placement, 32:9 fill |

Each PR is stacked on the one before it, builds and passes tests on its own, and changes nothing while the flag is off.

## Repository rules each PR follows (AGENTS.md)

- Nothing is committed or pushed without being asked. Commit messages carry a conventional prefix.
- Identity anchors stay as they are: bundle IDs, the `opennow` URL scheme, the UserDefaults domain, keychain service `OpenNOW.GFN`, the updater owner and repository, Remote Co-Op on port 32188. Instance 1 uses all of them unchanged.
- No explanatory inline comments, no force unwraps, no stubs, zero warnings, strict concurrency clean.
- New views thread `uiScale`, use `.opnUI` fonts and `OPNDesign` colors, follow DESIGN.md, and use `StreamHUDDropdown` inside the HUD. No new `.swiftlint-baseline.json` entries.
- Build and test from the repo root with `--scratch-path .build/shared`. Run the design lint before handing back anything under `View/`.

## Known limits

- Tiled windows do not get macOS Game Mode. Manual Split View does.
- Both streams play to the same audio output.
- Each account needs its own GeForce NOW membership and must own the game.
- Two identical controllers may need one swap after pairing, because GameController exposes no stable hardware ID.

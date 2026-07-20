---
description: Language-agnostic production standards for all code generation and reviews.
applyTo: '**'
---

# Operational Protocol
Execute every task in this order:

1. **Audit** — List all files, modules, and components required.
2. **Blueprint** — Outline a concise architectural plan before writing code.
3. **Execution** — Deliver complete, production-ready code. No snippets, placeholders (`TODO`, `pass`, `...`), or stubs.
4. **Autonomy** — Resolve missing context or dependencies using the standard library or canonical practices.

# Build Artifact Discipline
- Run SwiftPM commands from the repository root unless a task explicitly requires otherwise.
- Use `--scratch-path .build/shared` for SwiftPM commands that generate build state, including `swift build`, `swift test`, `swift run`, and relevant `swift package` commands.
- Do not run package-local SwiftPM commands that create package-specific `.build` directories. Use the root `Package.swift` with the shared scratch path instead.
- After SwiftPM-heavy tasks, run `scripts/report-spm-build-size.sh` to check generated build size and duplicated binary artifact extractions.
- If generated SwiftPM files exceed the warning threshold or duplicate `artifacts/sentry-cocoa` directories appear, run `scripts/clean-spm-builds.sh`, then rerun builds/tests with `--scratch-path .build/shared`.
- Never commit generated build artifacts.

# Upstream Sync

This repository is a fork of `OpenCloudGaming/OpenNOW-Mac`. The `sync-fork.yml` workflow runs weekly (Monday 06:00 UTC) and opens a PR labeled `upstream-sync` from `upstream/main` into `main`. The fork was renamed from OpenNOW to MacForce Now, so upstream syncs require manual conflict resolution on renamed files and re-application of identifier renames on merged lines.

## Renamed File Mapping

When a `upstream-sync` PR conflicts on any of these paths, the upstream change applies to the old path (left); resolve onto the new path (right):

| Upstream path (old) | Fork path (new) |
|---|---|
| `OpenNOWApp.swift` | `MacForceNowApp.swift` |
| `OpenNOW-Info.plist` | `MacForceNow-Info.plist` |
| `OpenNOW.entitlements` | `MacForceNow.entitlements` |
| `OpenNOW.xcodeproj/project.pbxproj` | `MacForceNow.xcodeproj/project.pbxproj` |
| `OPN/Services/OpenNOWLog.swift` | `OPN/Services/MacForceNowLog.swift` |
| `OPN/Services/OpenNOWGitHubUpdater.swift` | `OPN/Services/MacForceNowGitHubUpdater.swift` |
| `OPN/Services/OpenNOWInterfacePreferences.swift` | `OPN/Services/MacForceNowInterfacePreferences.swift` |
| `OPN/Services/OpenNOWWebRTCMediaTelemetrySink.swift` | `OPN/Services/MacForceNowWebRTCMediaTelemetrySink.swift` |
| `OPN/GameServices/OpenNOWStreamSessionCoordinator.swift` | `OPN/GameServices/MacForceNowStreamSessionCoordinator.swift` |
| `OPN/Core/OpenNOWNotifications.swift` | `OPN/Core/MacForceNowNotifications.swift` |
| `View/OpenNOWDesign.swift` | `View/MacForceNowDesign.swift` |
| `View/Design/OpenNOWNVIDIAFont.swift` | `View/Design/MacForceNowNVIDIAFont.swift` |
| `View/Startup/OpenNOWStartupLoadingView.swift` | `View/Startup/MacForceNowStartupLoadingView.swift` |
| `Tests/Games/OpenNOWGameServicesTests.swift` | `Tests/Games/MacForceNowGameServicesTests.swift` |
| `Tests/Twitch/OpenNOWTwitchTests.swift` | `Tests/Twitch/MacForceNowTwitchTests.swift` |
| `Resources/OpenNOW/` | `Resources/MacForceNow/` |
| `RemoteCoOp/service/macos/com.opennow.remote-coop.panel.plist` | `RemoteCoOp/service/macos/com.macforce-now.remote-coop.panel.plist` |
| `RemoteCoOp/service/linux/opennow-remote-coop-panel.service` | `RemoteCoOp/service/linux/macforce-now-remote-coop-panel.service` |
| `RemoteCoOp/service/opennow-remote-coop-panel.env.example` | `RemoteCoOp/service/macforce-now-remote-coop-panel.env.example` |
| `RemoteCoOp/panel/auth/opennow-remote-coop.pam.example` | `RemoteCoOp/panel/auth/macforce-now-remote-coop.pam.example` |
| `RemoteCoOp/panel/auth/opennow-remote-coop.macos.pam.example` | `RemoteCoOp/panel/auth/macforce-now-remote-coop.macos.pam.example` |

## Identifier Re-Application

Upstream commits may reintroduce `OpenNOW`/`opennow`/`OPENNOW_` identifiers on merged lines. After resolving file-level conflicts, run this sweep on the merge result to re-apply the fork's rename:

```sh
files=$(rg -l 'OpenNOW|opennow|OPENNOW_' \
  --glob '!**/.build/**' --glob '!**/.git/**' --glob '!**/WebRTC.framework/**' \
  --glob '!**/vendor/**' --glob '!**/Package.resolved' --glob '!**/.playwright-mcp/**' \
  --glob '!**/.claude/**' --glob '!**/.opencode/**' --glob '!**/.agents/**' \
  --glob '!README.md' --glob '!**/sync-fork.yml' --glob '!CHANGELOG.md')
echo "$files" | xargs sed -i '' 's/OpenNOW /MacForce Now /g; s/OpenNOW/MacForceNow/g; s/opennow/macforce-now/g; s/OPENNOW_/MACFORCE_NOW_/g'
```

Then fix display-name occurrences that should contain a space, and preserve the GitHub repo name:

```sh
sed -i '' 's/repository: "opennow-mac"/repository: "macforce-now"/' MacForceNowApp.swift
sed -i '' 's/Window("MacForceNow"/Window("MacForce Now"/' MacForceNowApp.swift
sed -i '' 's/INFOPLIST_KEY_CFBundleDisplayName = MacForceNow;/INFOPLIST_KEY_CFBundleDisplayName = "MacForce Now";/' MacForceNow.xcodeproj/project.pbxproj
sed -i '' 's/-scheme MacForce Now /-scheme MacForceNow /' .github/workflows/release.yml .github/workflows/unit-tests.yml
```

## Sync Procedure

1. Fetch the `upstream-sync` PR locally and merge `upstream/main` into a working branch off `main`.
2. Resolve file-level conflicts using the mapping table above: apply upstream content changes onto the new fork paths, not the old ones.
3. Run the identifier re-application sweep on the full working tree.
4. Verify the only remaining `opennow` hits are `README.md` (upstream attribution), `CHANGELOG.md` (history), and `.github/workflows/sync-fork.yml` (upstream URL):
   ```sh
   rg -n 'OpenNOW|opennow|OPENNOW_' --glob '!**/.build/**' --glob '!**/.git/**' \
     --glob '!**/WebRTC.framework/**' --glob '!**/vendor/**' --glob '!**/Package.resolved' \
     --glob '!**/.playwright-mcp/**' --glob '!**/.claude/**' --glob '!**/.opencode/**' \
     --glob '!**/.agents/**' --glob '!README.md' --glob '!**/sync-fork.yml' --glob '!CHANGELOG.md'
   ```
   Expect zero output.
5. Run `swift build --scratch-path .build/shared` and `swift test --scratch-path .build/shared`.
6. Run `xcodebuild build -project MacForceNow.xcodeproj -scheme MacForceNow -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO`.
7. Commit the merge with `chore: sync upstream` and push.

# Coding Standards

## General
- **Self-Documenting:** Names and structure must convey intent. No explanatory inline comments.
- **Hermetic:** Every file includes all imports and dependencies. Must compile/run as-is.
- **Complete:** All functions and methods contain final, working logic. No mocks or no-ops unless building a test suite.
- **No Folded Code:** Folding code is strictly forbidden.

## Migration & Conversion
- **No Stubs:** Never use stubs when migrating or converting code.
- **In-Place Conversion:** Always convert the existing implementation in place.
- **No Wrappers:** Do not use wrappers, shims, adapters, or compatibility layers during migration or conversion.
- **Remove Legacy Files:** Delete the old `.mm` and `.h` files after migration or conversion.
- **Trace Blockers:** Always trace and convert or migrate blockers during migration or conversion.
- **Migrate Blockers:** Always migrate blockers instead of bypassing, stubbing, or deferring them.

## Resource & State
- **Lifecycle:** Explicitly manage memory, connections, and handles via the language's native paradigm (RAII, context managers, ownership, etc.).
- **Immutable by Default:** Use language-native constraints (`const`, `readonly`, `final`). Mutable state must be minimal and scoped.

## Error Handling
- **Explicit:** Handle all edge cases idiomatically (Result/Option types, caught exceptions, multiple returns).
- **No Panics:** Never use forceful unwraps or unhandled crash equivalents. Failures must propagate or degrade gracefully.

## Quality
- **Strict Typing:** Use static/strict types throughout. Avoid `any` or dynamic types unless architecturally required.
- **Zero Warnings:** Code must pass the strictest linter and compiler settings cleanly.

# Commit Standards
- Commit all completed work before considering a task done.
- Push completed commits to the current branch's upstream remote after committing.
- Prefix every message with a conventional tag: `fix:`, `feat:`, `chore:`, `docs:`, `refactor:`, `test:`, or `style:`.

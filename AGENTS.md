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
- UI work is linted against DESIGN.md by the `design_*` custom rules in `.swiftlint.yml`. Run `swift package --scratch-path .build/lint plugin --allow-writing-to-package-directory swiftlint lint --strict --baseline .swiftlint-baseline.json App GFN Model OPN View ViewModel Tests` before handing back a change under `View/`. Pre-existing surfaces are grandfathered in `.swiftlint-baseline.json`; do not add new entries to it — annotate a documented exception at the site instead.
- For this Xcode project, use Xcode/XcodeBuildMCP only for builds, tests, and runs. Do not use SwiftPM commands as build/test/run shortcuts unless the user explicitly overrides this instruction for a specific task.
- Run SwiftPM commands from the repository root unless a task explicitly requires otherwise.
- Use `--scratch-path .build/shared` for SwiftPM commands that generate build state, including `swift build`, `swift test`, `swift run`, and relevant `swift package` commands.
- Do not run package-local SwiftPM commands that create package-specific `.build` directories. Use the root `Package.swift` with the shared scratch path instead.
- After SwiftPM-heavy tasks, run `scripts/report-spm-build-size.sh` to check generated build size and duplicated binary artifact extractions.
- If generated SwiftPM files exceed the warning threshold or duplicate `artifacts/sentry-cocoa` directories appear, run `scripts/clean-spm-builds.sh`, then rerun builds/tests with `--scratch-path .build/shared`.
- Never commit generated build artifacts.

# Repository Identity

This repository (`OpenCloudGaming/openNOW-Mac`) is the canonical OpenNOW source. It descended from `OpenCloudGaming/OpenNOW-Mac`, was temporarily renamed to MacForce Now, was restored to OpenNOW in 2026-08, and was transferred into the OpenCloudGaming organization in 2026-08. There is no separate upstream to sync from: no `upstream` remote, no `sync-fork.yml` workflow, and no upstream-sync procedure. Do not add an upstream-sync setup or reintroduce `MacForceNow`/`macforce-now` identifiers.

Identity anchors (verify these survive any bulk rename or merge):

- `OpenNOW.xcodeproj/project.pbxproj`: Release `PRODUCT_BUNDLE_IDENTIFIER = "io.github.opencloudgaming.opennow"`, Debug `= "io.github.opencloudgaming.opennow.dev"`, tests `= "io.github.opencloudgaming.opennow.tests"`, Debug `PRODUCT_NAME = "OpenNOW Dev"`.
- URL scheme `opennow`; UserDefaults domain `io.github.opencloudgaming.opennow`; keychain services `OpenNOW.GFN` / `OpenNOW.Twitch`; telemetry key prefix `opennow.*`.
- `App/OpenNOWAppDelegate.swift`: updater is `OpenNOWGitHubUpdater(owner: "OpenCloudGaming", repository: "openNOW-Mac")`.
- RemoteCoOp: hosted in-app by `OPNRemoteCoOpEmbeddedServer` on port 32188. No daemon, no service unit, no environment variables. The guest page ships in `Resources/RemoteCoOp/browser`.

`App/` is a `PBXFileSystemSynchronizedRootGroup` in the Xcode project — new files under it are picked up automatically, no pbxproj edit needed. `OpenNOWApp.swift` contains only the `@main` App struct; update preferences live in `OPN/Services/OpenNOWUpdatePreferences.swift` and the `NSApplicationDelegate` in `App/OpenNOWAppDelegate.swift`.

# UI Scaling & Design System

The app has a `uiScale` system and design tokens defined in `DESIGN.md`. Any new or imported UI code (new views, modified modifiers, new constants) must follow it:

- **Thread `uiScale` through every view**: add `@Environment(\.opnUIScale) private var uiScale` and scale all hardcoded dimensions — frames, paddings, spacings, corner radii, offsets — with `* uiScale` or the layout helpers (`CatalogVendorLayout.*(scale:)`, `CatalogShowAllLayout`, `OpenNOWDesign.Spacing.*(scale:)`).
- **Scale consistently within one geometric expression.** Every constant contributing to the same size must scale identically. Mixing scaled and unscaled values only breaks at `uiScale != 1` and looks correct at 1.0 — e.g. `wideTileWidth(scale:) - 32 * uiScale` combined with an unscaled `.padding(.horizontal, 16)` left the tile tray background narrower than the tile (and its full-width selection bar) at any scale above 1.0.
- **Use project fonts and colors**: `.nvidiaFont(size:weight:)` (uiScale-aware in catalog code) instead of `.font(.system(...))`, and `OpenNOWDesign` colors/surfaces instead of hardcoded `Color(red:green:blue:)` unless matching an existing intentional value.
- **New components** must follow `DESIGN.md` component patterns; update `DESIGN.md` when a change introduces a genuinely new pattern.
- **Verify visually at a non-default UI scale** (e.g. 1.25 and 1.5 via Settings) for every touched view — layout bugs from inconsistent scaling are invisible at 1.0.

Sweep touched view files for unscaled constants as a heuristic:

```sh
git diff main...HEAD --name-only -- 'View/**/*.swift' | xargs rg -n '\.(frame|padding|offset)\(' | rg -v 'uiScale|scale:|\.infinity|minLength: 0'
```

Review each hit; not every unscaled value is wrong (stroke widths, 1pt dividers, and deliberate fixed sizes are fine), but any constant paired with scaled siblings in the same layout expression is a bug.

# Vendor Protocol Surface

`GFN/CloudMatch`, `GFN/GDN`, and `GFN/NesAuth` model the vendor HTTP protocols. Their request
factories, endpoint enums, and error types are used by the app; the generic `CloudMatchService`,
`GDNService`, and `NesAuthService` wrappers are exercised only by their test suites. That is
deliberate — they are the executable specification of the reverse-engineered protocol and the
seam their tests inject a transport through. Do not delete them as dead code.

`WebRTC.framework/Headers/sdk` is likewise load-bearing despite looking like a vendored source
dump: the shipped public headers `#import "sdk/objc/base/RTCMacros.h"`, so stripping that tree
breaks the umbrella header rather than merely shrinking the checkout.

# Merge & Build Pitfalls

- **Never use `git checkout --theirs` or `--ours` on a conflicted file.** It silently discards the other side's features. In one past sync, `--theirs` wiped the quickAccess HUD interception in `NativeWebRTCStreamView.swift` and ~985 lines of pillarbox/Steam-mapping/uiScale code in `WebRTCMediaStreamSurface.swift`. Resolve hunk by hunk; for heavily diverged files use `git merge-file` and review every conflict.
- **All UI code must compile under SPM strict concurrency.** The SPM target compiles `App/`, `View/`, and `ViewModel/` (Swift 6 mode), which is stricter than the Xcode target: `@MainActor`-isolated types with `Equatable`/`Identifiable` conformances error under SPM but only warn in Xcode. If a view trips `#ConformanceIsolation`: for value-type enums drop the `@MainActor` annotation, for views comparing only `Sendable` properties use `nonisolated static func ==`, for views comparing non-Sendable model objects use `@preconcurrency Equatable`.
- **Modifying vendored dylibs breaks macOS code signing.** `install_name_tool` invalidates signatures; every process that stats the file afterwards (including `git status`) gets SIGKILL'd with `CODESIGNING: Invalid Page`. Re-sign immediately: `codesign --force --sign - <dylib>` (and `codesign --force --deep --sign -` for frameworks).
- **Never amend a merge commit.** `git commit --amend` on a merge commit drops the second parent, converting it into a regular commit — merged ancestry is lost. If the commit message or content needs adjustment after resolving, create a follow-up commit instead.
- **Type migrations can silently break tests.** Merged changes may introduce new types (e.g. `String` → `InputDeviceID`) or expose previously unambiguous expressions (e.g. `.nan` ambiguity between `CGFloat` and `Double`). After resolving conflicts, run `swift test --scratch-path .build/shared` and fix any compilation errors before committing.

# Coding Standards

## General
- **Self-Documenting:** Names and structure must convey intent. No explanatory inline comments.
- **Design System:** All UI code must follow `DESIGN.md` (colors, typography, spacing, components, elevation, guidelines). Update `DESIGN.md` whenever design tokens or component patterns change.
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
- Push completed commits to the current branch's remote tracking branch on `origin` after committing.
- Prefix every message with a conventional tag: `fix:`, `feat:`, `chore:`, `docs:`, `refactor:`, `test:`, or `style:`.

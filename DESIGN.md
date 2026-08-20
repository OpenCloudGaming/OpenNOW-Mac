# MacForce Now Design System

Squared, panel-based dark interface echoing the GeForce NOW industrial aesthetic: flat
surfaces, 1px strokes, a single NVIDIA green accent, and NVIDIA Sans typography. Corner
radius is reserved for a small set of explicit exceptions — panels, buttons, and fields
are always plain rectangles.

Token sources of truth:

- App shell: `View/MacForceNowDesign.swift` (`MacForceNowDesign`), `View/Login/LoginStyles.swift`
- Stream HUD: `OPN/Stream/WebRTCMediaStreamSurface.swift` (`WebRTCMediaStreamTheme`)
- Typography: `View/Design/MacForceNowNVIDIAFont.swift` (`MacForceNowNVIDIAFont`)

## Colors

### Brand

- **Accent** (#75E61A): NVIDIA green, `MacForceNowDesign.accent` /
  `WebRTCMediaStreamTheme.accent`. Primary actions, active states, focus rings, section
- **Destructive** (#FF8980): `MacForceNowDesign.Semantic.destructive`. Destructive menu
  roles, end-stream actions, error accents.
  eyebrows, top edge bars. Never used for large backgrounds.
- **Accent Soft** (#ABFF5C): `WebRTCMediaStreamTheme.accentSoft`. Status text on the
  stream launch overlay only.

### Surfaces

- **App Background** (#191919): `MacForceNowDesign.Surface.app`. Root window background.
- **App Bar** (#2D2D2D): `Surface.appBar` / `WebRTCMediaStreamTheme.appBar`. Header bands
  on docks, dialogs, and panels.
- **Panel** (#1C1C1C app, #171717 stream): `Surface.panel` / `WebRTCMediaStreamTheme.panel`.
  Cards, docks, and dialog bodies.
- **Panel Raised** (#222222): `Surface.panelRaised` / `WebRTCMediaStreamTheme.surfaceRaised`.
  Nested or elevated panels, gradient stops.
- **Tile Tray** (#292929): `Surface.tileTray`. Grid/tile containers in the catalog.
- **Field** (#1F1F1F): `Surface.field`. Input backgrounds on app-shell forms.
- **Scrim** (#000000 @ 0.58 app, 0.54 stream): `Surface.scrim`. Full-cover dim behind
  modals and overlays.
- **Deep** (#121312): `Surface.deep`. Full-page backdrops for settings-style flows
  (Settings, Steam Controller test/mapping surfaces).
- **Overlay** (#171717): `Surface.overlay`. Menu and Show All page backdrops.
- **Chrome** (#39393B): `Surface.chrome`. Hero gradient base and launch-overlay chrome.

### Text

- **Text Primary** (#FFFFFF @ 0.96): Main content and values.
- **Text Secondary** (#FFFFFF @ 0.72): Supporting copy, dialog descriptions.
- **Text Tertiary** (#FFFFFF @ 0.52): `Text.tertiary`. Section labels, row labels,
  footers.
- **Text Muted** (#FFFFFF @ 0.38): Disabled and placeholder text.

### Strokes

- **Stroke Subtle / Divider** (#FFFFFF @ 0.10): `Stroke.subtle` /
  `WebRTCMediaStreamTheme.divider`. Default 1px borders and divider bars.
- **Stroke Regular** (#FFFFFF @ 0.14): `Stroke.regular`. Interactive element borders
  (buttons, fields, pickers).
- **Stroke Strong** (#FFFFFF @ 0.22): `Stroke.strong`. Emphasized borders, hover states.

### Fill Tints (stream HUD)

- **Row Fill** (#FFFFFF @ 0.075): Resting background of interactive rows and buttons;
  0.14 on hover.
- **Section Fill** (#FFFFFF @ 0.055): Background of HUD sections and metric cards.

### Semantic

- **Warning** (#FF9500, system orange): `WebRTCMediaStreamTheme.warning`. Low battery,
  degraded states, validation messages.
- **Danger** (#FF0000, system red): `WebRTCMediaStreamTheme.danger`. Live badges and
  destructive-state indicators. Destructive dialog actions still use the standard
  secondary button style.

## Typography

Typeface is **NVIDIA Sans** in three weights, bundled as WOFF2 and loaded through
`MacForceNowNVIDIAFont` (falls back to the system font at the matching weight if the
bundle resource is unavailable). SwiftUI accessors: `.openNOWNVIDIA(size:weight:)` and
`.nvidiaSans(size:weight:)`; the stream surface uses the file-private
`.streamNvidia(size:weight:)`.

Weights: `regular`, `medium`, `bold`.

### Stream HUD Scale

- **Eyebrow / Section Label**: 9–10pt bold, tracking 0.7–1.4, uppercase, accent or
  Text Tertiary. Examples: "GFN" dock eyebrow (11pt, tracking 1.4), section labels
  (10pt, tracking 1.1), badge labels (9pt, tracking 0.7).
- **Row Label**: 11pt medium, Text Tertiary.
- **Row Value**: 11pt bold, Text Primary.
- **Body / Description**: 12pt medium, Text Secondary.
- **Control Label**: 11–12pt medium or bold. Segmented pickers 12pt medium; dialog and
  footer buttons 12pt bold with tracking 0.4.
- **Panel Title**: 13–14pt medium/bold, Text Primary or Secondary.
- **Dock / Dialog Title**: 20pt bold, Text Primary.

### App Shell Scale

- **Buttons**: 13–14pt bold, tracking 0.3–0.4.
- **Text Fields**: 14pt regular.
- Login vendor surfaces use NVIDIA Sans 14pt bold; general app-shell controls may use the
  system font at the same sizes when the NVIDIA face is not required.

System rounded/monospaced fonts remain only in legacy stream overlays (launch overlay,
Twitch panel, transient message pills). Do not use them in new code.

## Spacing

### App Shell (`MacForceNowDesign.Spacing`)

**Scale** — 4pt-grid values for generic layout spacing. Each exists as an unscaled
static let and a `scale:`-parameterized function; use the function on surfaces that
multiply by `opnUIScale`.

| Token | Value | | Token | Value |
|---|---|---|---|---|
| `xxSmall` | 4 | | `large` | 20 |
| `xSmall` | 8 | | `xLarge` | 24 |
| `small` | 12 | | `xxLarge` | 32 |
| `medium` | 16 | | `xxxLarge` | 40 |

**Structural and component tokens**

- **Page Horizontal**: 40 — page content margins.
- **Rail Horizontal**: 32 — sidebar/rail padding.
- **Card**: 18 — card internal padding.
- **Section**: 10 — section container padding (main menu sections, HUD sections).
- **Content Vertical**: 14 — vertical rhythm inside panels and cards.
- **Control Row**: 12 — horizontal padding inside controls, triggers, and menu rows.
- **Menu Panel Vertical**: 4 — dropdown panel vertical padding.

**Window top inset** — the titlebar has a fixed physical height regardless of
interface scale. Chrome measures it with `WindowTopInsetReader` and never scales it;
`CatalogVendorLayout.fallbackWindowTopInset` (32) is only the pre-measurement fallback.

### Stream HUD

- **Dock header**: 22 horizontal, 16 top, 14 bottom.
- **Dock content**: 18 horizontal, 14 vertical; 14 between sections.
- **Section**: 10 padding; 8–10 internal spacing.
- **Metric card**: 10 padding; 5 internal spacing.
- **Action row grid**: 8 between buttons.
- **Dialog body**: 18 padding; 16 between description and actions.
- **Footer**: 18 horizontal, 9 vertical.

## Interface Scale

All point sizes in this document are pre-scale (100 %) values. A user-adjustable
interface scale multiplies every size on the chrome surfaces it wraps.

- **Token**: `MacForceNowInterfacePreferences.uiScale` (`MacForceNow.Interface.UIScale`),
  Double in 0.75–2.0, default 1.0. Always read/write through `clampedUIScale(_:)`.
- **Mechanism**: `.macForceNowInterfaceScale(_:)` (`View/MacForceNowDesign.swift`) lays
  content out in a reduced logical space, then applies `scaleEffect` so chrome reflows
  larger instead of cropping. Never apply plain `scaleEffect` to chrome without the
  compensating frame, and never scale the video surface itself.
- **Text fidelity**: `scaleEffect` alone rasterizes text at display density and upscales
  the bitmap (progressively blurrier as scale grows). `MacForceNowInterfaceScaleDensityBooster`
  (mounted once at the `ContentView` root) keeps every non-Metal window layer's
  `contentsScale` pinned at `uiScale × window.backingScaleFactor` via a run-loop observer,
  forcing SwiftUI to re-render text and vector content at zoom density. It skips
  `CAMetalLayer` (the stream video) and restores natural density at 100 %. Layers with
  direct bitmap content (game art, `ImageLayer`) are never display-invalidated —
  re-rendering would blank them; only empty or re-renderable (`CGDrawingLayer`) layers
  are redrawn. Never bypass it with per-layer `contentsScale` edits elsewhere.
- **Applied to**: catalog chrome including controller mode and overlays (`CatalogView`
  non-stream branch), the login window (`LoginView`), and the stream HUD chrome layer
  (`hudChrome` in `WebRTCMediaStreamSurface`). Full-bleed backdrops and transient
  splash/loading screens stay at 100 %.
- **Setting**: Settings → General → Interface → Display, "Interface Scale" slider
  (5 % steps, shown as a percentage).

## Radius

- **Default**: 0 — panels, docks, dialogs, buttons, fields, and cards are plain
  `Rectangle`s with 1px strokes. No `RoundedRectangle`, no `Capsule`.
- **Avatar**: 14 (`MacForceNowDesign.Radius.avatar`).
- **Exceptions**: circular mic toggle and status dots on the stream surface, login vendor
  icon buttons (`size * 0.32`). New UI must not add further exceptions.

## Components

### Buttons (app shell)

- **Primary**: Accent background, black 14pt bold text (tracking 0.4), 14 vertical /
  16 horizontal padding, square corners. Pressed: accent @ 0.76.
- **Secondary**: #FFFFFF @ 0.08 background (0.16 pressed), 1px Stroke Regular, white
  13–14pt bold text, square corners.
- **Compact Row Action** (`MacForceNowCompactButtonStyle`): settings/inline row
  actions. Height 28, NVIDIA Sans 12pt bold, 14 horizontal padding, square corners.
  Primary: accent background (0.78 pressed), black text, accent stroke. Destructive:
  #000000 @ 0.35 background (0.5 pressed), white text, red @ 0.85 stroke. Takes
  `uiScale`; call sites never restyle the label.
- **Vendor Get-In** (`VendorGetInButtonStyle`): Accent background, black NVIDIA Sans
  bold (tracking 0.3), 16 horizontal padding, square corners. Pressed: accent @ 0.78.
  Two sizes: **regular** (14pt, height 36 — login and inline CTAs) and **large**
  (15pt, height 40 — hero and game-detail primary actions, optional `minimumWidth`).
  Call sites pass `uiScale` and never override font or frame on the label.

### Stream HUD Action Row (`StreamHUDActionRow`)

Icon-only square button: 42×38, 15pt bold SF Symbol, Row Fill background (0.14 hover),
1px Divider stroke. Active: accent background, black icon, accent @ 0.86 stroke.
Focused (gamepad/keyboard): accent stroke at 2px. Disabled: opacity 0.46.

### Stream Dialog Button (`StreamQuitMenuButton`)

Full-width rectangular button, height 38, NVIDIA Sans 12pt bold (tracking 0.4).

- **Primary**: Accent background (0.82 hover), black @ 0.86 text, accent stroke.
- **Secondary**: Row Fill background (0.14 hover), white @ 0.82 text (0.94 hover),
  Divider stroke.
- **Focused**: accent stroke at 2px. **Disabled**: opacity 0.46.

### Dropdown Menu (`MacForceNowDropdownMenu`)

Square dropdown replacing native `Menu` for every app-shell dropdown: game detail
"⋮" actions, catalog sort and filter groups, recordings sort, login provider picker.
Built from `MacForceNowDropdownPanel` + `MacForceNowDropdownRow`
(`View/Components/MacForceNowDropdown.swift`). Panel: Panel Raised background, 1px
Stroke Regular, 4 (Menu Panel Vertical) padding, width 208, leading-aligned to the
trigger and anchored 4pt below it, no shadow. Rows: full width, height 30, 12
(Control Row) horizontal padding, NVIDIA Sans 12pt bold — Text Secondary resting,
Text Primary + #FFFFFF @ 0.08 fill on hover. The selected row carries an accent
checkmark. Dismisses on outside click, Escape, or selection, and closes when the
underlying item set changes.

### Main Menu (app shell)

Full-height leading panel (`CatalogMainMenuPanel`), width 344, surface #171717 @
0.985, 1px white @ 0.10 trailing stroke, 2px accent bar along the top edge. Header
block: 22 horizontal, 20 (Large) top, 18 (Card) bottom — 11pt bold accent eyebrow
(tracking 1.4) over a 20pt bold title. Playtime card: Section Fill (#FFFFFF @ 0.055)
with 1px white @ 0.10 stroke, 14 padding, 18 (Card) horizontal / 14 (Content
Vertical) vertical margins. Sections: 10 (Section) horizontal margins, 14 (Content
Vertical) top spacing, 6 between rows. Section labels are eyebrows (10pt bold,
tracking 1.1, white @ 0.42) with 12 (Small) horizontal / 5 vertical padding. Rows
(`CatalogMainMenuRow`): height 50 (38 compact), 8 (X-Small) leading / 12 (Control
Row) trailing padding, 34×34 icon tile (accent fill when active, #FFFFFF @ 0.08
resting / 0.16 hover), 13 icon-to-text spacing, 14pt bold title over an 11pt medium
subtitle (white @ 0.52). Active row: accent @ 0.095 fill + 3px accent leading bar.
Destructive rows tint icon and title #FF8A80. Sign Out is pinned below a divider
with 10 (Section) horizontal / 12 (Small) vertical padding.

### Text Fields (login)

14pt regular white text, accent caret, 16 horizontal / 14 vertical padding, #FFFFFF
@ 0.08 background, 1px Stroke Regular. Focused: 2px accent stroke. Square corners.

### HUD Section (`hudSection`)

Section Fill background, 1px Divider stroke, 10 padding. Label is an eyebrow (10pt bold,
tracking 1.1, Text Tertiary). Used for CONTROLS, CO-OP, STATS, VIDEO panels.

### Metric Card (`hudMetricCard`)

Section Fill background, 1px Divider stroke, 10 padding, min height 58, equal width.
Label 9pt bold @ 0.46 white (tracking 0.7); value 12pt bold. Positive state tints the
value toward accent.

### HUD Dock (unified stream HUD)

Full-height leading dock, width `min(344, max(220, streamWidth * 0.72))`. Panel
background @ 0.985, 1px Divider trailing edge, 2px accent bar along the top edge, App
Bar header block, Divider-separated shortcut footer. The footer leads with a live clock
(accent 9pt clock symbol, 11pt bold Text Primary time, monospaced digits) stacked above
the 10pt bold shortcut hint line. Gamepad/keyboard focus moves across action rows with
accent focus strokes.

### Stream Modal Dialog (quit menu)

Centered 440-wide panel over a full-cover scrim (#000000 @ 0.54). Panel background
@ 0.985, 1px accent @ 0.28 stroke, 2px accent top bar. Header block: App Bar background,
eyebrow (10pt bold accent, tracking 1.1) over a 20pt bold title, 1px Divider below.
Body: 18 padding, 12pt medium Text Secondary description, then a row of Stream Dialog
Buttons. Escape (`.cancelAction`) maps to the primary dismiss action.

### Stats HUD

252-wide top-trailing panel, Panel background @ 0.92, 1px accent @ 0.28 stroke, 14
padding, eyebrow header, label/value stat rows (11pt).

### On-Screen Keyboard (`StreamOnScreenKeyboardOverlay`)

Bottom-anchored panel invoked in-stream with Steam + X (Steam Deck-style chord);
works on both the WebRTC and native NVST paths. Panel background @ 0.985, 2px accent
top bar, 1px Divider stroke. App Bar header strip holds the eyebrow label, a live
echo of recently typed text (12pt medium Text Primary, head-truncated), and accent
state badges for latched Shift and the symbols layer. The key grid is 10 columns ×
4 rows of square 46×40 keys (13pt bold, Row Fill resting background, 1px Divider
stroke), split between columns 5/6: each trackpad owns one half. Cursor highlights:
left pad = Accent Soft stroke + 0.28 fill, right pad = accent stroke + 0.28 fill,
d-pad/stick grid cursor = 2px Text Primary stroke. Latched Shift / active symbols
keys use the accent fill with black glyph. A bottom bar holds the layer toggle,
a wide space key, and the dismiss key, followed by a 9pt bold hint footer. Key
activation sends UTF-8 text events for characters and macOS keycode press/release
pairs for Return/Backspace, matching the physical-keyboard passthrough.

### Stream Launch Loading Screen (`StreamLaunchLoadingScreen`)

Full-cover black surface with blurred loading artwork, a top-to-bottom scrim
gradient, and an accent radial glow. Centered stack: signal indicator, 32pt bold
title (24 compact), eyebrow stage line (11pt bold, tracking 1.5, white @ 0.72) with
a glowing accent status dot, optional queue badge, Cancel button, and a 3px
indeterminate progress bar. The queue badge and Cancel button follow the standard
square spec — 1px Stroke Regular `Rectangle`s, no capsules: badge is black @ 0.48
with an accent @ 0.38 stroke (13pt bold, 14 horizontal padding, height 32); Cancel
is the Secondary button (white @ 0.08 fill, 13pt bold, 16 horizontal padding,
height 34). The embedded ad player accessory is a square `Rectangle` card with a
1px Stroke Regular and floating-layer shadow; its countdown badge is black @ 0.72,
square.

### Focus Ring (`openNowFocusRing`)

2px accent `Rectangle` stroke overlay on the focused control. Used for gamepad and
keyboard focus across the app and stream surfaces.

## Elevation

Flat by default — depth comes from 1px strokes and fill tints, not shadows. Shadows are
reserved for floating layers above the stream:

- **Floating control** (mic toggle): #000000 @ 0.18, radius 8, y 3.
- **Stats HUD**: #000000 @ 0.45, radius 24, y 12.
- **HUD dock**: #000000 @ 0.58, radius 28, x 14, y 20.
- **Modal dialog**: #000000 @ 0.58, radius 28, y 20.

## Guidelines

### Do

- Build every panel, button, field, and card as a `Rectangle` with a 1px stroke.
- Use NVIDIA Sans on all branded and stream surfaces; keep the size/weight scale above.
- Pull colors from `MacForceNowDesign` / `WebRTCMediaStreamTheme` tokens; express light
  tints as white opacities from the token tables.
- Reserve accent for primary actions, active/focused states, eyebrows, and edge bars.
- Indicate keyboard/gamepad focus with the 2px accent focus ring or accent stroke.
- Stack panels with Divider bars (1px, Stroke Subtle) instead of shadows.

### Don't

- Don't add corner radius, `Capsule`, or `RoundedRectangle` to stream HUD or app-shell
  chrome — the only radii are the documented exceptions.
- Don't use native SwiftUI `Menu` for app-shell overflow actions — it renders rounded
  system chrome; use the styled Overflow Menu dropdown instead.
- Don't use system rounded or monospaced font designs on new surfaces; they are legacy
  in the launch overlay, Twitch panel, and transient message pills only.
- Don't introduce new accent colors or hardcode hex values outside the token files.
- Don't use accent for large fills, backgrounds, or destructive actions.
- Don't rely on shadows for hierarchy on flat panels; use strokes and fill tints.

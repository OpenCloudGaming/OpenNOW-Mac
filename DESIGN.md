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

- **Accent** (#75E61A): NVIDIA green, `Color.openNowGreen` / `MacForceNowDesign.accent` /
  `WebRTCMediaStreamTheme.accent`. Primary actions, active states, focus rings, section
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

### Text

- **Text Primary** (#FFFFFF @ 0.96): Main content and values.
- **Text Secondary** (#FFFFFF @ 0.72): Supporting copy, dialog descriptions.
- **Text Tertiary** (#FFFFFF @ 0.52 app/stream, 0.48 legacy `gfnTextTertiary`): Section
  labels, row labels, footers.
- **Text Muted** (#FFFFFF @ 0.38): Disabled and placeholder text.

### Strokes

- **Stroke Subtle / Divider** (#FFFFFF @ 0.10): `Stroke.subtle` /
  `WebRTCMediaStreamTheme.divider`. Default 1px borders and divider bars.
- **Stroke Regular** (#FFFFFF @ 0.14): `Stroke.regular` / `Color.gfnStroke`. Interactive
  element borders (buttons, fields, pickers).
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

- **Page Horizontal**: 40 — page content margins.
- **Rail Horizontal**: 32 — sidebar/rail padding.
- **Card**: 18 — card internal padding.

### Stream HUD

- **Dock header**: 22 horizontal, 16 top, 14 bottom.
- **Dock content**: 18 horizontal, 14 vertical; 14 between sections.
- **Section**: 10 padding; 8–10 internal spacing.
- **Metric card**: 10 padding; 5 internal spacing.
- **Action row grid**: 8 between buttons.
- **Dialog body**: 18 padding; 16 between description and actions.
- **Footer**: 18 horizontal, 9 vertical.

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
- **Vendor Get-In**: Accent background, black NVIDIA Sans 14pt bold, height 36,
  16 horizontal padding. Pressed: accent @ 0.78.

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
Bar header block, Divider-separated shortcut footer. Gamepad/keyboard focus moves across
action rows with accent focus strokes.

### Stream Modal Dialog (quit menu)

Centered 440-wide panel over a full-cover scrim (#000000 @ 0.54). Panel background
@ 0.985, 1px accent @ 0.28 stroke, 2px accent top bar. Header block: App Bar background,
eyebrow (10pt bold accent, tracking 1.1) over a 20pt bold title, 1px Divider below.
Body: 18 padding, 12pt medium Text Secondary description, then a row of Stream Dialog
Buttons. Escape (`.cancelAction`) maps to the primary dismiss action.

### Stats HUD

252-wide top-trailing panel, Panel background @ 0.92, 1px accent @ 0.28 stroke, 14
padding, eyebrow header, label/value stat rows (11pt).

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
- Don't use system rounded or monospaced font designs on new surfaces; they are legacy
  in the launch overlay, Twitch panel, and transient message pills only.
- Don't introduce new accent colors or hardcode hex values outside the token files.
- Don't use accent for large fills, backgrounds, or destructive actions.
- Don't rely on shadows for hierarchy on flat panels; use strokes and fill tints.

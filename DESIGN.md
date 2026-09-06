# OpenNOW Design System

Squared, panel-based dark interface echoing the GeForce NOW industrial aesthetic: flat
surfaces, 1px strokes, a single NVIDIA green accent, and NVIDIA Sans typography. Corner
radius is reserved for a small set of explicit exceptions — panels, buttons, and fields
are always plain rectangles.

Token sources of truth:

- App shell: `View/OpenNOWDesign.swift` (`OpenNOWDesign`), `View/Login/LoginStyles.swift`
- Stream HUD: `OPN/Stream/WebRTCMediaStreamSurface.swift` (`WebRTCMediaStreamTheme`)
- Typography: `View/Design/OpenNOWNVIDIAFont.swift` (`OpenNOWNVIDIAFont`)

## Colors

### Brand

- **Accent** (#75E61A): NVIDIA green, `OpenNOWDesign.accent` /
  `WebRTCMediaStreamTheme.accent`. Primary actions, active states, focus rings, section
- **Destructive** (#FF8980): `OpenNOWDesign.Semantic.destructive`. Destructive menu
  roles, end-stream actions, error accents.
  eyebrows, top edge bars. Never used for large backgrounds.
- **Accent Soft** (#ABFF5C): `WebRTCMediaStreamTheme.accentSoft`. Status text on the
  stream launch overlay only.

### Surfaces

- **App Background** (#191919): `OpenNOWDesign.Surface.app`. Root window background.
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

- **Warning** (#FF9500, system orange): `WebRTCMediaStreamTheme.warning` on the stream HUD,
  `OpenNOWDesign.Semantic.warning` on the app shell. Low battery, unsaved edits, degraded
  states, validation messages. The same condition uses the same colour on both surfaces.
- **Danger** (#FF0000, system red): `WebRTCMediaStreamTheme.danger`. Live badges and
  destructive-state indicators. Destructive dialog actions still use the standard
  secondary button style.

## Typography

Typeface is **NVIDIA Sans** in three weights, bundled as WOFF2 and loaded through
`OpenNOWNVIDIAFont` (falls back to the system font at the matching weight if the
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

### App Shell (`OpenNOWDesign.Spacing`)

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

- **Token**: `OpenNOWInterfacePreferences.uiScale` (`OpenNOW.Interface.UIScale`),
  Double in 0.75–2.0, default 1.0. Always read/write through `clampedUIScale(_:)`.
- **Mechanism**: `.opnInterfaceScale(_:)` (`View/OpenNOWDesign.swift`) lays
  content out in a reduced logical space, then applies `scaleEffect` so chrome reflows
  larger instead of cropping. Never apply plain `scaleEffect` to chrome without the
  compensating frame, and never scale the video surface itself.
- **Text fidelity**: `scaleEffect` alone rasterizes text at display density and upscales
  the bitmap (progressively blurrier as scale grows). `OpenNOWInterfaceScaleDensityBooster`
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
- **Avatar**: 14 (`OpenNOWDesign.Radius.avatar`).
- **Exceptions**: circular mic toggle and status dots on the stream surface, login vendor
  icon buttons (`size * 0.32`), and the controller diagram artwork
  (`SteamControllerDiagramView`), which traces physical hardware — round face buttons, pill
  grips, oval trackpads — rather than chrome. Everything laid out *around* that drawing,
  including its 2px accent selection ring, stays square. New UI must not add further
  exceptions.

## Components

### Buttons (app shell)

- **Primary**: Accent background, black 14pt bold text (tracking 0.4), 14 vertical /
  16 horizontal padding, square corners. Pressed: accent @ 0.76.
- **Secondary**: #FFFFFF @ 0.08 background (0.16 pressed), 1px Stroke Regular, white
  13–14pt bold text, square corners.
- **Compact Row Action** (`OpenNOWCompactButtonStyle`): settings/inline row
  actions. Height 28, NVIDIA Sans 12pt bold, 14 horizontal padding, square corners.
  Primary: accent background (0.78 pressed), black text, accent stroke. Destructive:
  #000000 @ 0.35 background (0.5 pressed), white text, red @ 0.85 stroke. Takes
  `uiScale`; call sites never restyle the label.
- **Vendor Get-In** (`VendorGetInButtonStyle`): Accent background, black NVIDIA Sans
  bold (tracking 0.3), 16 horizontal padding, square corners. Pressed: accent @ 0.78.
  Two sizes: **regular** (14pt, height 36 — login and inline CTAs) and **large**
  (15pt, height 40 — hero and game-detail primary actions, optional `minimumWidth`).
  Call sites pass `uiScale` and never override font or frame on the label.

### Control Heights (recordings editor)

One row, one height. Mixed heights on a single line read as a broken layout however good the
spacing is, and the eye catches a two-point difference. Three tiers, in
`RecordingEditorMetrics`; everything on a line uses its line's tier.

- **Header row** (36, `RecordingEditorMetrics.headerControlHeight`): the page header above the
  video — the recording's actions and the editor's. `RecordingActionButtonStyle.height` is this
  value, and the editor's title field matches it rather than picking its own.
- **Timeline control row** (40, `.controlHeight`): transport buttons, the timecode readout, the
  edit actions. Taller than the header tier on purpose — this row runs to the window's bottom
  edge with no padding beneath it, so the height is the hit target.
- **Advanced panel** (28, `.compactControlHeight`): small buttons, dropdown triggers, chip
  pickers.

### Borders on Filled Controls

Use `Rectangle().strokeBorder(...)`, never `Rectangle().stroke(...)`, on anything with a
background.

A stroke is centred on the path, so it spills half a point outside the frame. Where the border is
low-contrast that spill is invisible and the control measures its stated height. Where the border
matches the fill — an accent-filled primary button with an accent stroke — the spill paints as
more control, and the button measures a point taller than the identically-sized ones beside it.
`strokeBorder` insets the line, so every tone paints exactly its frame.

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

### Dropdown Menu (`OpenNOWDropdownMenu`)

Square dropdown replacing native `Menu` for every app-shell dropdown: game detail
"⋮" actions, catalog sort and filter groups, recordings sort, login provider picker.
Built from `OpenNOWDropdownPanel` + `OpenNOWDropdownRow`
(`View/Components/OpenNOWDropdown.swift`). Panel: Panel Raised background, 1px
Stroke Regular, 4 (Menu Panel Vertical) padding, minimum width 208 (expands to the
trigger's width when the trigger is wider, e.g. the login provider picker),
leading-aligned to the trigger and anchored 4pt below it, no shadow. When the panel would extend past the
window's bottom edge it constrains to the available space below and scrolls.
Rows: full width, height 30, 12
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

### Login Wall Layout

The login panel is marketing-only: logo, eyebrow, headline, marketing bullets, and a
large GET IN CTA that opens the Sign-In Modal. The column never scrolls; it is built
with `ViewThatFits(in: .vertical)` over full, no-bullets, and compact (smaller logo
and headline) variants and renders the first that fits the window height, vertically
centered in the panel.

### Sign-In Modal (login)

Centered dialog over the Scrim, up to 520 wide, following the modal spec: Surface
Panel background, 1px Stroke Regular, 2px accent top bar, modal shadow (#000000 @
0.58, radius 28, y 20), 24 (X-Large) body padding. Width shrinks to the window
minus 40 (Page Horizontal) margins on narrow windows (floor 280); when the form
exceeds the window height the title and close control stay pinned and the body
scrolls. Holds the 20pt bold title with trailing
close control, SERVICE PROVIDER cards stacked full-width, the GET IN primary (full
width) over the BROWSER SIGN-IN text action, device-code block, and validation
line. Closes via the square 28×28 close control
(xmark, Text Secondary resting / Text Primary + #FFFFFF @ 0.08 hover) trailing in
the title row, a click on the scrim, or Escape. The Terms of Use dialog stacks
above it on first sign-in and opens the modal on accept.

While an OAuth launch is pending, the full-cover connecting splash overlays the
window with a square Cancel button (white @ 0.08 fill, 1px Stroke Regular, 13pt
bold, height 34) that aborts the pending sign-in and returns to the modal. The
device-code flow clears the splash as soon as the code is ready so the code stays
visible.

### Provider Card (login)

Selectable square card for each service provider inside the Sign-In Modal, stacked
vertically at full modal width. 14pt bold title over an 11pt Text Tertiary
provider code, 12 (Control Row) horizontal padding, min height 50. Resting: #FFFFFF @ 0.08 fill, 1px Stroke
Regular. Hover: #FFFFFF @ 0.16 fill, 1px Stroke Strong. Selected: 2px accent
stroke, accent checkmark trailing, and the `.isSelected` accessibility trait.
Square corners.

### Release Notes List (`OpenNOWReleaseNotesView`)

Shared renderer for parsed GitHub release notes (`View/Components/OpenNOWReleaseNotes.swift`),
used by the Update Modal and the What's New card. Section header is an eyebrow (10pt bold,
tracking 1.1, Text Tertiary) with a trailing entry count in Text Muted; the settings density
prefixes it with a 3×12 accent bar. Entries are a 3×3 accent square marker (top-aligned to the
first line) over 12pt (modal) / 13pt (settings) medium Text Secondary text with 2pt line
spacing. Commit SHA, pull request, and author render as trailing chips: 9–10pt bold Text Muted
(Text Secondary on hover), 8 horizontal padding, height 18, #FFFFFF @ 0.05 fill (0.10 hover),
1px Stroke Subtle, opening the GitHub URL on click. `entryLimit` truncates a section to N
entries behind an accent `+N MORE` action (10pt bold, tracking 0.7); the modal passes nil and
scrolls instead. Inline markdown (bold, links) is resolved at parse time; links tint accent.

### Update Modal (`OpenNOWUpdateModal`)

Centered dialog over the Scrim following the modal spec, mounted at the app root so it reaches
the catalog, login wall, and stream surface alike. Up to 560 wide, shrinking to the window minus
2 × 40 (Page Horizontal) with a 280 floor. 2px accent top bar; App Bar header block (18
horizontal, 16 vertical) holding the eyebrow (10pt bold accent, tracking 1.1: UPDATE AVAILABLE /
UP TO DATE / UPDATE CHECK FAILED / UPDATE INSTALL FAILED), a 20pt bold title, a 12pt medium Text
Secondary subtitle (installed version · release date · download size), and the square 28×28
close control. 1px Divider, then an 18-padded body: the Release Notes List inside a ScrollView
capped at min(340, half the window height), or a 12pt medium message for the status variants.
1px Divider, then a footer (18 horizontal, 12 vertical) with the accent VIEW ON GITHUB text
action leading and LATER (`OpenNOWModalSecondaryButtonStyle`, height 36 — defers the
prompt for a day) plus
INSTALL AND RELAUNCH (`VendorGetInButtonStyle`) trailing.

While installing, a Section Fill block with a 1px Divider stroke sits under the notes: DOWNLOADING
or INSTALLING eyebrow, an 11pt bold byte readout, and a 3px progress bar — determinate as two
Rectangles (accent over #FFFFFF @ 0.10), or `VendorIndeterminateProgressBar` when the server
sends no content length. Buttons and the close control disable for the duration.

### Settings Destination Rail (`SettingsSidebar`)

The desktop Settings navigation: a 208-wide column of 36-high rows, 14 horizontal padding, 16pt
glyph then a 13pt label. Selected is accent @ 0.12 fill with a 3-wide accent bar on the leading
edge; hover is white @ 0.05. Below 900pt of window width per interface scale the labels drop and
the rail narrows to 60, glyphs only, each row keeping its title as a tooltip. The rail is desktop
only: controller mode renders `SettingsTabBar` instead, because its shell already carries a
horizontal row of destination pills and pad focus is a single top-to-bottom list.

### Settings Card Columns (`SettingsColumns`)

Two independent card columns, 16 gutter, above `narrowRowWidth * 2 + gutter` of card width per
interface scale - derived rather than picked, so a split never produces columns too narrow to hold a
row's label beside its control, which would be the one-column layout at half the measure one column below that, and always one column under pad focus. Columns are independent, not a grid: a grid row stretches to its taller
card and leaves a hole whenever a pair differs. Cards inside the columns get
`opnSettingsNarrowRows`, which moves a row's control under its label instead of beside it.

### Settings Disclosure Card (`SettingsDisclosureCard`)

A `SettingsCollapsibleCard` whose open state persists under `OpenNOW.Settings.Expanded.<key>`. For a
block most readers never open: an advanced set, a diagnostics dump, a statistics panel. The header is
itself a focusable row, so a pad can open the card; without that every setting inside it is reachable
only with a pointer.

### Settings Subheading (`SettingsSubheading`)

Names a block inside a card: 10pt bold, tracking 1.0, white @ 0.44, with the block's own content
below it. Use it instead of a second `SettingsCard` when the blocks belong to one subject and a
card each would read as separate objects and spend a header of height saying so. The folded system
report is the reference case.

### Settings Labs (`LabsSettingsPage`, `OpenNOWLabs`)

Features on trial live on their own destination, always drawn so people can learn where to look.
With `OpenNOWLabs.flags` empty the page is its own empty state: a 132 accent-ringed flask with three
bubbles at its neck over "Nothing in flight", centred in the pane. That state names itself, so
`isEmptyStatePage` drops the page header and the scroll view for it - two titles would compete.
Each flag names itself, says what it turns on and when it went on trial, and stores itself under
`OpenNOW.Labs.<id>`. The card carries the EXPERIMENTAL badge.

A card that belongs to its own destination's subject but is not finished keeps its badge there
instead; the badge marks maturity in place, and is not a substitute for a home.

### Settings Search (`SettingsSearchField`, `SettingsSearchResults`)

A 30-high field at the top of the destination rail, 10 horizontal padding, white @ 0.07 fill, white
@ 0.12 border that becomes accent @ 0.44 while focused. Two characters start a search; the results
take the rail's place until the field is cleared. Each result is a 12.5pt title over a 10.5pt
`Destination › Card` line, from the section names each destination declares, with the same 3-wide accent leading edge the rail rows use on hover.
Desktop only: it is absent from the icons-only rail and from controller mode, where nothing on
screen may be unreachable by a pad.

### Settings Card Badge (`SettingsCardBadge`, `SettingsCardTag`)

`SettingsCard(title:badge:uiScale:)` renders BETA or EXPERIMENTAL beside the card title, 8pt bold,
tracking 0.7, accent @ 0.78 on accent @ 0.12. Scope is the card. A destination in
`SettingsTabBar.betaGroups` wears the tag in the rail instead, and only when every card on it is
beta - one unsettled card in a settled tab is a card badge, not a destination tag.

### Tags (`OpenNOWBetaTag`, `OpenNOWNewTag`)

Two annotations ride inside another control's title and must not outweigh it: 8pt bold, tracking
0.7, 4pt leading / 3.3pt trailing / 2pt vertical padding, square corners. The trailing padding is
short by exactly the tracking, because letter-spacing is applied after the last glyph too and an
even 4/4 leaves the label sitting left of centre in its box. Tracking scales with the interface like
the padding it is subtracted from. **BETA** is accent text on a 12 % accent
tint (compact) for shipped-but-rough features. **NEW** is black text on solid accent for a setting
added in the current release; rows opt in with `isNew:` and declare their release in
`OpenNOWNewSettings.Row`, which hides the tag once the setting is changed or the next release ships.

### What's New Card (Settings → About)

`SettingsCard` holding release history (`View/Settings/SettingsWhatsNewViews.swift`). When an
update is pending, a strip leads the card: 4×32 accent bar, version with an accent AVAILABLE
badge (9pt bold black on accent, height 18), installed-version and size subtitle, and a VIEW
UPDATE `SettingsActionButton` that raises the Update Modal. Release rows are chevron + 14pt bold
version + neutral INSTALLED badge (#FFFFFF @ 0.08 fill, Text Secondary) + date + entry count;
clicking one expands the Release Notes List at settings density, indented 22, limited to 5
entries per section. Rows are separated by `SettingsDivider`, and the card ends with an
OPEN RELEASES ON GITHUB secondary action.

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

### Steam Controller Sheets (test / mapping)

The two controller sheets (`SteamControllerTestView`, `SteamControllerMappingView`) are
full-window settings-style flows on Surface Deep, wrapped in the modal spec: 2px accent top bar
(`SteamControllerModalTopBar`), App Bar header block (`SteamControllerModalHeader` — 10pt bold
accent eyebrow "STEAM CONTROLLER", tracking 1.1, over a 20pt bold title, with the shared square
28×28 `OpenNOWModalCloseButton`), 18 (Card) horizontal / 16 (Medium) vertical header padding, and
1px Stroke Subtle rules (`SteamControllerModalRule`) between every band. Escape dismisses both.
Every size is pre-scale and multiplied by `opnUIScale`, which the sheets read from the
environment; hairline rules stay 1px at all scales.

Shared square pieces live in `SteamControllerModalChrome.swift`:

- **Chip** (`SteamControllerChip`): square selectable, Row Fill (#FFFFFF @ 0.075) resting / 0.14
  hover / accent + black label when selected, 1px Stroke Subtle (accent when selected), 12
  (Control Row) horizontal padding. Heights 26 (chord chips), 28 (default), 30 (list rows).
  Disabled: opacity 0.46.
- **Option Picker** (`SteamControllerOptionPicker`): the square stand-in for
  `.pickerStyle(.segmented)` and `.pickerStyle(.menu)` — a `SettingsFlowLayout` row of chips at 8
  (X-Small) spacing. Native pickers are not used on these surfaces.
- **Value Bar** (`SteamControllerValueBar`): 8-high square bar, Row Fill track, accent fill.
  Signed axes grow from a Stroke Regular centre tick; unsigned ones from the leading edge.
- **Status Marker** (`SteamControllerStatusMarker`): 8×8 square — accent connected, Semantic
  Destructive disconnected. No glow. The circular status dot stays a stream-surface exception.
- **Badge** (`SteamControllerBadge`) and **Section** (`SteamControllerSection`): Section Fill
  (#FFFFFF @ 0.055) with a 1px Stroke Subtle; the badge is height 20 with 8 padding, the section
  18 (Card) padding under an eyebrow header.

Mapping-specific chrome: the profile picker is an `OpenNOWDropdownMenu` (trigger height 30, Row
Fill, 1px Stroke Regular), the profile name is a 14pt regular field on Surface Field with a 2px
accent focus stroke, and the category sidebar (width 168) follows the Main Menu row spec — height
30, 12 (Control Row) padding, white 0.08 on hover, accent @ 0.095 fill with a 3px accent leading
bar when active. The footer carries a `Semantic.warning` "UNSAVED CHANGES" eyebrow, CANCEL
(`OpenNOWModalSecondaryButtonStyle`, `.cancelAction`) and SAVE (`VendorGetInButtonStyle`,
`.defaultAction`, opacity 0.46 while there is nothing to save). Row actions elsewhere in the bar
use `OpenNOWCompactButtonStyle`.

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

## Enforcement

Seven SwiftLint custom rules in `.swiftlint.yml` check the "Don't" list mechanically over `View/`:
`design_no_corner_radius`, `design_no_native_picker`, `design_no_system_font_design`,
`design_no_raw_semantic_color`, `design_no_accent_glow_shadow`, `design_no_native_divider`,
`design_no_hardcoded_surface_color`. They are regex rules, so they read text, not intent:

- A genuine documented exception is annotated at the site —
  `// swiftlint:disable:next design_no_corner_radius` plus the reason — which keeps the exception
  list visible in review. The controller diagram disables the radius rule file-wide for its
  artwork; the login vendor icon annotates its one line.
- Surfaces that predate the rules are grandfathered in `.swiftlint-baseline.json`, not exempted:
  the tree still reports them when the baseline is dropped, and each one is a burn-down item.
- Token files (`OpenNOWDesign.swift`, `StreamHUDComponents.swift`, `SettingsView.swift`,
  `LoginStyles.swift`, `OpenNOWButtons.swift`) are excluded where they define the literals the
  rules ban elsewhere — that is where a colour or font is allowed to be spelled out.

## Guidelines

### Do

- Build every panel, button, field, and card as a `Rectangle` with a 1px stroke.
- Use NVIDIA Sans on all branded and stream surfaces; keep the size/weight scale above.
- Pull colors from `OpenNOWDesign` / `WebRTCMediaStreamTheme` tokens; express light
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

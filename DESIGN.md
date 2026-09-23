# OpenNOW Design System

Squared, panel-based dark interface echoing the GeForce NOW industrial aesthetic: flat
surfaces, 1px strokes, a single NVIDIA green accent, and Hanken Grotesk typography. Corner
radius is reserved for a small set of explicit exceptions — panels, buttons, and fields
are always plain rectangles.

Token sources of truth:

- App shell: `View/OPNDesign.swift` (`OPNDesign`), `View/Login/LoginStyles.swift`
- Stream HUD: `View/Stream/StreamHUDComponents.swift` (`StreamHUDTheme`)
- Typography: `View/Design/OPNUIFont.swift` (`OPNUIFont`)

## Colors

### Brand

- **Accent** (#75E61A): NVIDIA green, `OPNDesign.accent` /
  `StreamHUDTheme.accent`. Primary actions, active states, focus rings, section
  eyebrows, top edge bars. Never used for large backgrounds.
- **Destructive** (#FF8980): `OPNDesign.Semantic.destructive`. Destructive menu
  roles, end-stream actions, error accents.
- **Favorite** (#FF4D94): `OPNDesign.Semantic.favorite`. The favorite toggle only.
  Deliberately not the accent: beside an accent-filled Play button, an accent-filled heart
  reads as a second primary action rather than a state you can switch off.
- **Accent Soft** (#ABFF5C): `StreamHUDTheme.accentSoft`. Status text on the
  stream launch overlay only.

### Surfaces

- **App Background** (#191919): `OPNDesign.Surface.app`. Root window background.
- **App Bar** (#2D2D2D): `Surface.appBar` / `StreamHUDTheme.appBar`. Header bands
  on docks, dialogs, and panels.
- **Panel** (#1C1C1C app, #171717 stream): `Surface.panel` / `StreamHUDTheme.panel`.
  Cards, docks, and dialog bodies.
- **Panel Raised** (#222222): `Surface.panelRaised` / `StreamHUDTheme.surfaceRaised`.
  Nested or elevated panels, gradient stops.
- **Tile Tray** (#292929): `Surface.tileTray`. Grid/tile containers in the catalog.
- **Field** (#1F1F1F): `Surface.field`. Input backgrounds on app-shell forms.
- **Scrim** (#000000 @ 0.58 app, 0.54 stream): `Surface.scrim` /
  `StreamHUDTheme.scrim`. Full-cover dim behind modals and overlays.
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
  `StreamHUDTheme.divider`. Default 1px borders and divider bars.
- **Stroke Regular** (#FFFFFF @ 0.14): `Stroke.regular`. Interactive element borders
  (buttons, fields, pickers).
- **Stroke Strong** (#FFFFFF @ 0.22): `Stroke.strong`. Emphasized borders, hover states.

### Fill Tints (stream HUD)

- **Row Fill** (#FFFFFF @ 0.075): Resting background of interactive rows and buttons;
  0.14 on hover.
- **Section Fill** (#FFFFFF @ 0.055): Background of HUD sections and metric cards.

### Semantic

- **Warning** (#FF9500, system orange): `StreamHUDTheme.warning` on the stream HUD,
  `OPNDesign.Semantic.warning` on the app shell. Low battery, unsaved edits, degraded
  states, validation messages. The same condition uses the same colour on both surfaces.
- **Danger** (#FF0000, system red): `StreamHUDTheme.danger`. Live badges and
  destructive-state indicators. Destructive dialog actions still use the standard
  secondary button style.

## Typography

Typeface is **Hanken Grotesk** (SIL Open Font License 1.1) in three weights, bundled as
WOFF2 and loaded through `OPNUIFont` (falls back to the system font at the matching
weight if the bundle resource is unavailable). SwiftUI accessor: `.opnUI(size:weight:)`;
per-surface helpers wrap it (`catalogFont`, `streamFont`, `settingsFont`, `recordingsFont`,
`LoginStyles.uiSans`). The bundled static instances are Regular (400), Medium (500), and
Bold (700); see `Resources/Fonts/OFL.txt` for the license.

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
- Login vendor surfaces use Hanken Grotesk 14pt bold; general app-shell controls may use the
  system font at the same sizes when the Hanken Grotesk face is not required.

System rounded/monospaced fonts remain only in legacy stream overlays (Twitch panel,
transient message pills). Do not use them in new code.

## Spacing

### App Shell (`OPNDesign.Spacing`)

**Scale** — 4pt-grid values for generic layout spacing. Each exists as an unscaled
static let and a `scale:`-parameterized function; use the function on surfaces that
multiply by `opnUIScale`.

| Token | Value | | Token | Value |
| --- | --- | --- | --- | --- |
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

- **Token**: `OPNInterfacePreferences.uiScale` (`OpenNOW.Interface.UIScale`),
  Double in 0.75–2.0, default 1.0. Always read/write through `clampedUIScale(_:)`.
- **Mechanism**: `.opnInterfaceScale(_:)` (`View/OPNDesign.swift`) lays
  content out in a reduced logical space, then applies `scaleEffect` so chrome reflows
  larger instead of cropping. Never apply plain `scaleEffect` to chrome without the
  compensating frame, and never scale the video surface itself.
- **Text fidelity**: `scaleEffect` alone rasterizes text at display density and upscales
  the bitmap (progressively blurrier as scale grows). `OPNInterfaceScaleDensityBooster`
  (mounted once at the `ContentView` root) keeps every non-Metal window layer's
  `contentsScale` pinned at `uiScale × window.backingScaleFactor` via a run-loop observer,
  forcing SwiftUI to re-render text and vector content at zoom density. It skips
  `CAMetalLayer` (the stream video) and restores natural density at 100 %. Layers with
  direct bitmap content (game art, `ImageLayer`) are never display-invalidated —
  re-rendering would blank them; only empty or re-renderable (`CGDrawingLayer`) layers
  are redrawn. Never bypass it with per-layer `contentsScale` edits elsewhere.
- **Applied to**: catalog chrome including controller mode and overlays (`CatalogView`
  non-stream branch), the login window (`LoginView`), and the stream HUD chrome layer
  (`nativeUnifiedHUD` in `NativeNVSTMediaStreamSurface`). Full-bleed backdrops and transient
  splash/loading screens stay at 100 %.
- **Setting**: Settings → General → Interface → Display, "Interface Scale" slider
  (5 % steps, shown as a percentage).

## Radius

- **Default**: 0 — panels, docks, dialogs, buttons, fields, and cards are plain
  `Rectangle`s with 1px strokes. No `RoundedRectangle`, no `Capsule`.
- **Avatar**: 14 (`OPNDesign.Radius.avatar`).
- **Exceptions**: circular mic toggle and status dots on the stream surface, login vendor
  icon buttons (`size * 0.32`), and the controller diagram artwork
  (`SteamControllerDiagramView`, `DualShock4DiagramView`, `GenericControllerDiagramView`), which traces physical
  hardware — round face buttons, pill grips, oval trackpads, circular stick wells — rather
  than chrome. Everything laid out *around* those drawings, including the 2px accent
  selection ring, stays square. New UI must not add further exceptions.

## Components

### Buttons (app shell)

- **Primary**: Accent background, black 14pt bold text (tracking 0.4), 14 vertical /
  16 horizontal padding, square corners. Pressed: accent @ 0.76.
- **Secondary**: #FFFFFF @ 0.08 background (0.16 pressed), 1px Stroke Regular, white
  13–14pt bold text, square corners.
- **Destructive Modal** (`OPNModalDestructiveButtonStyle`): a modal footer's destructive
  action, sized to sit beside the secondary modal button. 36 high, 13pt bold
  `Semantic.destructive` label, destructive @ 0.10 fill (0.18 pressed), destructive @ 0.36
  stroke. Never the default action.
- **Compact Row Action** (`OPNCompactButtonStyle`): settings/inline row
  actions. Height 28, Hanken Grotesk 12pt bold, 14 horizontal padding, square corners.
  Primary: accent background (0.78 pressed), black text, accent stroke. Destructive:
  #000000 @ 0.35 background (0.5 pressed), white text, red @ 0.85 stroke. Takes
  `uiScale`; call sites never restyle the label.
- **Vendor Get-In** (`VendorGetInButtonStyle`): Accent background, black Hanken Grotesk
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

### Recording Fact Pill (`RecordingPill`)

One recording fact as a 20-high square chip: 9pt bold Hanken label, 7 horizontal padding, Stroke
Subtle fill at rest and accent when active (label black @ 0.86 over accent), 1px `strokeBorder` in
the matching tone. Library rows carry duration, quality and size in that order; the retained replay
rows and the watched-window header carry the same three, so a window's quality is readable before it
is kept. The label comes from `RecordingFormat.qualityText`, which maps the encoded shape to 4K /
1440p / 1080p / `<height>p` / Auto and therefore takes a raw width and height: a replay window is a
ring of files and has no `StreamRecording` of its own.

### Retained Replay Section (`RetainedReplaySection`, `RetainedReplayRow`)

Recordings: the replay windows finished streams left on disk, above the library because they are the
footage from the sessions just played. The header is a Text Muted eyebrow with the store's usage
(`used of limit`) on the trailing edge. Each row is a raised fill with a 1px Stroke Subtle, a play
glyph, the game title, a three-pill fact row (`RecordingPill`: duration, quality, size) and three
26-high square actions: **CLIP** (filled accent with `OPNDesign.onAccent` — the ink for text on an
accent fill, not `accentInk`, which is the accent as text on the page and resolves to the accent
itself in the dark palette), **SAVE ALL** and **DISCARD** (both outlined). The actions disable while
a whole-window save runs, and the row then reads "Saving…".

The facts block is the play control, not a fourth action: pressing it composes the whole ring and
plays it in the player pane, so the footage can be watched before any of the three actions is
chosen. While it plays the row strokes accent and the glyph becomes a pause; pressing it again
stops. The pane header becomes `RetainedReplayPreviewHeader` — "REPLAY WINDOW", the title, the same
fact pills, and **BACK TO LIBRARY** — because the window is not a library recording, so
`RecordingInspector`'s Open/Reveal/Delete would not apply to a ring.

**CLIP** opens the quick editor over the ring: each segment file becomes one timeline clip in capture
order, so a trim cuts across the whole window rather than only its last file. A multi-file ring
always re-encodes (the exporter's passthrough needs a single segment from the head of one file), so
**SAVE ALL** remains the cheap whole-window path.

One window is shown per title: it has no expiry, and the next session of that title rolls it forward
rather than replacing it. The whole store is held to the Storage Budget the settings page sets,
oldest title first — only a single title larger than the budget has its own oldest footage cut.
DISCARD and SAVE ALL refuse while that window's own edit is open, and if the budget evicts a window
that is being watched or edited, the pane returns to the library rather than failing later on the
missing files.

### Screenshot Quick Edit (`ScreenshotEditorView`, `ScreenshotSelectionOverlay`)

The screenshot's Edit action opens an inline QUICK EDIT header with the BETA tag. Its square
36-high controls wrap with the available width: Select, Crop, Undo, Redo, Reset, Cancel, and the
accent Save as New Screenshot action. Select offers Select All and Clear Selection. The status
line shows the selection's pixel dimensions or the output size; a pending selection must be
cropped or cleared before saving. Cancel closes the draft, and Save creates a new PNG with the
source's application and album membership.

The image stays aspect-fit. A rectangular selection dims the surrounding image with Surface Scrim,
uses an accent outline and eight 10-point square handles with 20-point hit targets, and carries
thirds guides in Stroke Strong. Drag outside the selection to replace it, inside to move it, or
on a handle to resize it. Arrow keys move by one source pixel, Option-arrow resizes, and Shift
uses ten-pixel steps. All chrome dimensions scale with `opnUIScale`; image coordinates remain
source pixels. The library is inactive during the edit so the draft stays associated with its image.

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

Full-width rectangular button, height 38, Hanken Grotesk 12pt bold (tracking 0.4).

- **Primary**: Accent background (0.82 hover), black @ 0.86 text, accent stroke.
- **Secondary**: Row Fill background (0.14 hover), white @ 0.82 text (0.94 hover),
  Divider stroke.
- **Focused**: accent stroke at 2px. **Disabled**: opacity 0.46.

### Dropdown Menu (`OPNDropdownMenu`)

Square dropdown replacing native `Menu` for every app-shell dropdown: game detail
"⋮" actions, catalog sort and filter groups, recordings sort. Built from
`OPNDropdownPanel` + `OPNDropdownRow`
(`View/Components/OPNDropdown.swift`). Panel: Panel Raised background, 1px
Stroke Regular, 4 (Menu Panel Vertical) padding, minimum width 208 (expands to the
trigger's width when the trigger is wider), leading-aligned to the trigger and
anchored 4pt below it, no shadow. `visibleItemCount` caps the panel at that many
rows (30 each) and scrolls the rest, with 12pt of trailing content margin so the
scroll indicator clears the row text. When the panel would extend past the
window's bottom edge it constrains to the available space below and scrolls.
Rows: full width, height 30, 12
(Control Row) horizontal padding, Hanken Grotesk 12pt bold — Text Secondary resting,
Text Primary + #FFFFFF @ 0.08 fill on hover. A destructive row (`isDestructive`) reads
`Semantic.destructive` in every state; a row that `startsGroup` carries a 1px Stroke Subtle
rule above it, spaced by 4 (X-Small) above and below. The selected row carries an accent
checkmark. Dismisses on outside click, Escape, or selection, and closes when the
underlying item set changes.

### Context Menu (`OPNContextMenuOverlay`)

The custom replacement for SwiftUI's `.contextMenu`, which renders rounded macOS menu chrome
(`View/Components/OPNContextMenu.swift`). The surface that owns the rows registers itself as the
anchor (`OPNContextMenuHost`) in an `OPNContextSurface` and each row registers its view
(`OPNContextRowAnchor`). One local event monitor on the host catches right-clicks and
Control-clicks — a monitor, not a hit-testing view, so left clicks, drags, and hover are untouched.
It resolves the click to a row and the surface coordinate only when a click happens, so there is no
per-scroll-frame measurement, and a click inside the surface that misses every row dismisses while
one outside it dismisses and is passed through. The owner then presents `OPNContextMenuOverlay` as
an overlay on that surface, so a row's scroll view cannot clip it. The menu is an `OPNDropdownPanel`
at its 208 minimum width, anchored at the pointer, clamped to the surface, and flipped above the
pointer when it would not fit below. Outside click or Escape dismisses; there is no scrim, matching
the Dropdown Menu.

The sign-in modal's provider picker renders `OPNDropdownPanel` inline instead
(expanding below the trigger, uncapped), because an overlay panel inside the
modal's nested scroll containers loses sibling z-order and paints behind the tab
content. The modal itself is height-capped to the window and owns the only
scrollbar — a second, inner one for the picker produced double scroll bars.
Rows: full width, height 30, 12
(Control Row) horizontal padding, Hanken Grotesk 12pt bold — Text Secondary resting,
Text Primary + #FFFFFF @ 0.08 fill on hover. The selected row carries an accent
checkmark. Dismisses on outside click, Escape, or selection, and closes when the
underlying item set changes.

### Collection Icon Picker (`OPNCollectionIconView`, `CatalogCollectionIconPickerOverlay`)

Every collection draws its glyph through one component, `OPNCollectionIconView`, so a symbol and a
reader-imported image read identically wherever a collection appears: the Add to Collection picker,
the Collections manager, the home rails' headers, the collection's Show All header, the empty state,
and controller mode's action menu. It takes an unscaled base `size` and scales it
itself (mirroring `catalogFont`), rendering an SF Symbol or, for an imported image, the PNG the store
normalized to at most 256px. A missing image or a symbol this macOS does not carry falls back to the
catalog default, so a tile is never blank.

The desktop picker (`CatalogCollectionIconPickerOverlay`) is a centered 620-wide panel over the Scrim
at the dialog's elevation: 2px accent top bar, Surface Deep @ 0.98, 1px Stroke Subtle, the deep
shadow. Header is the eyebrow "CHOOSE ICON" over the collection name with the current glyph leading.
Below it: a 44-high search field (the dialog field spec — #FFFFFF @ 0.08 fill, 1px Stroke Regular,
accent caret), a horizontal category chip row (30-high, Row Fill resting, accent fill with
`onAccent` ink when selected), and a `LazyVGrid` of 44×44 cells at 6 spacing — Row Fill resting, a
1px Stroke Subtle, accent fill with `onAccent` ink when it is the chosen glyph, each cell labelled
with its symbol name. The chip row opens on **Popular**, a hand-picked spread of recognizable glyphs,
ahead of **All** and the subject categories, because All starts at the numeric and letter symbols and
reads as noise before a search or category is chosen. A typed search is also offered verbatim as
"Use “…” as an exact symbol name", so a glyph the bundled catalog does not list is still reachable.
The grid caps at 600 cells and says so, because browsing all symbols unfiltered builds a very long
list.

The header carries a top-trailing close (a 32×32 square `xmark` button, the icon-only square spec),
and the footer holds UPLOAD IMAGE… and RESET as secondary actions beside CANCEL and a SAVE-style DONE.
CANCEL and the scrim restore the icon the picker opened with; DONE keeps the choice as the dialog's
draft, which the dialog's own SAVE still has to commit.

Controller mode reaches the same glyphs without a file picker: the collection row's Options opens
Icon, Rename, Delete; Icon opens a D-pad grid inside the picker panel, the D-pad moving the cursor,
LB/RB stepping categories, X clearing to the default, and A applying the focused glyph. Custom
images are desktop-only, since a pad has no file picker.

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

### Status Item (`OPNMenuBarStatusLabel`, `OPNMenuBarPanel`)

The status item's *label* is system chrome: macOS draws it in the status bar, and it takes no
`uiScale`, `OPNDesign` fills, or 1px-stroke treatment. It is one cloud SF Symbol alone — hollow when
idle, the hourglass for a queue or the launch flow's pre-overlay states, a spinner
(`arrow.triangle.2.circlepath`) while the allocated stream has not produced a frame yet, filled while
streaming, the OpenNOW mark — with the game and the elapsed clock living in the popover instead, so
the status item never resizes while a session runs.

The label's one addition is the **queue position**: while queued, the mark is followed by the bare
number (`4`, not `Queue #4`). It is the state a user parked behind a seat most wants to see without
opening anything, and a position changes only when the seat advances — cheap to redraw, unlike the
elapsed clock. The ETA stays in the popover, where it can change on every vendor poll without
driving the native status-button renderer.

The popover's Continue Playing rows name the game and **when it was last played** ("2 hours ago",
"yesterday") rather than repeating "Continue playing" under a header that already says it. A row the
history carries no timestamp for is title-only.

Above the cards sits a compact **icon tab row** (`OPNMenuBarTab`): a game controller for the session
surface the panel has always been, a heart for the account's favorites, and the catalog's collection
glyph (`square.stack.3d.up.fill`) for the account's own collections. The tabs are the popover's
navigation, one of the things Apple names Liquid Glass for, so on macOS 26 and later each tab is a
glass element in its own `GlassEffectContainer` — the selected one tinted with the accent, the
unselected one plain interactive glass — exactly as the session control row is gathered. On older
systems they fall back to the translucent fill with an accent stroke on the selected tab. The
selected tab's glyph uses `OPNDesign.onAccent`, the ink designed to be read on an accent fill: the
ordinary text ink all but disappears on the tinted glass. The account card sits between the tab row
and the tab content and is **fixed across switches** — who is signed in does not depend on which tab
is showing, so the card, and the account dropdown's state, stay put.

The popover is a fixed-width status-item surface, so like the label it takes no `uiScale`: every card
inside it is laid out at the same 316-wide geometry, and scaling one card alone would break the
alignment the others share.

The Favorites tab lists the account's favorites in the catalog's order as title-only
`.opnMenuBarRow` rows, and the list **grows with its contents up to five rows** before it starts to
scroll, so a long list holds the popover at a comfortable size rather than stretching it. Favorites
live on the vendor, so unlike the play history there is no local copy to seed a windowless surface
from: the tab fills once a window has loaded the catalog.

The Collections tab lists the account's collections in the catalog's order — the glyph
`OPNCollectionIconView` draws, the name, the stored member count, and a chevron — as the same
`.opnMenuBarRow` content, capped at the same five rows. Choosing one opens its games as a detail
inside the same card: a back affordance (`COLLECTIONS` behind a chevron), the collection's glyph and
name with its member count, and the member rows with the same artwork-and-play-glyph treatment a
favorite gets, lazily built and capped like the list. A collection is addressed by id, so deleting
the open collection — or switching accounts — returns the card to the list rather than showing a
stale one. A detail with nothing to list says which case it is: an empty collection, the members
still being resolved, or members the catalog does not carry, always alongside the collection's real
stored size.

Collections are local (`CatalogCollectionsStore`), so the list needs neither a window nor a network
and paints from the store the moment the popover opens. Their members' titles and box art need the
catalog: with a window it resolves them live through the session snapshot, and the catalog writes
what it resolved to `CatalogCollectionGamesCache` as collections are written or reloaded. With no
window, `OPNMenuBarCollections` paints those cached games at launch and asks the vendor for the rest
in bounded batches through `OPNGameService.resolveCatalogGames(byIdentities:)`, writing the result
back to the cache so the next windowless run starts warm. A launch from any of these rows takes the
same window-preserving path a Continue Playing row does.

The popover's first card names the **signed-in account**: avatar, display name, and membership tier.
When more than one account is saved the header becomes a disclosure — a chevron and a tap reveal the
account rows, each with a checkmark on the active one and a "Signed out — sign in again" subtitle for
one whose tokens are gone, followed by an Add Account row. Switching is a window action (it re-points
the shared auth session), so the card presents the window and parks the request on the session model
the same way a recent-game launch does; the account rows are `.opnMenuBarRow` content, not extra
glass.

The native label receives one plain-text readout. Its elapsed clock is refreshed once per second
by the session model and stopped on stream teardown; a self-updating `Text(date, style: .timer)`
in the `MenuBarExtra` label can trap the native status-button renderer in a continuous update loop.

The popover is app-drawn, because `MenuBarExtra`'s `.window` style hands SwiftUI the whole panel.
It matches the Control Center popovers it sits beside — stacked cards with their own controls —
rather than this document's panel system, so its corner radii carry a documented
`design_no_corner_radius` exception at each site.

How it is drawn depends on the OS:

- **macOS 26 and later** — the popover is the system's own Liquid Glass. Inside it, the tab row and
  the session controls (Resume / Pause / End) are Liquid Glass elements, each set gathered in a
  `GlassEffectContainer`, while the cards and their list rows stay in the content layer as
  translucent fills. That split is Apple's guidance, not a preference: Liquid Glass is "a distinct
  functional layer for controls and navigation elements", it should be applied "sparingly" to "the
  most important functional elements", and it must not be stacked on itself — the popover is already
  glass, so a glass card inside it would be two layers of the same material.
- **macOS 15.6 – 25** — the app's floor, unchanged: no glass to draw, so everything above is the same
  translucent fill (`OPNDesign.Fill.neutral` + a 1px stroke) over a `.ultraThinMaterial` panel.

Everything else applies to both paths: `.opnUI` sizes and weights, `OPNDesign` text tokens,
destructive ink from `OPNDesign.Semantic`, and no native `Menu` or `Divider` in the panel.

### Dock Tile (`OPNDockTileProgressView`, `OPNDockMenu`, `OPNDockIconController`)

The Dock tile is system chrome. The icon, the badge, and the drawing of the Dock's menu all belong to
macOS, so nothing here carries `uiScale`, an `OPNDesign` panel fill, or a corner radius — and none of
it is drawn by the app except the one thing the system does not offer:

- **The progress bar.** `NSDockTile` has no progress API: drawing one means becoming the tile's
  `contentView`, and a content view *replaces* the icon instead of overlaying it. `OPNDockTileProgressView`
  therefore draws `NSApp.applicationIconImage` back in and lays the bar over its lower edge, with the
  geometry taken as a fraction of the tile rather than a pixel size, because the Dock draws the tile
  at whatever size the display and the user's Dock settings ask for. It is the only app-painted surface
  outside the window, so it is also the only one outside `View/`: the bar takes its colour from
  `OPNThemePreferences.AccentColor.components`, the same values the in-app palette is built from, and
  deliberately not the page-contrast variant — the background here is the app icon, not a page.
  The bar is `determinate` for the queue and the recording export, and `indeterminate` for a stream
  that has been allocated but has not produced a frame: that state has no fraction to measure, so it
  draws a segment sweeping across the well instead of an empty bar that reads as a stalled wait.
  Reduce Motion parks the segment centered and stops the timer.
- **The menu's wording.** `OPNDockMenu` supplies titles and actions only: a disabled *Continue Playing*
  header, the three most recent games, then *New Session* and *Open Recordings*. The Dock renders it
  in its own chrome, so no `NSMenu` styling belongs in the code either.

A badge is one system-drawn label — the count of sessions waiting on the user, capped at `99+` — and
is cleared by the same rule that set it: nothing pending, no badge.

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

### Release Notes List (`OPNReleaseNotesView`)

Shared renderer for parsed GitHub release notes (`View/Components/OPNReleaseNotes.swift`),
used by the Update Modal and the What's New card. Section header is an eyebrow (10pt bold,
tracking 1.1, Text Tertiary) with a trailing entry count in Text Muted; the settings density
prefixes it with a 3×12 accent bar. Entries are a 3×3 accent square marker (top-aligned to the
first line) over 12pt (modal) / 13pt (settings) medium Text Secondary text with 2pt line
spacing. Commit SHA, pull request, and author render as trailing chips: 9–10pt bold Text Muted
(Text Secondary on hover), 8 horizontal padding, height 18, #FFFFFF @ 0.05 fill (0.10 hover),
1px Stroke Subtle, opening the GitHub URL on click. `entryLimit` truncates a section to N
entries behind an accent `+N MORE` action (10pt bold, tracking 0.7); the modal passes nil and
scrolls instead. Inline markdown (bold, links) is resolved at parse time; links tint accent.

### Update Modal (`OPNUpdateModal`)

Centered dialog over the Scrim following the modal spec, mounted at the app root so it reaches
the catalog, login wall, and stream surface alike. Up to 560 wide, shrinking to the window minus
2 × 40 (Page Horizontal) with a 280 floor. 2px accent top bar; App Bar header block (18
horizontal, 16 vertical) holding the eyebrow (10pt bold accent, tracking 1.1: UPDATE AVAILABLE /
UP TO DATE / UPDATE CHECK FAILED / UPDATE INSTALL FAILED), a 20pt bold title, a 12pt medium Text
Secondary subtitle (installed version · release date · download size), and the square 28×28
close control. 1px Divider, then an 18-padded body: the Release Notes List inside a ScrollView
capped at min(340, half the window height), or a 12pt medium message for the status variants.
1px Divider, then a footer (18 horizontal, 12 vertical) with the accent VIEW ON GITHUB text
action leading and LATER (`OPNModalSecondaryButtonStyle`, height 36 — defers the
prompt for a day) plus
INSTALL AND RELAUNCH (`VendorGetInButtonStyle`) trailing.

While installing, a Section Fill block with a 1px Divider stroke sits under the notes: DOWNLOADING
or INSTALLING eyebrow, an 11pt bold byte readout, and a 3px progress bar — determinate as two
Rectangles (accent over #FFFFFF @ 0.10), or `VendorIndeterminateProgressBar` when the server
sends no content length. Buttons and the close control disable for the duration.

It enters and leaves through `Motion.panel` — the scrim cross-fades while the centered panel
springs up from 0.96 scale with a fade, collapsing to a plain cross-fade under Reduce Motion.

### Settings Destination Rail (`SettingsSidebar`)

The desktop Settings navigation: a 208-wide column of 36-high rows, 14 horizontal padding, 16pt
glyph then a 13pt label. Selected is accent @ 0.12 fill with a 3-wide accent bar on the leading
edge; hover is white @ 0.05. Pages of one concern share a quiet caption in the `SettingsSubheading`
style - App (General, Look, iCloud, System, Labs), Stream, Connection - with 14 horizontal padding,
12 top and 8 bottom padding, so thirteen bare rows never read as a wall. Account anchors the rail
uncaptioned, ahead of the first caption, and Connection ends it - no run trails the last caption
uncaptioned, or it would read as belonging to the section above. Below 900pt of window width per
interface scale the labels drop and the captions drop with them, the rail narrows to 60, glyphs
only, each row keeping its title as a tooltip. The rail is desktop only: controller mode renders `SettingsTabBar`
instead, because its shell already carries a horizontal row of destination pills and pad focus is a
single top-to-bottom list.

### Settings Destinations (`GeneralSettingsGroup`, `SystemSettingsGroup`)

General carries the editable catches - Session Ready, Game Launch, Discord, Privacy, Cache, and
Support Diagnostics. System carries identity, updates, and machine facts: Product, Runtime, This
Mac, Updates, and What's New last. The updater deliberately lives on System rather than General, so
its preferences and the manual check sit beside the release history they produce. When one card
mixes read-only and editable content, it splits: Runtime keeps its version rows on System while its
update rows live in Updates.

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

### Settings Decode Recommendation (`DecodeRecommendationRow`)

Settings → Video → Codec & Colour: what this Mac measured while decoding the chosen
resolution/codec, one 28-high row per colour tier. A run-on sentence cannot work here: with four
tiers it is wider than the card at any interface scale and truncated at the right edge, hiding the
tiers it recommends. The 10pt bold muted eyebrow sits beside the report - a 150-wide label column
when the card is wide, stacked above it under `opnSettingsNarrowRows`. The report leads with a
12pt medium Text Tertiary "Measured here at ‹resolution› ‹codec›" line, then one row per tier in
ascending decode cost: a 96-wide 12pt bold Text Secondary label, the 12pt medium monospaced-digit
decode time, and the verdict pushed to the trailing edge - accent ink "holds ‹fps› fps" when the
measured decode time reaches the target, muted "fits ~‹fps› fps" when it does not. Rows carry the
row fill and a subtle stroke. Tiers this build does not offer are dropped before display, because
the measurement store is append-only and also holds superseded and test tiers.

### Replay Window Diagram (`ReplayWindowDiagram`)

Settings → Recording → Instant Replay: the model as one picture, because the two numbers it draws
are the two readers mix up. A full-width 8-high square bar is the window kept on disk; its trailing
edge carries the accent fill for the slice a save takes, never narrower than a 12-wide sliver — a
1-minute clip against a 2-hour window is 0.8%, and a hairline reads as a rendering fault. The labels
sit on the bar's own ends: the kept duration as a Text Muted eyebrow, the shortcut and clip duration
in `OPNDesign.accentInk`, so the action is written on the side of the bar it acts on. One 12pt Text
Tertiary line under it names the consequence. The bar measures in an overlay rather than as the
stack's own child: a `GeometryReader` in the stack takes the height it is offered and collapses the
caption. The diagram owns the single duration vocabulary both sliders above and below it read
(`45 s`, `1 min`, `1 h 30 min`).

### Settings Reorder List (`HomeCategorySettingsCard`)
Settings → Look → Home Categories: the reader's own order for the home rails, and which are drawn.
The card sits last on the Look page and wears the NEW tag. Each rail is a stroked row - 12 padding,
subtle fill, 1pt Stroke Subtle border - holding an 18-wide
muted drag handle, a 14pt bold title that drops to Text Tertiary while switched off, and a
`Toggle`. Pointer dragging reorders through `draggable`/`dropDestination`; under a gamepad, confirm
switches the focused rail on or off and left/right moves it one place. A rail the arrangement has
never seen appears at the bottom and stays visible. The Jump Back In row writes through to its own
preference rather than the arrangement's hidden set, because that setting predates this card and is
read elsewhere. A RESET ORDER secondary `SettingsActionButton` appears only while something is
customised. The three fixed rails are always listed, so a rail the catalog has nothing for yet is
still findable. Stored under `OpenNOW.Interface.HomeRailOrder` and
`OpenNOW.Interface.HomeRailsHidden` via `OPNHomeCustomization`.

### Settings Labs (`LabsSettingsPage`, `OPNLabs`)

Features on trial live on their own destination, always drawn so people can learn where to look.
With `OPNLabs.flags` empty the page is its own empty state: a 132 accent-ringed flask with three
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

### Keybindings Settings (`KeybindingsSettingsPage`, `KeybindingRecorderRow`)

Its own destination, grouped into exactly two cards - Stream and Catalog - one per shortcut surface,
each tagged with its section id so search can land on it. Every row is a 15pt title with a one-line
subtitle, a muted `Default ⌘X` line, and a trailing 190-wide recorder beside a Reset button that is
disabled until the binding is customised. A chord two actions in the same section share replaces the
default line with a warning-coloured "Also used by …" note; the same chord across sections is not a
conflict, because only one surface is active. Capture reuses `ControllerBindingRecorder`, so recording
a shortcut reads the same here as in Controller Mapping, and a bare modifier key is rejected rather
than stored. A Reset card appears only while something is customised.

### Settings Card Badge (`SettingsCardBadge`, `SettingsCardTag`)
`SettingsCard(title:badge:uiScale:)` renders BETA or EXPERIMENTAL beside the card title, 8pt bold,
tracking 0.7, accent @ 0.78 on accent @ 0.12. Scope is the card, and it qualifies what the card
holds alone: Instant Replay is BETA, the Recording Mode row that offers Off, Instant Replay and
Manual is not, so the tag stays on the card rather than moving to the row that reaches it.
A destination in
`SettingsTabBar.betaGroups` wears the tag in the rail instead, and only when every card on it is
beta - one unsettled card in a settled tab is a card badge, not a destination tag.
`SettingsCard(title:badge:isNew:uiScale:)` also lets a card wear the solid NEW tag when it qualifies
a setting added in the current release; it expires by version and by use exactly as a row's does.

### Tags (`OPNBetaTag`, `OPNNewTag`)

Two annotations ride inside another control's title and must not outweigh it: 8pt bold, tracking
0.7, 4pt leading / 3.3pt trailing / 2pt vertical padding, square corners. The trailing padding is
short by exactly the tracking, because letter-spacing is applied after the last glyph too and an
even 4/4 leaves the label sitting left of centre in its box. Tracking scales with the interface like
the padding it is subtracted from. **BETA** is accent text on a 12 % accent
tint (compact) for shipped-but-rough features. **NEW** is black text on solid accent for a setting
added in the current release; rows opt in with `isNew:` and declare their release in
`OPNNewSettings.Row`, which hides the tag once the setting is changed or the next release ships.

### Tooltip (`opnTooltip`)

A flat balloon annotation that drops below a control while the pointer rests on it, used where the
system `.help` bubble's rounded, shadowed chrome would clash with the square, stroked plates around
it (the catalog top bar's icon row). Raised panel surface, 1pt Stroke Regular border, 11pt bold Text
Primary on one line, 8pt horizontal / 5pt vertical padding, plus a centred 12×5pt caret rising from
the top edge and pointing back at the control. The caret is part of the bubble outline, filled and
stroked with it, so the border traces the point rather than crossing its mouth — no shadow; depth
comes from the stroke, per the flat-panel rule. Placement is measured, not assumed: the label is
top-anchored and offset past the control's own height plus a 6pt gap, so it clears any control size.
It is decoration only: `allowsHitTesting(false)` keeps it out of the hit area, and the control keeps
its own `accessibilityLabel`. An ancestor that clips or draws after the control will occlude it, so
the host must not be clipped and must sit above the content it overhangs.

### What's New Card (Settings → System)

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

The floating stream-statistics overlay is `NativeNVSTStatsPanel` on the native NVST surface.
It is toggle-only from the shortcut and the CONTROLS tile —
shown or hidden — and its shape is chosen in the unified HUD's STATS panel.

Two stored preferences give its shape:

- **Detail** — Minimum, Compact, Advanced. Minimum is the headline readings alone: GAME and
  STREAM frame rates plus latency.
  Compact keeps the headline readings and one overview group — Resolution, Codec, Bandwidth,
  Packet Loss, Frame Loss. Advanced keeps every group. The header and the panel's padding and
  width are the same at every level; the level only decides how many detail rows follow.
- **Position** — Top Left, Top Right, Bottom Left, Bottom Right. A leading corner steps clear of
  the unified sidebar by its own width while the sidebar is open, so the overlay is never buried
  behind the dock; Bottom Right sits above the circular microphone toggle. Reveal and hide
  travel from the chosen corner.

The panel keeps its chrome and its geometry at every level — Panel background, 2px accent top
bar, 1px stroke, floating-layer shadow — and only how many detail rows follow the headline
readings changes. Both selectors are square `StreamHUDDropdown` rows, and a pad cycles each on
activate.

### On-Screen Keyboard (`StreamOnScreenKeyboardOverlay`)

Bottom-anchored panel invoked in-stream with Steam + X (Steam Deck-style chord)
on the native NVST surface. Panel background @ 0.985, 2px accent
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

Full-bleed black surface: blurred loading artwork (10pt blur, 14pt overscan) behind a
two-strip scrim — full `StreamHUDTheme.scrim` (0.54) in the top 22% and bottom
34% of the frame, clear through the middle — and a 2px accent top bar. Corner-anchored
layout: the 32pt bold title (24 compact) sits top-leading in Text Primary; a fixed-footprint
hero region sits centered; a footer band sits bottom, holding the eyebrow line and the
5-segment step rail.

The hero region reserves one footprint per breakpoint (640×418 full, 380×272 compact,
both derived from the embedded ad player's real video-plus-two-line-info-bar height) whether it
holds the `StreamLaunchStagePlate` or the mandatory free-tier ad player — swapping between
them never resizes the region. The plate is a wide letterbox (full hero width × 84, 64
compact; Surface Chrome @ 0.55, 1px Stroke Regular, four accent corner brackets) carrying
the stage word alone — 22pt bold (16 compact), tracking 4 (2.6 compact), uppercase, Accent
Soft — with a thin accent sweep travelling leading-to-trailing once every 2.4s
(`Motion.heroFrameInterval`, omitted under Reduce Motion). It contains no circle and no
corner radius.

It carries no step number. The eyebrow and the rail directly below already say where in
the sequence this is, and a third rendering of that same count — at the largest size on
the screen — was the one element of this surface that read as decoration rather than
information. For the same reason the plate is the only place the stage word appears:
queueing renames the headline to "WAITING IN QUEUE" rather than adding a line about it.

The footer's eyebrow carries the position, not the stage: `STEP n OF 5` (11pt bold,
tracking 1.4, Text Tertiary), with an Accent Soft trailing phrase appended only when there
is something the plate cannot say — "POSITION n" while queued, "SPONSORED BREAK" during
the ad (which replaces the plate entirely, so the eyebrow takes over the headline), or both
when a queue position was still active when the ad began. The step count never drops out.
Below it, the step rail is five equal `Rectangle` segments
(8pt tall, 6pt compact) sized off `StreamLaunchStep`: passed is accent @ 0.72, current is
full accent with a 1px Stroke Strong border, pending is a Stroke Subtle outline only —
the same fill/scale values as the startup rail's filled/unfilled/head cells. Below each
segment at full width only, an 8pt caption repeats that step's title. Cancel
(`OPNModalSecondaryButtonStyle`, unchanged shared object) sits trailing on the eyebrow
row, its 36pt row height reserved even when no cancel action is offered.

The screen renders at 100 % interface scale like every other transient splash.

### Confirmation Modal (`OPNConfirmationModal`)

The app-shell replacement for the native `.confirmationDialog` and `.alert`, which render rounded
macOS system chrome. Raised through the `opnConfirmation` modifier and rendered once at the app root
by `OPNConfirmationOverlay` — above the update prompt, below the splash — so it covers the whole
surface even when the page that raised it lives inside a scroll view. Full-cover Scrim behind a
centered panel following the modal spec (Panel background, 1px Stroke Regular, 2px accent top bar,
modal shadow #000000 @ 0.58, radius 28, y 20), up to 440 wide and shrinking to the window minus
2 × 40 (Page Horizontal) with a 280 floor. The App Bar header block holds the eyebrow (10pt bold accent, tracking 1.1), a 20pt bold
title, and the square 28×28 close control (shared `OPNModalCloseButton`). 1px Divider, an 18-padded
12pt medium Text Secondary message, 1px Divider, then the footer (18 horizontal, 12 vertical) with
actions trailing. Actions are `OPNConfirmationAction`s in visual order: `.cancel` (Escape,
`OPNModalSecondaryButtonStyle`), `.standard` (Enter, secondary), and `.destructive`
(`OPNModalDestructiveButtonStyle`, never the default). The scrim tap, close control, Escape, and
`.cancel` all dismiss. It enters and leaves through `Motion.panel`: the scrim cross-fades while the
centered panel springs up from 0.96 scale with a fade. Reduce Motion collapses both to a plain
cross-fade.

### Report an Issue Modal (`OPNReportIssueModal`)

The two-channel support form, raised through `OPNReportIssuePresentation.shared.present(context:)`
and rendered once at the app root by `OPNReportIssueOverlay` — above the update prompt, below the
confirmation modal — so it covers the whole surface even when the page that raised it lives inside a
scroll view. It reuses the confirmation modal's shell exactly (Panel background, 1px Stroke Regular,
2px accent top bar, modal shadow #000000 @ 0.58 radius 28 y 20, App Bar header with a 10pt bold
accent "SUPPORT" eyebrow, a 20pt bold "Feedback" title, and the shared 28×28 close control).
The panel is up to 520 wide and shrinks to the window minus 2 × 40 (Page Horizontal) with a 340
floor; the body is the only part that scrolls, capped to 62 % of the window height so the header and
footer stay put at a high interface scale.

The body opens on two square target cards side by side (`OPNReportIssueTargetPicker`): selected is
accent @ 0.14 fill with a 2px accent strokeBorder and the accent-ink label, the other is the Row
Fill (0.045) with a 1px Stroke Subtle border. The cards choose between two different forms, not one
form with two destinations:

- **OpenNOW Client** collects a GitHub report. It opens on a row of square category chips
  (`OPNReportIssueCategoryPicker`: 28 high, 12 (Small) horizontal padding, accent fill with an
  on-accent label when selected and the neutral Row Fill otherwise) for Bug / Feature Request —
  the category is required, and it becomes both the GitHub label (`bug` / `feature`) and a body
  section. Below it sit labelled fields (`OPNReportIssueInput`) on Surface Field, 1px Stroke Regular
  and a 2px accent strokeBorder while focused, 12 (Small) horizontal / 10 vertical padding, with the
  placeholder drawn rather than handed to the field so no system prompt colour leaks in: a
  single-line Summary, a multiline Description, and a square diagnostics checkbox
  (`OPNReportIssueCheckbox`: 18×18, accent fill with an on-accent checkmark when on). The footer carries CANCEL (`OPNModalSecondaryButtonStyle`, Escape) and SEND
  REPORT (`VendorGetInButtonStyle`, disabled at 0.62 until both fields are filled); after submission
  it becomes a single CLOSE button over a confirmation that names GitHub and says the full report is
  on the clipboard.

- **GeForce NOW Stream** collects no summary of its own — NVIDIA's survey has its own text field.
  Selecting the card loads the survey immediately and draws its questions natively
  (`OPNFeedbackSurveyForm`): numbered 14pt bold question text; a 22pt star row
  (`star`/`star.fill`, accent when selected) for CSAT/NPS; a multiline Surface Field for free text,
  placeholder "Do not include any personal information"; and 18×18 square selection indicators for
  choice questions — accent fill with an on-accent checkmark for multi-select, an on-accent inner
  square for single-select. The footer carries CANCEL and SUBMIT FEEDBACK (`VendorGetInButtonStyle`,
  disabled at 0.62 until every required question is answered). SUBMIT FEEDBACK first opens an
  agreement step in place of the questions: an accent-bar notice stating the answers go directly to
  NVIDIA and OpenNOW is unaffiliated and cannot follow up, plus a required `OPNReportIssueCheckbox`
  ("I understand and agree") that gates AGREE & SEND. Confirming sends the answers to NVIDIA's
  `/survey/v1`; CANCEL returns to the questions with the answers intact. A questionnaire the native form cannot draw (DDL/INFO) falls back to
  `OPNFeedbackSurveyView`, an embedded `WKWebView` of NVIDIA's own survey, up to 74 % of the window
  height with a 320 floor and an OPEN IN BROWSER / DONE footer. If the survey cannot be reached at
  all, an accent-bar notice (`OPNReportIssueNotice`) explains it and the footer offers OPEN GEFORCE
  NOW. The centered loading state uses `VendorIndeterminateProgressBar`; the embedded page's chrome
  is NVIDIA's and is not restyled.

Scrim tap, close control, and Escape all dismiss; the centered picker stays above whichever form the
channel draws. It opens and closes with the same `Motion.panel` entrance as the confirmation modal:
the scrim cross-fades while the panel springs up from 0.96 scale with a fade, collapsing to a plain
cross-fade under Reduce Motion.

### Session Insights Modal (`SessionInsightsOverlay`)

The post-session summary, mounted by `CatalogView` over the catalog when a stream ends and the
session actually ran. Follows the modal spec (Panel background, 1px Stroke Regular, 2px accent
top bar, modal shadow #000000 @ 0.58 radius 28 y 20, App Bar header with a 10pt bold accent
"SESSION INSIGHTS" eyebrow, the game title as a 20pt bold title, and the shared 28×28 close
control). The panel is up to 560 wide and shrinks to the window minus 2 × 40 (Page Horizontal)
with a 320 floor; only the body scrolls, so the header and footer stay put at a high interface
scale.

The body opens on the outcome headline (15pt bold — Text Primary, or Danger when the session
failed) beside the transport name as an eyebrow chip, then "Played for …", then the stream shape
(Resolution · FPS · Codec). Measurements the transports wrote into `StreamReport.metadata` while
the session was still connected render as a three-column grid of metric cards (Row Fill @ 0.045,
1px Stroke Subtle, 9pt bold muted label over a 15pt bold value; a reading outside its budget —
latency over 60 ms, decode over the frame budget, packet loss over 1 %, or any non-zero drop,
decode error or recovery — carries Warning). A transport that measured nothing contributes no
cards. An accent-bar notice (`OPNReportIssueNotice`) closes the body with the session's own
verdict. The footer carries a square "Don't show this again" checkbox
(`OPNReportIssueCheckbox`, left) and DONE (`VendorGetInButtonStyle`, Enter). Checking the box and
confirming — by DONE, the close control, scrim tap, or Escape — turns the `Session Insights`
preference off; leaving it unchecked keeps it on. The summary is gated by
Settings → General → Session Ready → Session Insights (default on).

### Controller Sheets (test / mapping)

The controller tester (`SteamControllerTestView`) opens from Settings → Input → Controller
Tools. The mapping editor (`ControllerMappingView`) opens from the same shared Controller
Tools section and from the stream HUD. Native mappings are opt-in: no assigned profile means
unchanged direct gamepad passthrough. Existing Steam defaults and saved profiles are preserved. Both are full-window settings-style flows on Surface Deep, wrapped in the modal spec:
2px accent top bar (`SteamControllerModalTopBar`), App Bar header block
(`SteamControllerModalHeader` — 10pt bold accent eyebrow, tracking 1.1, over a 20pt bold
title, with the shared square 28×28 `OPNModalCloseButton`), 18 (Card) horizontal / 16 (Medium)
vertical header padding, and 1px Stroke Subtle rules (`SteamControllerModalRule`) between
every band. Both eyebrows read "CONTROLLER". Escape dismisses both. Every size is pre-scale and multiplied by `opnUIScale`,
which the sheets read from the environment; hairline rules stay 1px at all scales.

The tester has a pinned square `OPNDropdownMenu` listing every connected controller, including
multiple pads of the same family. It initially selects the first connected device (Steam-first),
keeps that identity selected when other pads connect or player order changes, and selects the
first remaining device if the selected pad disconnects. With no pads it shows the empty state.
The picker changes only the tester: it never changes player order or mapping assignments.
Input, battery, and Steam rumble target only the selected device; changing selection clears old
telemetry and stops an in-flight test pulse. Native input is polled without taking handler slots.

The tester draws whichever shell matches the selected pad, and always exactly one of the three:

- A Steam Controller gets `SteamControllerDiagramView` — full Triton hardware, rumble panel.
- A DualShock 4 gets the read-only `DualShock4DiagramView` — the PS4 shell with its touchpad, the
  PlayStation face glyphs (△ ○ × □), Share/Options (`buttonOptions` left, `buttonMenu` right),
  and a PS button. The front-view artwork preserves DS4 proportions: flat upper bridge, wide
  touchpad, circular control platforms, separate directional keycaps, symmetrical recessed
  sticks, speaker grille, and tapered grips. Face glyphs are vector strokes, not font glyphs;
  the shell uses Steam's 4px silhouette / 2px detail strokes in authored coordinates.
- Everything else GameController exposes — Xbox, DualSense, and every other pad — gets the
  read-only `GenericControllerDiagramView`.

Neither of the read-only shells draws a rumble panel, which is a Steam HID feature. Detection is
`GCDualShockGamepad` on the attached profile, with the `GCProductCategoryDualShock4` identity as
the fallback for a pad bridged through a virtual driver. All three diagrams live in the same
456×320 authored space at the same 560 reference width, share their shell palette and overlay
ink through `ControllerDiagramArtwork` (`OPNDesign.Fixed.controllerShell` /
`.controllerShellStroke`), and scale from the interface scale environment. Their shell art is
the DESIGN.md radius exception: every rounded shape traces physical hardware, not chrome.
The tester always shows a battery badge while connected: a reported percentage, “Charging”
when only the charge state is known, or “Battery unavailable” when macOS supplies neither.

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

Mapping opens on an actually connected controller. With no controllers connected it shows a
"No controller connected" empty state and a Close action, not a Steam diagram or profile editor.
Hot-plugging selects the first available controller; an existing selection is preserved while it
remains connected. Steam defaults are an explicit picker option only while a Steam Controller is
connected. Each connected pad has its own assignment; native connection identities are UUIDs,
never vendor-name matches. Saved profiles persist, but assignments
reset on disconnect/restart because GameController exposes no reliable hardware identifier. The
Steam-default entry edits the preserved shared Steam profile; connected Steam pads can override it.
The profile picker includes a direct-passthrough option for native pads. Families filter profiles,
controls, and labels: generic pads have standard buttons/axes, DS4 adds touchpad click/motion only
when GameController exposes it, and Steam keeps its grips and twin pads. The native diagrams remain
read-only previews with selectable control chips above; the Steam diagram also supports tapping.
The preview aspect-fits the entire shell and shoulder row into the remaining editor width and
height without scrolling or cropping. Only the hardware artwork may shrink below the configured
interface scale; control chips, sidebar, binding panel, and footer keep their normal scaled sizes.
The DS4 touch pointer uses reported touch begin/end, never nonzero coordinates as a touch heuristic.
Mappings affect local streaming, not the system controller or RemoteCoOp guest keyboard/mouse.

Mapping-specific chrome: the profile picker is an `OPNDropdownMenu` (trigger height 30, Row
Fill, 1px Stroke Regular), the profile name is a 14pt regular field on Surface Field with a 2px
accent focus stroke, and the category sidebar (width 168) follows the Main Menu row spec — height
30, 12 (Control Row) padding, white 0.08 on hover, accent @ 0.095 fill with a 3px accent leading
bar when active. The footer carries a `Semantic.warning` "UNSAVED CHANGES" eyebrow, CANCEL
(`OPNModalSecondaryButtonStyle`, `.cancelAction`) and SAVE (`VendorGetInButtonStyle`,
`.defaultAction`, opacity 0.46 while there is nothing to save). Row actions elsewhere in the bar
use `OPNCompactButtonStyle`.

### Controller Order (`ControllerOrderView`)

Available from Settings → Input → Controller Tools and both stream HUDs. Uses the controller-sheet
header, rules, and Surface Deep, at 680 wide and 320–680 tall (sized to the controller count)
before interface scaling and screen-size clamping.
A scrollable list of square Panel rows has a 76-wide accent PLAYER 1–4 label, controller name and
family, and secondary Up/Down buttons. Extra controllers are marked WAITING and can be moved into
the first four. The focused move button has a 2px accent border; D-pad/stick navigates rows and
arrows, Confirm moves, Back closes. Input is polled without taking GameController handler slots,
and only the key sheet of the active app accepts controller navigation. Empty state explicitly says
no controllers are connected. The pinned footer offers Default Order (disabled unless custom) and
Close; all dimensions and typography scale with `opnUIScale`.

Ordering is per connection session, separate from mapping profile assignments. Default order is
Steam-first; custom order preserves surviving connections and appends new ones, then resets when
all disconnect. Steam and native topology are observed even while the sheet is closed. Only local
controllers are reordered; Remote Co-Op guest slots are unchanged. Slot changes stop old rumble,
release held input before changing routing, refresh battery/player labels and topology, then replay
current state in the new slots.

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
  The baseline is currently empty: every pre-rule surface has been
  redesigned to spec, so the ledger is a gate rather than a backlog.
- Token files (`OPNDesign.swift`, `StreamHUDComponents.swift`, `SettingsView.swift`,
  `LoginStyles.swift`, `OPNButtons.swift`) are excluded where they define the literals the
  rules ban elsewhere — that is where a colour or font is allowed to be spelled out.

## Guidelines

### Do

- Build every panel, button, field, and card as a `Rectangle` with a 1px stroke.
- Use Hanken Grotesk on all branded and stream surfaces; keep the size/weight scale above.
- Pull colors from `OPNDesign` / `StreamHUDTheme` tokens; express light
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
  in the Twitch panel and transient message pills only.
- Don't introduce new accent colors or hardcode hex values outside the token files.
- Don't use accent for large fills, backgrounds, or destructive actions.
- Don't rely on shadows for hierarchy on flat panels; use strokes and fill tints.

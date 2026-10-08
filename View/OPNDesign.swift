import SwiftUI

enum OPNDesign {
    /// Every reader goes through the cached statics below rather than through these directly: a
    /// `static let` here would freeze at the dark values and never see `applyAppearance`.
    enum Surface {
        static var app: Color { resolvedPalette.surfaceApp }
        static var appBar: Color { resolvedPalette.surfaceAppBar }
        static var panel: Color { resolvedPalette.surfacePanel }
        static var panelRaised: Color { resolvedPalette.surfacePanelRaised }
        static var tileTray: Color { resolvedPalette.surfaceTileTray }
        static var field: Color { resolvedPalette.surfaceField }
        static var scrim: Color { resolvedPalette.surfaceScrim }
        static var deep: Color { resolvedPalette.surfaceDeep }
        static var overlay: Color { resolvedPalette.surfaceOverlay }
        static var chrome: Color { resolvedPalette.surfaceChrome }
    }

    /// Surfaces that stay dark whatever the appearance: the startup scene, and chrome drawn over
    /// video or artwork. Their ink is white in light mode too, because what is behind it never is.
    enum Fixed {
        static let surfaceDeep = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)

        /// The controller diagram shells. Real gamepad plastic is matte black under a fixed grey
        /// outline, and the palette tokens wash the other way in light mode, where the shell would
        /// read as barely-there pale grey instead of a device.
        static let controllerShell = Color(red: 0.14, green: 0.14, blue: 0.145)
        static let controllerShellStroke = Color(red: 0.42, green: 0.42, blue: 0.44)

        static func ink(_ opacity: Double) -> Color { Color.white.opacity(opacity) }

        /// The accent as it reads on those surfaces: always the bright value, because the deep one
        /// is for light pages and these never are.
        static var accent: Color { brightAccent }
    }

    nonisolated(unsafe) static var brightAccent = color(OPNThemePreferences.AccentColor.cloudGreen.components)

    enum Semantic {
        static let destructive = Color(red: 1, green: 0.54, blue: 0.50)
        /// Favorite state, and the one place a second hue is sanctioned: an accent-green heart
        /// sitting beside an accent-green Play button reads as a second primary action, not a toggle.
        static let favorite = Color(red: 1, green: 0.30, blue: 0.58)
        /// Degraded-but-not-broken state on app-shell surfaces: unsaved edits, a low battery, a
        /// value that still works but wants attention. Matches `StreamHUDTheme.warning`
        /// so the same condition reads the same colour in the stream HUD and in Settings.
        static let warning = Color.orange
    }

    enum Text {
        static var primary: Color { resolvedPalette.textPrimary }
        static var secondary: Color { resolvedPalette.textSecondary }
        static var tertiary: Color { resolvedPalette.textTertiary }
        static var muted: Color { resolvedPalette.textMuted }
    }

    /// Budget for `opnTakingFocus`.
    static let focusAttempts = 6
    static let focusRetryMilliseconds = 30

    enum Stroke {
        static var subtle: Color { resolvedPalette.strokeSubtle }
        static var regular: Color { resolvedPalette.strokeRegular }
        static var strong: Color { resolvedPalette.strokeStrong }
    }

    /// Translucent neutral fills - row backgrounds, hover washes, chip and pill fills. The palette
    /// has no named colour for these because each site picks its own weight; what flips with the
    /// appearance is which way the wash goes, white over a dark page and black over a light one.
    enum Fill {
        /// Dark ink on a light page reads far heavier than light ink on a dark one at the same
        /// alpha, so a light palette carries the same wash at roughly half weight.
        static let lightWashScale = 0.5

        static func neutral(_ opacity: Double) -> Color {
            resolvedPalette.fillBase.opacity(opacity * resolvedPalette.fillScale)
        }
    }

    enum Spacing {
        private static let baseXXSmall: CGFloat = 4
        private static let baseXSmall: CGFloat = 8
        private static let baseSmall: CGFloat = 12
        private static let baseMedium: CGFloat = 16
        private static let baseLarge: CGFloat = 20
        private static let baseXLarge: CGFloat = 24
        private static let baseXXLarge: CGFloat = 32
        private static let baseXXXLarge: CGFloat = 40
        private static let basePageHorizontal: CGFloat = 40
        private static let baseRailHorizontal: CGFloat = 32
        private static let baseCard: CGFloat = 18
        private static let baseSection: CGFloat = 10
        private static let baseContentVertical: CGFloat = 14
        private static let baseControlRow: CGFloat = 12
        private static let baseMenuPanelVertical: CGFloat = 4

        static let xxSmall: CGFloat = baseXXSmall
        static let xSmall: CGFloat = baseXSmall
        static let small: CGFloat = baseSmall
        static let medium: CGFloat = baseMedium
        static let large: CGFloat = baseLarge
        static let xLarge: CGFloat = baseXLarge
        static let xxLarge: CGFloat = baseXXLarge
        static let xxxLarge: CGFloat = baseXXXLarge
        static let pageHorizontal: CGFloat = basePageHorizontal
        static let railHorizontal: CGFloat = baseRailHorizontal
        static let card: CGFloat = baseCard
        static let section: CGFloat = baseSection
        static let contentVertical: CGFloat = baseContentVertical
        static let controlRow: CGFloat = baseControlRow
        static let menuPanelVertical: CGFloat = baseMenuPanelVertical

        static func xxSmall(scale: CGFloat) -> CGFloat { baseXXSmall * scale }
        static func xSmall(scale: CGFloat) -> CGFloat { baseXSmall * scale }
        static func small(scale: CGFloat) -> CGFloat { baseSmall * scale }
        static func medium(scale: CGFloat) -> CGFloat { baseMedium * scale }
        static func large(scale: CGFloat) -> CGFloat { baseLarge * scale }
        static func xLarge(scale: CGFloat) -> CGFloat { baseXLarge * scale }
        static func xxLarge(scale: CGFloat) -> CGFloat { baseXXLarge * scale }
        static func xxxLarge(scale: CGFloat) -> CGFloat { baseXXXLarge * scale }
        static func pageHorizontal(scale: CGFloat) -> CGFloat { basePageHorizontal * scale }
        static func railHorizontal(scale: CGFloat) -> CGFloat { baseRailHorizontal * scale }
        static func card(scale: CGFloat) -> CGFloat { baseCard * scale }
        static func section(scale: CGFloat) -> CGFloat { baseSection * scale }
        static func contentVertical(scale: CGFloat) -> CGFloat { baseContentVertical * scale }
        static func controlRow(scale: CGFloat) -> CGFloat { baseControlRow * scale }
        static func menuPanelVertical(scale: CGFloat) -> CGFloat { baseMenuPanelVertical * scale }
    }

    /// What a surface IS, not how round it is, so a fill, its border and its clipping all resolve
    /// from one role and can never disagree.
    enum CornerRole {
        /// Buttons, chips, fields, toggles and icon buttons.
        case control
        /// Small artwork tiles: menu-bar game and collection thumbnails.
        case tile
        /// Cards, rows and list containers.
        case card
        /// Panels, docks, dropdown panels and section chrome.
        case panel
    }

    /// The one place corner radii are written down. `scale` belongs to the caller that owns the
    /// interface scale, and stays at 1 where an outer `opnInterfaceScale` already transforms it.
    enum Corner {
        private static let baseControl: CGFloat = 6
        private static let baseTile: CGFloat = 6
        private static let baseCard: CGFloat = 10
        private static let basePanel: CGFloat = 12

        static func radius(_ role: CornerRole, style: OPNThemePreferences.CornerStyle, scale: CGFloat = 1) -> CGFloat {
            guard style == .rounded, scale.isFinite, scale > 0 else { return 0 }
            return base(role) * scale
        }

        private static func base(_ role: CornerRole) -> CGFloat {
            switch role {
            case .control: baseControl
            case .tile: baseTile
            case .card: baseCard
            case .panel: basePanel
            }
        }
    }

    /// Type roles for the app. `label`/`body` use the app's UI sans (brand voice);
    /// `mono` is reserved for machine readouts (telemetry, counters, codes) so
    /// numerals stay column-aligned while they tick.
    enum Typography {
        static func display(size: CGFloat, scale: CGFloat = 1) -> Font {
            .uiSans(size: size * scale, weight: .black)
        }

        static func label(size: CGFloat, scale: CGFloat = 1, weight: OPNUIFont.Weight = .bold) -> Font {
            .uiSans(size: size * scale, weight: weight)
        }

        static func body(size: CGFloat, scale: CGFloat = 1, weight: OPNUIFont.Weight = .regular) -> Font {
            .uiSans(size: size * scale, weight: weight)
        }

        static func mono(size: CGFloat, scale: CGFloat = 1, weight: Font.Weight = .bold) -> Font {
            .system(size: size * scale, weight: weight, design: .monospaced)
        }
    }

    enum Motion {
        /// 30 fps clock for decorative ambient `TimelineView` animations. The native
        /// `.animation` schedule fires every display frame (up to 120 Hz on ProMotion),
        /// so throttling to 30 fps halves render work on 60 Hz panels and quarters it
        /// on 120 Hz panels with no perceptible change for slow, large-area motion.
        static let ambientFrameInterval: TimeInterval = 1.0 / 30.0

        /// 60 fps clock for short, foreground-hero motion (the startup scan sweep).
        /// Fast small-area travel reads as stepped at 30 fps, and these surfaces
        /// live for under three seconds, so the extra frames are worth paying for.
        static let heroFrameInterval: TimeInterval = 1.0 / 60.0

        /// Shared curve vocabulary. Every interactive surface should reach for one of these rather
        /// than inventing a duration: the durations used to be spread across twenty files, so two
        /// adjacent controls could fade at different speeds for no reason. Use them through
        /// `opnMotion(_:value:)`, which drops the motion under Reduce Motion.
        ///
        /// Pointer-driven state that must feel instant (hover tints, borders).
        static let hover = Animation.easeOut(duration: 0.16)
        /// Click feedback. Shorter than `hover` so the press reads as a direct response.
        static let press = Animation.easeOut(duration: 0.10)
        /// A control changing state in place (chevron flip, disclosure, tab tint).
        static let toggle = Animation.easeInOut(duration: 0.18)
        /// Physical travel inside a control, where the ground covered is the feedback (the switch
        /// knob crossing its track). Tighter than `panel` and barely overshooting, so a 16pt slide
        /// settles into place rather than bouncing off the end of the track.
        static let toggleKnob = Animation.spring(response: 0.24, dampingFraction: 0.7)
        /// Panels and menus entering or leaving. The only full spring in the set - travel is the point.
        static let panel = Animation.spring(response: 0.34, dampingFraction: 0.86)
        /// Whole-surface swaps (page change, skeleton to content).
        static let page = Animation.easeInOut(duration: 0.24)

        /// Substitute used when Reduce Motion is on: same timing family, no spring overshoot, and
        /// paired with `opnTransition` so nothing travels or scales.
        static let reduced = Animation.easeInOut(duration: 0.12)

        /// The one place "is motion reduced right now" gets decided. The in-app switch only ever
        /// adds to the system setting, so a reader who turned on macOS Reduce Motion never gets
        /// animation back because the in-app preference happens to be off.
        static func isMotionReduced(system isSystemReduceMotionEnabled: Bool, preference isReduceMotionPreferenceEnabled: Bool) -> Bool {
            isSystemReduceMotionEnabled || isReduceMotionPreferenceEnabled
        }

        /// Per-item delay for staggered appearance, and the index it stops growing at. Without the
        /// cap a 400-tile grid would ripple for ten seconds.
        static let stagger: TimeInterval = 0.028
        static let staggerLimit = 12

        static func staggered(_ animation: Animation, index: Int) -> Animation {
            animation.delay(Double(min(max(index, 0), staggerLimit)) * stagger)
        }
    }

    /// Cached so the 384 call sites never touch UserDefaults per read. Plain globals, not
    /// main-actor isolated: some readers are `ButtonStyle` bodies, which aren't either.
    nonisolated(unsafe) static var appliedAccent = OPNThemePreferences.AccentColor.cloudGreen
    nonisolated(unsafe) static var isDarkPalette = true

    /// Cached for the same reason as `resolvedAccent`: every `Surface`/`Text`/`Stroke` token reads
    /// this on every render of every row and tile, so it must never touch UserDefaults itself.
    /// Starts resolved to dark so a reader that renders before the root's first `onChange` fires -
    /// there isn't one, since `initial: true` runs it before the first frame - still sees today's
    /// shipping colours rather than an unresolved gap.
    nonisolated(unsafe) private static var resolvedPalette = palette(isDark: true)

    /// Single write path for the appearance palette, mirroring `applyAccent`. `.system` is resolved
    /// against `systemColorScheme` here rather than upstream, so every caller passes the same two
    /// things - the stored preference and what the OS currently is - and only this function decides
    /// what they add up to.
    /// Resolves both halves of the theme in one place, and does nothing when neither has moved.
    /// Called from a root view's `body` rather than from `onChange`: a change to either preference
    /// rebuilds subtrees during that same body evaluation, and `onChange` does not run until after
    /// those children have already drawn - so pushing from there painted one change behind.
    @discardableResult
    static func applyTheme(
        accent: OPNThemePreferences.AccentColor,
        appearance: OPNThemePreferences.Appearance,
        systemColorScheme: ColorScheme
    ) -> Bool {
        let key = "\(accent.rawValue)-\(appearance.rawValue)-\(systemColorScheme == .dark)"
        guard key != appliedThemeKey else { return false }
        appliedThemeKey = key
        applyAccent(accent)
        applyAppearance(appearance, systemColorScheme: systemColorScheme)
        return true
    }

    nonisolated(unsafe) private static var appliedThemeKey = ""

    static func isDarkAppearance(_ preference: OPNThemePreferences.Appearance, systemColorScheme: ColorScheme) -> Bool {
        switch preference {
        case .system: systemColorScheme == .dark
        case .dark: true
        case .light: false
        }
    }

    static func applyAppearance(_ preference: OPNThemePreferences.Appearance, systemColorScheme: ColorScheme) {
        let isDark = isDarkAppearance(preference, systemColorScheme: systemColorScheme)
        isDarkPalette = isDark
        resolvedPalette = palette(isDark: isDark)
        resolveAccentColors()
    }

    private static func palette(isDark: Bool) -> ResolvedPalette {
        ResolvedPalette(tokens: isDark ? OPNThemePreferences.darkPaletteTokens : OPNThemePreferences.lightPaletteTokens)
    }

    /// The `Color` form of one `PaletteTokens` set. The one place a palette's plain sRGB tuples turn
    /// into `Color`.
    private struct ResolvedPalette {
        let fillBase: Color
        let fillScale: Double
        let surfaceApp: Color
        let surfaceAppBar: Color
        let surfacePanel: Color
        let surfacePanelRaised: Color
        let surfaceTileTray: Color
        let surfaceField: Color
        let surfaceScrim: Color
        let surfaceDeep: Color
        let surfaceOverlay: Color
        let surfaceChrome: Color
        let textPrimary: Color
        let textSecondary: Color
        let textTertiary: Color
        let textMuted: Color
        let strokeSubtle: Color
        let strokeRegular: Color
        let strokeStrong: Color

        init(tokens: OPNThemePreferences.PaletteTokens) {
            // The text token already carries the direction a palette washes in: white on dark,
            // black on light. A fill is that same ink at a much lower weight.
            fillBase = Self.opaque((tokens.textPrimary.red, tokens.textPrimary.green, tokens.textPrimary.blue))
            fillScale = tokens.textPrimary.red > 0.5 ? 1 : Fill.lightWashScale
            surfaceApp = Self.opaque(tokens.surfaceApp)
            surfaceAppBar = Self.opaque(tokens.surfaceAppBar)
            surfacePanel = Self.opaque(tokens.surfacePanel)
            surfacePanelRaised = Self.opaque(tokens.surfacePanelRaised)
            surfaceTileTray = Self.opaque(tokens.surfaceTileTray)
            surfaceField = Self.opaque(tokens.surfaceField)
            surfaceScrim = Self.translucent(tokens.surfaceScrim)
            surfaceDeep = Self.opaque(tokens.surfaceDeep)
            surfaceOverlay = Self.opaque(tokens.surfaceOverlay)
            surfaceChrome = Self.opaque(tokens.surfaceChrome)
            textPrimary = Self.translucent(tokens.textPrimary)
            textSecondary = Self.translucent(tokens.textSecondary)
            textTertiary = Self.translucent(tokens.textTertiary)
            textMuted = Self.translucent(tokens.textMuted)
            strokeSubtle = Self.translucent(tokens.strokeSubtle)
            strokeRegular = Self.translucent(tokens.strokeRegular)
            strokeStrong = Self.translucent(tokens.strokeStrong)
        }

        private static func opaque(_ components: (red: Double, green: Double, blue: Double)) -> Color {
            Color(red: components.red, green: components.green, blue: components.blue)
        }

        private static func translucent(_ components: (red: Double, green: Double, blue: Double, opacity: Double)) -> Color {
            Color(red: components.red, green: components.green, blue: components.blue, opacity: components.opacity)
        }
    }

    private static func accentColor(for preset: OPNThemePreferences.AccentColor) -> Color {
        let components = preset.components
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    private static func softAccentColor(for preset: OPNThemePreferences.AccentColor) -> Color {
        let components = preset.components
        let lightened = lightenedAccentComponents(red: components.red, green: components.green, blue: components.blue)
        return Color(red: lightened.red, green: lightened.green, blue: lightened.blue)
    }

    /// Fixed amount `accentSoft` lightens by: brightness climbs and saturation falls by the same
    /// amount in HSB space, both clamped to their natural range, so the hue never shifts. Chosen to
    /// reproduce today's shipping accentSoft (0.67, 1.0, 0.36) from Cloud Green (0.46, 0.90, 0.10).
    static let accentLightenAmount = 0.25

    /// Pure so the lightening can be tested without touching `Color`. `amount` moves brightness up
    /// and saturation down together, which is what "lighter" means in HSB without shifting hue.
    static func lightenedAccentComponents(
        red: Double,
        green: Double,
        blue: Double,
        amount: Double = accentLightenAmount
    ) -> (red: Double, green: Double, blue: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let brightness = maximum
        let saturation = maximum == 0 ? 0 : delta / maximum
        let lightenedBrightness = min(1, brightness + amount)

        guard delta > 0 else {
            return (lightenedBrightness, lightenedBrightness, lightenedBrightness)
        }

        let hue: Double
        switch maximum {
        case red: hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
        case green: hue = 60 * ((blue - red) / delta + 2)
        default: hue = 60 * ((red - green) / delta + 4)
        }
        let normalizedHue = hue < 0 ? hue + 360 : hue

        let lightenedSaturation = max(0, saturation - amount)
        let chroma = lightenedBrightness * lightenedSaturation
        let huePrime = normalizedHue / 60
        let secondary = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let matchValue = lightenedBrightness - chroma

        let sector: (red: Double, green: Double, blue: Double)
        switch huePrime {
        case 0..<1: sector = (chroma, secondary, 0)
        case 1..<2: sector = (secondary, chroma, 0)
        case 2..<3: sector = (0, chroma, secondary)
        case 3..<4: sector = (0, secondary, chroma)
        case 4..<5: sector = (secondary, 0, chroma)
        default: sector = (chroma, 0, secondary)
        }

        return (sector.red + matchValue, sector.green + matchValue, sector.blue + matchValue)
    }

    static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

extension View {
    /// Now sits over interactive rows (settings toggles, sliders), not just buttons, so it is
    /// explicitly inert and absent rather than a permanently installed clear stroke.
    /// `onAccentFill` swaps the ring to the page surface colour. An accent ring over an accent
    /// background is invisible, so a focused primary button looked identical to an unfocused one.
    func openNowFocusRing(
        _ isFocused: Bool,
        role: OPNDesign.CornerRole = .control,
        scale: CGFloat = 1,
        onAccentFill: Bool = false
    ) -> some View {
        overlay {
            if isFocused {
                OPNCornerShape(role: role, scale: scale)
                    .strokeBorder(onAccentFill ? OPNDesign.Surface.app : OPNDesign.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Takes `@FocusState` for a field that is being inserted, retrying briefly.
    ///
    /// A focus request made in the same frame as the insertion is dropped - the field is not in the
    /// responder chain yet - so this yields, then re-asks while the field is still meant to be
    /// focused. Both the search field in the top bar and the one in controller mode need it, and a
    /// per-site copy meant the attempt count and delay had to stay in sync by hand.
    func opnTakingFocus(_ isFocused: FocusState<Bool>.Binding, while shouldFocus: Bool) -> some View {
        task(id: shouldFocus) {
            guard shouldFocus else { return }
            await Task.yield()
            for _ in 0..<OPNDesign.focusAttempts {
                guard !Task.isCancelled, shouldFocus else { return }
                if isFocused.wrappedValue { return }
                isFocused.wrappedValue = true
                try? await Task.sleep(for: .milliseconds(OPNDesign.focusRetryMilliseconds))
            }
        }
    }

    func opnInterfaceScale(_ scale: CGFloat) -> some View {
        modifier(OPNInterfaceScaleModifier(scale: scale))
    }

    /// `animation(_:value:)` that answers to Reduce Motion. Springs and long curves collapse to
    /// `Motion.reduced`, so a state change still cross-fades instead of snapping, but nothing
    /// overshoots. One switch here beats a `guard !reduceMotion` at every call site.
    func opnMotion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(OPNMotionModifier(animation: animation, value: value))
    }

    /// Transition that degrades to a plain cross-fade under Reduce Motion, which is exactly what
    /// the setting asks for: the state change still reads, the travel does not happen.
    func opnTransition(_ transition: AnyTransition) -> some View {
        modifier(OPNTransitionModifier(transition: transition))
    }

    /// Hover scale that Reduce Motion flattens. Callers still pair it with `opnMotion` for timing;
    /// this only decides whether the transform is applied at all.
    func opnHoverScale(_ isActive: Bool, factor: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(OPNHoverScaleModifier(isActive: isActive, factor: factor, anchor: anchor))
    }
}

private struct OPNMotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    func body(content: Content) -> some View {
        content.animation(isMotionReduced ? OPNDesign.Motion.reduced : animation, value: value)
    }
}

private struct OPNTransitionModifier: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    func body(content: Content) -> some View {
        content.transition(isMotionReduced ? .opacity : transition)
    }
}

private struct OPNHoverScaleModifier: ViewModifier {
    let isActive: Bool
    let factor: CGFloat
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    func body(content: Content) -> some View {
        content.scaleEffect(isMotionReduced || !isActive ? 1 : factor, anchor: anchor)
    }
}

/// The environment's semantic corner policy. A style change repaints every surface that reads it,
/// rather than requiring the subtrees keyed on the palette to rebuild.
struct OPNCornerGeometry: Equatable, Sendable {
    let style: OPNThemePreferences.CornerStyle

    static let square = OPNCornerGeometry(style: .square)

    func radius(_ role: OPNDesign.CornerRole, scale: CGFloat = 1) -> CGFloat {
        OPNDesign.Corner.radius(role, style: style, scale: scale)
    }
}

private struct OPNCornerGeometryKey: EnvironmentKey {
    static let defaultValue = OPNCornerGeometry.square
}

/// The one shape every app-owned container is drawn with, so a fill, its `strokeBorder` and its
/// `clipShape` agree by construction. Square reproduces the plain `Rectangle` the app shipped.
struct OPNCornerShape: InsettableShape {
    let role: OPNDesign.CornerRole
    let scale: CGFloat
    private let inset: CGFloat

    @Environment(\.opnCornerGeometry) private var geometry

    init(role: OPNDesign.CornerRole, scale: CGFloat = 1) {
        self.init(role: role, scale: scale, inset: 0)
    }

    private init(role: OPNDesign.CornerRole, scale: CGFloat, inset: CGFloat) {
        self.role = role
        self.scale = scale
        self.inset = inset
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(geometry.radius(role, scale: scale) - inset, 0)
        return Path(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerSize: CGSize(width: radius, height: radius),
            style: .continuous
        )
    }

    func inset(by amount: CGFloat) -> OPNCornerShape {
        OPNCornerShape(role: role, scale: scale, inset: inset + amount)
    }
}

/// Real content-size UI scale for Catalog views (replaces the visual scaleEffect hack for that surface only).
private struct OPNUIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var opnUIScale: CGFloat {
        get { self[OPNUIScaleKey.self] }
        set { self[OPNUIScaleKey.self] = newValue }
    }

    var opnCornerGeometry: OPNCornerGeometry {
        get { self[OPNCornerGeometryKey.self] }
        set { self[OPNCornerGeometryKey.self] = newValue }
    }
}

/// Injects the live Corner style into the environment. Every detached root observes the preference
/// itself: the main window, each stream window, the menu bar scene and the Remote Co-Op window.
private struct OPNCornerStyleInjectionModifier: ViewModifier {
    @AppStorage(OPNThemePreferences.cornerStyleKey) private var cornerStyleRawValue = OPNThemePreferences.CornerStyle.square.rawValue

    func body(content: Content) -> some View {
        content.environment(\.opnCornerGeometry, OPNCornerGeometry(style: OPNThemePreferences.CornerStyle(storedRawValue: cornerStyleRawValue)))
    }
}

extension View {
    func opnObservingCornerStyle() -> some View {
        modifier(OPNCornerStyleInjectionModifier())
    }
}

private struct OPNInterfaceScaleModifier: ViewModifier {
    let scale: CGFloat

    private var effectiveScale: CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width / effectiveScale, height: proxy.size.height / effectiveScale)
                .scaleEffect(effectiveScale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .background(magnifiedSurfaceMarker)
        }
    }

    @ViewBuilder
    private var magnifiedSurfaceMarker: some View {
        if effectiveScale != 1 {
            OPNMagnifiedSurfaceMarker()
        }
    }
}

/// Tile-only size multiplier for the Tile Density preference. Kept separate from `opnUIScale`,
/// which scales the whole interface, so the two settings stay independent levers.
private struct OPNTileDensityKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var opnTileDensity: CGFloat {
        get { self[OPNTileDensityKey.self] }
        set { self[OPNTileDensityKey.self] = newValue }
    }
}

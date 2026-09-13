import Darwin
import ObjectiveC
import QuartzCore
import SwiftUI

enum OpenNOWDesign {
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

        static func ink(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
    }

    enum Semantic {
        static let destructive = Color(red: 1, green: 0.54, blue: 0.50)
        /// Favorite state, and the one place a second hue is sanctioned: an accent-green heart
        /// sitting beside an accent-green Play button reads as a second primary action, not a toggle.
        static let favorite = Color(red: 1, green: 0.30, blue: 0.58)
        /// Degraded-but-not-broken state on app-shell surfaces: unsaved edits, a low battery, a
        /// value that still works but wants attention. Matches `WebRTCMediaStreamTheme.warning`
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

    enum Radius {
        private static let baseAvatar: CGFloat = 14
        private static let baseChip: CGFloat = 0
        private static let baseCard: CGFloat = 2
        private static let basePanel: CGFloat = 3

        static let chip: CGFloat = baseChip
        static let card: CGFloat = baseCard
        static let panel: CGFloat = basePanel

        static func avatar(scale: CGFloat) -> CGFloat { baseAvatar * scale }
        static func chip(scale: CGFloat) -> CGFloat { baseChip * scale }
        static func card(scale: CGFloat) -> CGFloat { baseCard * scale }
        static func panel(scale: CGFloat) -> CGFloat { basePanel * scale }
    }

    /// Type roles for the app. `label`/`body` use the app's UI sans (brand voice);
    /// `mono` is reserved for machine readouts (telemetry, counters, codes) so
    /// numerals stay column-aligned while they tick.
    enum Typography {
        static func display(size: CGFloat, scale: CGFloat = 1) -> Font {
            .uiSans(size: size * scale, weight: .black)
        }

        static func label(size: CGFloat, scale: CGFloat = 1, weight: OpenNOWUIFont.Weight = .bold) -> Font {
            .uiSans(size: size * scale, weight: weight)
        }

        static func body(size: CGFloat, scale: CGFloat = 1, weight: OpenNOWUIFont.Weight = .regular) -> Font {
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
        /// Panels and menus entering or leaving. The only spring in the set - travel is the point.
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

    /// Cached so the 384 call sites never touch UserDefaults per read. Plain global, not
    /// main-actor isolated: some readers are `ButtonStyle` bodies, which aren't either.
    nonisolated(unsafe) private static var resolvedAccent = accentColor(for: .cloudGreen)

    /// Cached beside the accent for the same reason: the stream HUD reads it every render.
    nonisolated(unsafe) private static var resolvedAccentSoft = softAccentColor(for: .cloudGreen)

    static var accent: Color { resolvedAccent }

    /// The lightened accent, for text and glyphs that sit on a dark surface beside an accent fill.
    static var accentSoft: Color { resolvedAccentSoft }

    /// The accent as TEXT. A fill can be any weight - a label has to be read, and the shipping
    /// accents are bright enough to disappear on a light page, so this darkens them to clear 4.5:1.
    static var accentInk: Color { resolvedAccentInk }

    /// For the few controls that have to compensate for the appearance rather than just take a
    /// colour from it - a native control whose own chrome does not follow this palette.
    static var isLightAppearance: Bool { !isDarkPalette }

    nonisolated(unsafe) private static var resolvedAccentInk = accentInkColor(for: .cloudGreen, isDark: true)

    private static func accentInkColor(for preset: OpenNOWThemePreferences.AccentColor, isDark: Bool) -> Color {
        let components = preset.components
        guard !isDark else { return Color(red: components.red, green: components.green, blue: components.blue) }
        let surface = OpenNOWThemePreferences.lightPaletteTokens.surfaceApp
        let legible = OpenNOWThemePreferences.legibleAccentComponents(
            red: components.red,
            green: components.green,
            blue: components.blue,
            onSurfaceLuminance: OpenNOWThemePreferences.relativeLuminance(red: surface.red, green: surface.green, blue: surface.blue)
        )
        return Color(red: legible.red, green: legible.green, blue: legible.blue)
    }

    static func applyAccent(_ preset: OpenNOWThemePreferences.AccentColor) {
        appliedAccent = preset
        resolvedAccent = accentColor(for: preset)
        resolvedAccentSoft = softAccentColor(for: preset)
        resolvedAccentInk = accentInkColor(for: preset, isDark: isDarkPalette)
    }

    nonisolated(unsafe) private static var appliedAccent = OpenNOWThemePreferences.AccentColor.cloudGreen
    nonisolated(unsafe) private static var isDarkPalette = true

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
        accent: OpenNOWThemePreferences.AccentColor,
        appearance: OpenNOWThemePreferences.Appearance,
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

    static func isDarkAppearance(_ preference: OpenNOWThemePreferences.Appearance, systemColorScheme: ColorScheme) -> Bool {
        switch preference {
        case .system: systemColorScheme == .dark
        case .dark: true
        case .light: false
        }
    }

    static func applyAppearance(_ preference: OpenNOWThemePreferences.Appearance, systemColorScheme: ColorScheme) {
        let isDark = isDarkAppearance(preference, systemColorScheme: systemColorScheme)
        isDarkPalette = isDark
        resolvedPalette = palette(isDark: isDark)
        resolvedAccentInk = accentInkColor(for: appliedAccent, isDark: isDark)
    }

    private static func palette(isDark: Bool) -> ResolvedPalette {
        ResolvedPalette(tokens: isDark ? OpenNOWThemePreferences.darkPaletteTokens : OpenNOWThemePreferences.lightPaletteTokens)
    }

    /// The `Color` form of one `PaletteTokens` set. The one place a palette's plain sRGB tuples turn
    /// into `Color`, mirroring `accentColor(for:)` just above.
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

        init(tokens: OpenNOWThemePreferences.PaletteTokens) {
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

    private static func accentColor(for preset: OpenNOWThemePreferences.AccentColor) -> Color {
        let components = preset.components
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    private static func softAccentColor(for preset: OpenNOWThemePreferences.AccentColor) -> Color {
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
    func openNowFocusRing(_ isFocused: Bool, onAccentFill: Bool = false) -> some View {
        overlay {
            if isFocused {
                Rectangle()
                    .strokeBorder(onAccentFill ? OpenNOWDesign.Surface.app : OpenNOWDesign.accent, lineWidth: 2)
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
            for _ in 0..<OpenNOWDesign.focusAttempts {
                guard !Task.isCancelled, shouldFocus else { return }
                if isFocused.wrappedValue { return }
                isFocused.wrappedValue = true
                try? await Task.sleep(for: .milliseconds(OpenNOWDesign.focusRetryMilliseconds))
            }
        }
    }

    func opnInterfaceScale(_ scale: CGFloat) -> some View {
        modifier(OpenNOWInterfaceScaleModifier(scale: scale))
    }

    /// `animation(_:value:)` that answers to Reduce Motion. Springs and long curves collapse to
    /// `Motion.reduced`, so a state change still cross-fades instead of snapping, but nothing
    /// overshoots. One switch here beats a `guard !reduceMotion` at every call site.
    func opnMotion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(OpenNOWMotionModifier(animation: animation, value: value))
    }

    /// Transition that degrades to a plain cross-fade under Reduce Motion, which is exactly what
    /// the setting asks for: the state change still reads, the travel does not happen.
    func opnTransition(_ transition: AnyTransition) -> some View {
        modifier(OpenNOWTransitionModifier(transition: transition))
    }

    /// Hover scale that Reduce Motion flattens. Callers still pair it with `opnMotion` for timing;
    /// this only decides whether the transform is applied at all.
    func opnHoverScale(_ isActive: Bool, factor: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(OpenNOWHoverScaleModifier(isActive: isActive, factor: factor, anchor: anchor))
    }
}

private struct OpenNOWMotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OpenNOWThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OpenNOWDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    func body(content: Content) -> some View {
        content.animation(isMotionReduced ? OpenNOWDesign.Motion.reduced : animation, value: value)
    }
}

private struct OpenNOWTransitionModifier: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OpenNOWThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OpenNOWDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    func body(content: Content) -> some View {
        content.transition(isMotionReduced ? .opacity : transition)
    }
}

private struct OpenNOWHoverScaleModifier: ViewModifier {
    let isActive: Bool
    let factor: CGFloat
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OpenNOWThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OpenNOWDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    func body(content: Content) -> some View {
        content.scaleEffect(isMotionReduced || !isActive ? 1 : factor, anchor: anchor)
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
}

private struct OpenNOWInterfaceScaleModifier: ViewModifier {
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
            OpenNOWMagnifiedSurfaceMarker()
        }
    }
}

/// Says whether anything on screen is currently magnified by `opnInterfaceScale`. Correcting layer
/// density rasterises the whole window, so it only pays for itself while a magnified subtree exists.
@MainActor
private final class OpenNOWMagnifiedSurfaceRegistry {
    static let shared = OpenNOWMagnifiedSurfaceRegistry()

    private let surfaces = NSHashTable<NSView>.weakObjects()
    private var changeHandlers: [ObjectIdentifier: () -> Void] = [:]

    var isAnySurfaceMagnified: Bool {
        surfaces.allObjects.contains { $0.window != nil }
    }

    /// Also the detach path: a marker that left the window is still registered but no longer counts,
    /// so re-announcing it on every window change is what retires the correction.
    func announceSurface(_ surface: NSView) {
        surfaces.add(surface)
        notifyChange()
    }

    func removeSurface(_ surface: NSView) {
        surfaces.remove(surface)
        notifyChange()
    }

    func setChangeHandler(for owner: NSView, handler: @escaping () -> Void) {
        changeHandlers[ObjectIdentifier(owner)] = handler
    }

    func removeChangeHandler(for owner: NSView) {
        changeHandlers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func notifyChange() {
        for handler in changeHandlers.values {
            handler()
        }
    }
}

private struct OpenNOWMagnifiedSurfaceMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> OpenNOWMagnifiedSurfaceMarkerView {
        OpenNOWMagnifiedSurfaceMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: OpenNOWMagnifiedSurfaceMarkerView, context: Context) {}

    static func dismantleNSView(_ nsView: OpenNOWMagnifiedSurfaceMarkerView, coordinator: ()) {
        OpenNOWMagnifiedSurfaceRegistry.shared.removeSurface(nsView)
    }
}

final class OpenNOWMagnifiedSurfaceMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        OpenNOWMagnifiedSurfaceRegistry.shared.announceSurface(self)
    }

    /// Presence is all it is for; it must never take a mouse event. It mounts as a full-size
    /// background of every magnified subtree, and one of those is the stream's overlay layer,
    /// which sits above the video surface: hit-testable, it swallowed every mouse-down and scroll
    /// the stream needed. Movement survived on the surface's tracking area and keys on the
    /// responder chain, so the whole thing read as "clicks stopped working in the stream".
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Mount anywhere: it corrects `contentsScale` across the whole window, and stays idle until an
/// `opnInterfaceScale` subtree is on screen, because unmagnified content is already at the right density.
struct OpenNOWInterfaceScaleDensityBooster: NSViewRepresentable {
    let scale: CGFloat

    func makeNSView(context: Context) -> OpenNOWInterfaceScaleDensityView {
        OpenNOWInterfaceScaleDensityView(scale: scale)
    }

    func updateNSView(_ nsView: OpenNOWInterfaceScaleDensityView, context: Context) {
        nsView.scale = scale
    }

    static func dismantleNSView(_ nsView: OpenNOWInterfaceScaleDensityView, coordinator: ()) {
        nsView.restoreNaturalDensity()
        nsView.invalidate()
    }
}

final class OpenNOWInterfaceScaleDensityView: NSView {
    var scale: CGFloat {
        didSet { reconfigure() }
    }
    nonisolated(unsafe) private var runLoopObserver: CFRunLoopObserver?

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        OpenNOWMagnifiedSurfaceRegistry.shared.setChangeHandler(for: self) { [weak self] in
            self?.reconfigure()
        }
        reconfigure()
    }

    func restoreNaturalDensity() {
        applyDensity(targetScale: window?.backingScaleFactor ?? 1)
    }

    func invalidate() {
        OpenNOWMagnifiedSurfaceRegistry.shared.removeChangeHandler(for: self)
        stopObserver()
    }

    private func reconfigure() {
        stopObserver()
        guard window != nil else { return }
        // Only magnified content is rasterised at the wrong density. Walking the window for the
        // catalog, settings or recordings re-renders correct layers at 2.1x the pixels for nothing.
        guard scale != 1, OpenNOWMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified else {
            restoreNaturalDensity()
            return
        }
        walkInterval = Self.activeInterval
        applyDensity(targetScale: effectiveTargetScale())
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self, window != nil, window?.inLiveResize == false else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastApplication >= walkInterval else { return }
            lastApplication = now
            // A magnified subtree can be torn down whole, without its marker being dismantled, so
            // the walk also retires itself the first time it finds nothing magnified left.
            guard OpenNOWMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified else {
                reconfigure()
                return
            }
            // A settled window needs no correcting, and re-walking it ten times a second is pure
            // cost. Back off while nothing changes; a page rebuild puts it straight back.
            walkInterval = applyDensity(targetScale: effectiveTargetScale()) ? Self.activeInterval : min(walkInterval * 2, Self.settledInterval)
        }
        runLoopObserver = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private var lastApplication: CFAbsoluteTime = 0
    private var walkInterval: CFTimeInterval = OpenNOWInterfaceScaleDensityView.activeInterval
    /// How often the tree is corrected while it is still changing, and the ceiling once it is not.
    private static let activeInterval: CFTimeInterval = 0.1
    private static let settledInterval: CFTimeInterval = 0.8

    private func effectiveTargetScale() -> CGFloat {
        scale * (window?.backingScaleFactor ?? 1)
    }

    private func stopObserver() {
        if let runLoopObserver {
            CFRunLoopObserverInvalidate(runLoopObserver)
            self.runLoopObserver = nil
        }
    }

    @discardableResult
    func applyDensity(targetScale: CGFloat) -> Bool {
        guard let root = window?.contentView?.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let didChange = forceContentsScale(root, targetScale: targetScale)
        CATransaction.commit()
        return didChange
    }

    private static let drawingLayerClasses: [AnyClass] = resolveDrawingLayerClasses()

    private static func resolveDrawingLayerClasses() -> [AnyClass] {
        var classes: [AnyClass] = []
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            guard let imageName = _dyld_get_image_name(index) else { continue }
            if strstr(imageName, "SwiftUI") == nil { continue }
            var count: UInt32 = 0
            guard let classNames = objc_copyClassNamesForImage(imageName, &count) else { continue }
            defer { free(UnsafeMutableRawPointer(mutating: classNames)) }
            for classIndex in 0..<Int(count) {
                let className = classNames[classIndex]
                if strstr(className, "CGDrawingLayer") != nil, let resolvedClass = objc_getClass(className) as? AnyClass {
                    classes.append(resolvedClass)
                }
            }
        }
        return classes
    }

    static func isDrawingLayer(_ layer: CALayer) -> Bool {
        guard let layerClass = object_getClass(layer) else { return false }
        if drawingLayerClasses.contains(where: { $0 === layerClass }) {
            return true
        }
        return strstr(object_getClassName(layer), "CGDrawingLayer") != nil
    }

    @discardableResult
    private func forceContentsScale(_ layer: CALayer, targetScale: CGFloat) -> Bool {
        if layer is CAMetalLayer { return false }
        var didChange = false
        if Self.isDrawingLayer(layer), abs(layer.contentsScale - targetScale) > 0.0001 {
            layer.contentsScale = targetScale
            layer.setNeedsDisplay()
            markOwningHostingViewDirty(layer)
            didChange = true
        }
        guard let sublayers = layer.sublayers else { return didChange }
        for sublayer in sublayers where forceContentsScale(sublayer, targetScale: targetScale) {
            didChange = true
        }
        return didChange
    }

    private func markOwningHostingViewDirty(_ layer: CALayer) {
        var current: CALayer? = layer
        while let candidate = current {
            if let view = candidate.delegate as? NSView {
                if strstr(object_getClassName(view), "NSHostingView") != nil {
                    view.needsDisplay = true
                }
                return
            }
            current = candidate.superlayer
        }
    }

    deinit {
        if let runLoopObserver {
            CFRunLoopObserverInvalidate(runLoopObserver)
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

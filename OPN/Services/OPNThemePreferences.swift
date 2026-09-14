//  How the catalog is drawn, independent of what it draws: how much room a tile takes, when its
//  title shows, and whether the interface animates at all.
//

import CoreGraphics
import Foundation

enum OPNThemePreferences {
    /// Tile size relative to the shipping size. Interface Scale grows the whole app; this moves the
    /// tiles alone, so a reader can fit more games on screen without shrinking the type around them.
    enum TileDensity: String, CaseIterable {
        case compact
        case comfortable
        case large

        var label: String {
            switch self {
            case .compact: "Compact"
            case .comfortable: "Comfortable"
            case .large: "Large"
            }
        }

        var tileScale: CGFloat {
            switch self {
            case .compact: 0.82
            case .comfortable: 1.0
            case .large: 1.22
            }
        }
    }

    enum TileTitleVisibility: String, CaseIterable {
        case onHover
        case always
        case never

        var label: String {
            switch self {
            case .onHover: "On Hover"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// The app's accent presets. `OPN` must not import SwiftUI, so each case exposes plain sRGB
    /// components; the View layer is the one place that turns them into a `Color`.
    enum AccentColor: String, CaseIterable {
        case cloudGreen
        case sky
        case violet
        case magenta
        case amber
        case coral

        var label: String {
            switch self {
            case .cloudGreen: "Cloud Green"
            case .sky: "Sky"
            case .violet: "Violet"
            case .magenta: "Magenta"
            case .amber: "Amber"
            case .coral: "Coral"
            }
        }

        /// The one place these presets' sRGB values are written down. Every other reader, in this
        /// file or in the View layer, goes through this rather than repeating a literal. These are
        /// the values chosen to sit on a near-black page; `lightComponents` is their light twin.
        var components: (red: Double, green: Double, blue: Double) {
            switch self {
            case .cloudGreen: (0.46, 0.90, 0.10)
            case .sky: (0.36, 0.78, 1.00)
            case .violet: (0.70, 0.60, 1.00)
            case .magenta: (1.00, 0.42, 0.78)
            case .amber: (1.00, 0.75, 0.20)
            case .coral: (1.00, 0.55, 0.45)
            }
        }

        /// The same hue taken deeper and a little less saturated, because a colour picked to glow
        /// on near-black glares on near-white. Each clears the text contrast floor against the
        /// light page and carries white text when it is used as a fill.
        var lightComponents: (red: Double, green: Double, blue: Double) {
            switch self {
            case .cloudGreen: (0.24, 0.43, 0.04)
            case .sky: (0.05, 0.34, 0.56)
            case .violet: (0.36, 0.25, 0.68)
            case .magenta: (0.64, 0.07, 0.41)
            case .amber: (0.45, 0.30, 0.02)
            case .coral: (0.64, 0.17, 0.11)
            }
        }

        func components(isDark: Bool) -> (red: Double, green: Double, blue: Double) {
            isDark ? components : lightComponents
        }
    }

    /// Which palette the app draws. Default is `.dark`, not `.system`: today's app is dark-only, so
    /// an existing user must see no change at all until they explicitly ask for one.
    enum Appearance: String, CaseIterable {
        case system
        case dark
        case light

        var label: String {
            switch self {
            case .system: "Match System"
            case .dark: "Dark"
            case .light: "Light"
            }
        }
    }

    static let tileDensityKey = "OpenNOW.Interface.TileDensity"
    static let tileTitleVisibilityKey = "OpenNOW.Interface.TileTitles"
    static let isMotionReducedKey = "OpenNOW.Interface.ReduceMotion"
    static let accentColorKey = "OpenNOW.Interface.Accent"
    static let appearanceKey = "OpenNOW.Interface.Appearance"
    static let isJumpBackInEnabledKey = "OpenNOW.Interface.JumpBackIn"

    /// Non-SwiftUI/AppKit access point: whatever the stored raw value is, an unknown one falls
    /// back to the shipping default rather than surfacing as an optional everywhere it is read.
    static var accentColor: AccentColor {
        get {
            guard let rawValue = OPNAppPreferenceStorage.standard.string(forKey: accentColorKey) else { return .cloudGreen }
            return AccentColor(rawValue: rawValue) ?? .cloudGreen
        }
        set { OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: accentColorKey) }
    }

    /// Non-SwiftUI/AppKit access point, mirroring `accentColor`: an unknown stored value falls back
    /// to the shipping default (dark) rather than surfacing as an optional everywhere it is read.
    static var appearance: Appearance {
        get {
            guard let rawValue = OPNAppPreferenceStorage.standard.string(forKey: appearanceKey) else { return .dark }
            return Appearance(rawValue: rawValue) ?? .dark
        }
        set { OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    /// Whether the home page draws the Jump Back In rail above My Favorites. Shipping default is
    /// on, so presence is checked before `bool`, which reports false for a key never written.
    static var isJumpBackInEnabled: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: isJumpBackInEnabledKey) != nil else { return true }
            return OPNAppPreferenceStorage.standard.bool(forKey: isJumpBackInEnabledKey)
        }
        set { OPNAppPreferenceStorage.standard.set(newValue, forKey: isJumpBackInEnabledKey) }
    }

    /// WCAG relative luminance of an sRGB colour, 0 (black) to 1 (white). Pure so the presets can
    /// be checked without touching `Color`, which this target may not import.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    /// Floor every preset must clear so black text (the PLAY button, among others) stays legible
    /// on top of it: half of the shipping default's own luminance, grounded in what already ships
    /// rather than an arbitrary WCAG number.
    static let minimumAccentLuminance = relativeLuminance(
        red: AccentColor.cloudGreen.components.red,
        green: AccentColor.cloudGreen.components.green,
        blue: AccentColor.cloudGreen.components.blue
    ) * 0.5

    /// WCAG contrast ratio between two sRGB colours, always >= 1 regardless of which one is passed
    /// first. Pure, beside `relativeLuminance`, for the same reason: a palette's legibility has to be
    /// checkable without importing `Color`.
    static func contrastRatio(
        red: Double, green: Double, blue: Double,
        againstRed: Double, againstGreen: Double, againstBlue: Double
    ) -> Double {
        let luminance = relativeLuminance(red: red, green: green, blue: blue)
        let againstLuminance = relativeLuminance(red: againstRed, green: againstGreen, blue: againstBlue)
        let lighter = max(luminance, againstLuminance)
        let darker = min(luminance, againstLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Plain sRGB description of one appearance's full surface/text/stroke set. Mirrors
    /// `AccentColor.components`: no `Color` here, so a palette's contrast can be checked without
    /// importing SwiftUI, and the View layer alone turns these into real colours.
    struct PaletteTokens {
        let surfaceApp: (red: Double, green: Double, blue: Double)
        let surfaceAppBar: (red: Double, green: Double, blue: Double)
        let surfacePanel: (red: Double, green: Double, blue: Double)
        let surfacePanelRaised: (red: Double, green: Double, blue: Double)
        let surfaceTileTray: (red: Double, green: Double, blue: Double)
        let surfaceField: (red: Double, green: Double, blue: Double)
        let surfaceScrim: (red: Double, green: Double, blue: Double, opacity: Double)
        let surfaceDeep: (red: Double, green: Double, blue: Double)
        let surfaceOverlay: (red: Double, green: Double, blue: Double)
        let surfaceChrome: (red: Double, green: Double, blue: Double)
        let textPrimary: (red: Double, green: Double, blue: Double, opacity: Double)
        let textSecondary: (red: Double, green: Double, blue: Double, opacity: Double)
        let textTertiary: (red: Double, green: Double, blue: Double, opacity: Double)
        let textMuted: (red: Double, green: Double, blue: Double, opacity: Double)
        let strokeSubtle: (red: Double, green: Double, blue: Double, opacity: Double)
        let strokeRegular: (red: Double, green: Double, blue: Double, opacity: Double)
        let strokeStrong: (red: Double, green: Double, blue: Double, opacity: Double)
    }

    /// Today's shipping dark values, unchanged: every existing reader must see the exact colours it
    /// saw before Appearance existed.
    static let darkPaletteTokens = PaletteTokens(
        surfaceApp: (25 / 255, 25 / 255, 25 / 255),
        surfaceAppBar: (45 / 255, 45 / 255, 45 / 255),
        surfacePanel: (28 / 255, 28 / 255, 28 / 255),
        surfacePanelRaised: (34 / 255, 34 / 255, 34 / 255),
        surfaceTileTray: (41 / 255, 41 / 255, 41 / 255),
        surfaceField: (31 / 255, 31 / 255, 31 / 255),
        surfaceScrim: (0, 0, 0, 0.58),
        surfaceDeep: (18 / 255, 19 / 255, 18 / 255),
        surfaceOverlay: (23 / 255, 23 / 255, 23 / 255),
        surfaceChrome: (57 / 255, 57 / 255, 59 / 255),
        textPrimary: (1, 1, 1, 0.96),
        textSecondary: (1, 1, 1, 0.72),
        textTertiary: (1, 1, 1, 0.52),
        textMuted: (1, 1, 1, 0.38),
        strokeSubtle: (1, 1, 1, 0.10),
        strokeRegular: (1, 1, 1, 0.14),
        strokeStrong: (1, 1, 1, 0.22)
    )

    /// Author's-choice light palette. Every surface keeps the dark palette's ROLE and RANK rather
    /// than inverting its numbers: `deep` stays the recessed-most surface and `chrome` stays the
    /// raised-most one, just recalibrated into a light range instead of trading places. Text and
    /// Stroke keep white-on-dark's "faint to loud" ordering, but flip from white to black, because a
    /// white stroke or a white label over a light surface would not be a lighter version of the same
    /// role - it would be invisible. Values are picked and checked against `contrastRatio` below.
    static let lightPaletteTokens = PaletteTokens(
        surfaceApp: (227 / 255, 227 / 255, 227 / 255),
        surfaceAppBar: (253 / 255, 253 / 255, 253 / 255),
        surfacePanel: (236 / 255, 236 / 255, 236 / 255),
        surfacePanelRaised: (246 / 255, 246 / 255, 246 / 255),
        surfaceTileTray: (250 / 255, 250 / 255, 250 / 255),
        surfaceField: (241 / 255, 241 / 255, 241 / 255),
        surfaceScrim: (0, 0, 0, 0.58),
        surfaceDeep: (214 / 255, 214 / 255, 214 / 255),
        surfaceOverlay: (220 / 255, 220 / 255, 220 / 255),
        surfaceChrome: (253 / 255, 253 / 255, 255 / 255),
        textPrimary: (0, 0, 0, 0.90),
        textSecondary: (0, 0, 0, 0.62),
        textTertiary: (0, 0, 0, 0.50),
        textMuted: (0, 0, 0, 0.46),
        strokeSubtle: (0, 0, 0, 0.10),
        strokeRegular: (0, 0, 0, 0.14),
        strokeStrong: (0, 0, 0, 0.22)
    )

    /// Whether a tile draws its title tray right now. The one place this decision is made: every
    /// catalog tile feeds its own hover/selection state through this instead of repeating the rule.
    /// Darkens an accent until it clears `minimumTextContrastRatio` against the page it is drawn on,
    /// so accent-coloured labels stay legible when the page is light.
    static func legibleAccentComponents(
        red: Double,
        green: Double,
        blue: Double,
        onSurfaceLuminance surfaceLuminance: Double
    ) -> (red: Double, green: Double, blue: Double) {
        var scale = 1.0
        while scale > 0.2 {
            let luminance = relativeLuminance(red: red * scale, green: green * scale, blue: blue * scale)
            let lighter = max(luminance, surfaceLuminance)
            let darker = min(luminance, surfaceLuminance)
            guard (lighter + 0.05) / (darker + 0.05) < minimumTextContrastRatio else {
                return (red * scale, green * scale, blue * scale)
            }
            scale -= 0.02
        }
        return (red * scale, green * scale, blue * scale)
    }

    static let minimumTextContrastRatio = 4.5

    static func showsTileTitle(visibility: TileTitleVisibility, isHovering: Bool, isSelected: Bool) -> Bool {
        switch visibility {
        case .onHover: isHovering || isSelected
        case .always: true
        case .never: false
        }
    }
}

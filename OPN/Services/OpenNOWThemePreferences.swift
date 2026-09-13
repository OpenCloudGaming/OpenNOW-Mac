//  How the catalog is drawn, independent of what it draws: how much room a tile takes, when its
//  title shows, and whether the interface animates at all.
//

import CoreGraphics
import Foundation

enum OpenNOWThemePreferences {
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
        /// file or in the View layer, goes through this rather than repeating a literal.
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
    }

    static let tileDensityKey = "OpenNOW.Interface.TileDensity"
    static let tileTitleVisibilityKey = "OpenNOW.Interface.TileTitles"
    static let isMotionReducedKey = "OpenNOW.Interface.ReduceMotion"
    static let accentColorKey = "OpenNOW.Interface.Accent"

    /// Non-SwiftUI/AppKit access point: whatever the stored raw value is, an unknown one falls
    /// back to the shipping default rather than surfacing as an optional everywhere it is read.
    static var accentColor: AccentColor {
        get {
            guard let rawValue = OPNAppPreferenceStorage.standard.string(forKey: accentColorKey) else { return .cloudGreen }
            return AccentColor(rawValue: rawValue) ?? .cloudGreen
        }
        set { OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: accentColorKey) }
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

    /// Whether a tile draws its title tray right now. The one place this decision is made: every
    /// catalog tile feeds its own hover/selection state through this instead of repeating the rule.
    static func showsTileTitle(visibility: TileTitleVisibility, isHovering: Bool, isSelected: Bool) -> Bool {
        switch visibility {
        case .onHover: isHovering || isSelected
        case .always: true
        case .never: false
        }
    }
}

//  How the catalog is drawn, independent of what it draws: how much room a tile takes, when its
//  title shows, and whether the interface animates at all.
//

import CoreGraphics

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

    static let tileDensityKey = "OpenNOW.Interface.TileDensity"
    static let tileTitleVisibilityKey = "OpenNOW.Interface.TileTitles"
    static let isMotionReducedKey = "OpenNOW.Interface.ReduceMotion"

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

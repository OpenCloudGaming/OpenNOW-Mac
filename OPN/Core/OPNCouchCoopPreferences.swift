import Foundation

enum OPNCouchCoopLayout: String, CaseIterable, Equatable, Sendable {
    case sideBySide
    case topAndBottom
    case manual

    static let defaultLayout = OPNCouchCoopLayout.sideBySide

    var label: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .topAndBottom: "Top and Bottom"
        case .manual: "Manual"
        }
    }

    var summary: String {
        switch self {
        case .sideBySide: "Each copy takes half the screen's width and letterboxes its 16:9 stream."
        case .topAndBottom: "Each copy takes half the screen's height, and a 32:9 stream fills the half."
        case .manual: "OpenNOW leaves the windows alone. Arrange them yourself, or use macOS Split View."
        }
    }
}

enum OPNCouchCoopPreferences {
    static let layoutKey = "OpenNOW.CouchCoop.Layout"

    static func layout(storage: OPNAppPreferenceStorage = .standard) -> OPNCouchCoopLayout {
        guard let rawValue = storage.string(forKey: layoutKey), let layout = OPNCouchCoopLayout(rawValue: rawValue) else {
            return OPNCouchCoopLayout.defaultLayout
        }
        return layout
    }

    static func setLayout(_ layout: OPNCouchCoopLayout, storage: OPNAppPreferenceStorage = .standard) {
        storage.set(layout.rawValue, forKey: layoutKey)
    }
}

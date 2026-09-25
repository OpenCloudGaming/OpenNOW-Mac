//  The collapsible groups of the unified stream HUD dock and the preferences that remember how the
//  reader arranged them: order, folded set, hidden set, and whether the dock shows a clock.
//

import Foundation

/// One collapsible group in the unified HUD dock. `title` is the eyebrow the panel draws, so the
/// dock and the layout editor read one label. `focusID` is the header's gamepad focus identity.
enum OPNStreamHUDSection: String, CaseIterable, Identifiable, Sendable {
    case session
    case audio
    case capture
    case display
    case input
    case controllers
    case network
    case stats
    case coop
    case upscaling
    case stream

    var id: String { rawValue }

    var focusID: String { "section-\(rawValue)" }

    var title: String {
        switch self {
        case .session: return "SESSION"
        case .audio: return "AUDIO"
        case .capture: return "CAPTURE"
        case .display: return "DISPLAY"
        case .input: return "INPUT"
        case .controllers: return "CONTROLLERS"
        case .network: return "NETWORK"
        case .stats: return "STATS"
        case .coop: return "CO-OP"
        case .upscaling: return "UPSCALING"
        case .stream: return "STREAM"
        }
    }
}

enum OPNStreamHUDSettings {
    static let collapsedSectionsKey = "OpenNOW.Stream.HUDCollapsedSections"
    static let sectionOrderKey = "OpenNOW.Stream.HUDSectionOrder"
    static let hiddenSectionsKey = "OpenNOW.Stream.HUDHiddenSections"
    static let clockVisibleKey = "OpenNOW.Stream.HUDClockVisible"

    private static let storage = OPNAppPreferenceStorage.standard

    /// Global across sessions and titles: folding a section keeps it folded every time the HUD opens.
    /// Unknown stored values are ignored, so a renamed or removed section is simply not applied.
    static var collapsedSections: Set<OPNStreamHUDSection> {
        get {
            let raw = storage.array(forKey: collapsedSectionsKey) as? [String] ?? []
            return Set(raw.compactMap(OPNStreamHUDSection.init(rawValue:)))
        }
        set {
            storage.set(newValue.map(\.rawValue).sorted(), forKey: collapsedSectionsKey)
        }
    }

    /// The dock order. A section added in a later build is appended rather than hidden by a stored
    /// order that predates it, so a new panel can never go missing behind a customization.
    static var sectionOrder: [OPNStreamHUDSection] {
        get {
            let raw = storage.array(forKey: sectionOrderKey) as? [String] ?? []
            var order = raw.compactMap(OPNStreamHUDSection.init(rawValue:))
            for section in OPNStreamHUDSection.allCases where !order.contains(section) {
                order.append(section)
            }
            return order
        }
        set {
            storage.set(newValue.map(\.rawValue), forKey: sectionOrderKey)
        }
    }

    static var hiddenSections: Set<OPNStreamHUDSection> {
        get {
            let raw = storage.array(forKey: hiddenSectionsKey) as? [String] ?? []
            return Set(raw.compactMap(OPNStreamHUDSection.init(rawValue:)))
        }
        set {
            storage.set(newValue.map(\.rawValue).sorted(), forKey: hiddenSectionsKey)
        }
    }

    /// The dock clock is on by default; `object(forKey:)` is read rather than `bool(forKey:)` so an
    /// untouched preference is not mistaken for the `false` an absent value would otherwise give.
    static var isClockVisible: Bool {
        get { storage.object(forKey: clockVisibleKey) as? Bool ?? true }
        set { storage.set(newValue, forKey: clockVisibleKey) }
    }
}

//  The stored shape of the floating stream statistics overlay: how much detail it shows and which
//  corner it occupies. The overlay's on/off state is per-session, so it lives on each surface; only
//  the detail level and the corner are preferences.
//

import Foundation

/// How much of the statistics the floating overlay shows. Every level keeps the headline readings;
/// the difference is how many of the detail rows come with them.
enum StreamStatsDetailLevel: String, CaseIterable, Identifiable, Sendable {
    /// The headline readings alone: every frame rate the transport exposes plus latency.
    case minimum
    /// The headline readings plus the handful of numbers most sessions are judged by.
    case compact
    /// Everything the surface can report.
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimum: return "Minimum"
        case .compact: return "Compact"
        case .advanced: return "Advanced"
        }
    }
}

/// Which corner of the stream surface the floating statistics overlay occupies.
enum StreamStatsHUDPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topTrailing: return "Top Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }

    /// A leading corner sits behind the unified sidebar, so the overlay steps clear of it while the
    /// sidebar is open.
    var isLeading: Bool {
        self == .topLeading || self == .bottomLeading
    }
}

enum OPNStreamStatsHUDSettings {
    static let detailLevelKey = "OpenNOW.Stream.StatsDetailLevel"
    static let positionKey = "OpenNOW.Stream.StatsPosition"

    /// Advanced keeps the full panel an existing reader already had, and top-right is where that
    /// panel has always sat, so neither preference changes an untouched session.
    static let defaultDetailLevel = StreamStatsDetailLevel.advanced
    static let defaultPosition = StreamStatsHUDPosition.topTrailing

    private static let storage = OPNAppPreferenceStorage.standard

    static var detailLevel: StreamStatsDetailLevel {
        get {
            guard let raw = storage.string(forKey: detailLevelKey),
                  let level = StreamStatsDetailLevel(rawValue: raw) else { return defaultDetailLevel }
            return level
        }
        set { storage.set(newValue.rawValue, forKey: detailLevelKey) }
    }

    static var position: StreamStatsHUDPosition {
        get {
            guard let raw = storage.string(forKey: positionKey),
                  let position = StreamStatsHUDPosition(rawValue: raw) else { return defaultPosition }
            return position
        }
        set { storage.set(newValue.rawValue, forKey: positionKey) }
    }
}

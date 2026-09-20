import Foundation

/// What the Dock tile shows on top of the icon: the badge the system draws, and the fraction the
/// app-drawn progress bar fills.
///
/// Pure, the way `OPNDockIconController.shouldHideDockIcon` is: a Dock exists only in a running app,
/// so the decisions live here where a test can hold them and every `NSDockTile` call stays in one
/// place.
struct OPNDockTileContent: Equatable, Sendable {
    /// How many sessions are waiting on the user. Nil means no badge at all — an empty badge is not
    /// the same as a cleared one, and the Dock draws nothing for nil.
    var pendingSessions: Int?
    /// The fraction the progress bar fills, 0…1 and quantized. Nil means no progress bar at all.
    var progressFraction: Double?

    static let none = OPNDockTileContent()

    var badgeLabel: String? {
        guard let pendingSessions, pendingSessions > 0 else { return nil }
        // Capped like every other badge on the system: past two digits the exact count is wider than
        // the tile and is not a number anyone acts on.
        return pendingSessions > 99 ? "99+" : String(pendingSessions)
    }

    /// The sessions the user has to act on: one being acquired, and one that exists but is not
    /// streaming here.
    ///
    /// They are counted rather than merged because they are separate seats from the user's point of
    /// view, and the badge is a count of things waiting — not arithmetic on a set that is normally
    /// one item long.
    static func pendingSessionCount(isQueued: Bool, hasResumableSession: Bool) -> Int? {
        let count = (isQueued ? 1 : 0) + (hasResumableSession ? 1 : 0)
        return count > 0 ? count : nil
    }

    /// Which wait gets the tile when two are running at once.
    ///
    /// The queue wins: it is the one the user is blocked behind, and the one that ends in a game.
    /// An export runs beside the window that started it and can be watched there, and a seat cannot
    /// be watched anywhere else.
    ///
    /// Quantized to whole percent because the tile is a picture of a number the user reads, and every
    /// write redraws the Dock icon. The editor publishes on that same granularity for the same
    /// reason, so the two agree about what counts as a change.
    static func progressFraction(queue: Double?, export: Double?) -> Double? {
        guard let fraction = queue ?? export else { return nil }
        let clamped = min(1, max(0, fraction))
        return (clamped * 100).rounded() / 100
    }
}

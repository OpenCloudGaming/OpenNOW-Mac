import Foundation

/// What the Dock tile's progress bar is drawing.
///
/// A measured fraction is the queue and the export: both report how far along they are. Starting a
/// stream reports no fraction — the session has been allocated, but no frame has arrived — so its
/// bar is indeterminate, a sweep that says "working" without inventing progress.
enum OPNDockProgress: Equatable, Sendable {
    case determinate(Double)
    case indeterminate
}

/// What the Dock tile shows on top of the icon: the badge the system draws, and the progress bar the
/// app draws.
///
/// Pure, the way `OPNDockIconController.shouldHideDockIcon` is: a Dock exists only in a running app,
/// so the decisions live here where a test can hold them and every `NSDockTile` call stays in one
/// place.
struct OPNDockTileContent: Equatable, Sendable {
    /// How many sessions are waiting on the user. Nil means no badge at all — an empty badge is not
    /// the same as a cleared one, and the Dock draws nothing for nil.
    var pendingSessions: Int?
    /// The progress bar's state. Nil means no progress bar at all.
    var progress: OPNDockProgress?

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
    /// one item long. A stream that is merely starting is not counted: there is nothing for the user
    /// to act on, and the sweep on the tile is where that state is shown.
    static func pendingSessionCount(isQueued: Bool, hasResumableSession: Bool) -> Int? {
        let count = (isQueued ? 1 : 0) + (hasResumableSession ? 1 : 0)
        return count > 0 ? count : nil
    }

    /// Which wait gets the tile when more than one is running at once.
    ///
    /// The queue wins: it is the one the user is blocked behind, and it is the only one that reports
    /// a fraction to fill the bar with. A stream being started comes next — it, too, ends in a game
    /// and has nothing to watch in the window until it does — and it takes the bar as an
    /// indeterminate sweep. An export is last: it runs beside the window that started it, where it
    /// can be watched, and its determinate bar returns the moment the stream is ready.
    ///
    /// Quantized to whole percent because the tile is a picture of a number the user reads, and every
    /// write redraws the Dock icon. The editor publishes on that same granularity for the same
    /// reason, so the two agree about what counts as a change.
    static func progress(queue: Double?, isStarting: Bool, export: Double?) -> OPNDockProgress? {
        if let queue { return .determinate(quantized(queue)) }
        if isStarting { return .indeterminate }
        guard let export else { return nil }
        return .determinate(quantized(export))
    }

    private static func quantized(_ fraction: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        return (clamped * 100).rounded() / 100
    }
}

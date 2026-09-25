//  The stream session's time limit: the initial window from the session descriptor, corrected by
//  the seat's live timer for the HUD's countdown and elapsed time.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// Replaces the countdown's window with the seat's live timer. A limit the seat extends or
    /// shortens mid-session would otherwise keep drifting from the real deadline.
    func applyNativeSessionLimitUpdate(_ update: StreamSessionLimitUpdate) {
        guard let limit = StreamSessionSidebarLimit(update: update) else { return }
        sessionLimit = limit
    }
}

//  When a stream's controllers keep playing while another stream window has the focus.

import Foundation

enum OPNCouchCoopInputPolicy {
    /// Pads are a device the system delivers to the process rather than to a window, so two streams
    /// can each play their own while one holds the keyboard. That is only wanted when couch co-op is
    /// on and there is a second stream for it to matter to.
    static func allowsBackgroundGamepads(isFlagEnabled: Bool, liveStreamCount: Int) -> Bool {
        isFlagEnabled && liveStreamCount >= 2
    }
}

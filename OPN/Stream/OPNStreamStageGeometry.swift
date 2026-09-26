//  Where the picture sits inside the stream window, as pure geometry.
//
//  Lives outside the SwiftUI view because both the windowed stage layout (a SwiftUI view) and the
//  Picture-in-Picture resize (AppKit, and deliberately SwiftUI-free) need the same answer, and a
//  second copy of this arithmetic is exactly how the two would drift apart.
//

import CoreGraphics
import Foundation

enum OPNStreamStageGeometry {
    /// The largest box of `aspectRatio` that fits inside `viewport`, or `nil` when the viewport or
    /// the ratio is unusable. This is the arithmetic both callers want; the one below only decides
    /// whether there is any point fitting at all.
    static func aspectFitted(viewport: CGSize, aspectRatio: CGFloat) -> CGSize? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        guard aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        let heightForFullWidth = viewport.width / aspectRatio
        if heightForFullWidth <= viewport.height {
            return CGSize(width: viewport.width, height: heightForFullWidth)
        }
        return CGSize(width: viewport.height * aspectRatio, height: viewport.height)
    }

    /// The largest box of `aspectRatio` that fits the viewport once the titlebar strip is taken off
    /// it. Falls back to the whole viewport when there is no inset or no usable aspect.
    ///
    /// A zero inset deliberately means "the viewport already is the shape of what fits": in windowed
    /// mode the window itself is locked to the stream's ratio, and in full screen there is no strip
    /// to reserve. Picture-in-Picture wants the fit without a strip to reserve it against, so it
    /// calls `aspectFitted` directly rather than reading anything into a zero inset.
    static func contentSize(viewport: CGSize, topInset: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let availableHeight = max(viewport.height - topInset, 0)
        let available = CGSize(width: viewport.width, height: availableHeight)
        guard topInset > 0, viewport.width > 0, availableHeight > 0 else { return available }
        return aspectFitted(viewport: available, aspectRatio: aspectRatio) ?? available
    }
}

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
    /// it. A zero inset means the viewport already is the shape of what fits.
    static func contentSize(viewport: CGSize, topInset: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let availableHeight = max(viewport.height - topInset, 0)
        let available = CGSize(width: viewport.width, height: availableHeight)
        guard topInset > 0, viewport.width > 0, availableHeight > 0 else { return available }
        return aspectFitted(viewport: available, aspectRatio: aspectRatio) ?? available
    }

    /// A box of `size` centred in `visibleFrame`, clamped so a frame smaller than the box still
    /// leaves it on screen. The one placement both the stream window and Picture-in-Picture open at.
    static func centered(size: CGSize, within visibleFrame: NSRect) -> NSRect {
        let centered = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clamped(centered, within: visibleFrame)
    }

    /// Pushes a frame back inside `visibleFrame`, so a placement remembered on a display that no
    /// longer exists cannot open off the desktop.
    static func clamped(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        var clamped = frame
        clamped.origin.x = max(visibleFrame.minX, min(frame.origin.x, visibleFrame.maxX - frame.width))
        clamped.origin.y = max(visibleFrame.minY, min(frame.origin.y, visibleFrame.maxY - frame.height))
        return clamped
    }
}

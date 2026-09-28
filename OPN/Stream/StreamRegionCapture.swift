//  The geometry of a freeze-frame region drag, and the frame waiting to be read.
//
//  Region mode is the ⌘⇧4 of the stream: the copy chord freezes the picture, the reader drags over
//  the text worth keeping, and that rectangle is what gets read. Everything here is pure arithmetic
//  so the mapping from a drag in view points to a rectangle in Vision's normalized space can be
//  tested without rendering a frame.
//

import CoreGraphics
import Foundation

/// A frozen frame waiting for the reader to drag the area worth reading.
struct StreamRegionCapture: Sendable {
    let image: StreamScreenshotImage

    var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

enum StreamRegionCaptureGeometry {
    /// A drag smaller than this many points is a click, not a region.
    static let minimumDragPoints: CGFloat = 6

    /// Where a frame of `imageSize` is drawn inside `bounds`, scaled to fit and centred — the same
    /// letterboxing the video surface uses, so what the reader drags over is what gets read.
    static func fittedRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The Vision-normalized rectangle a drag names, or nil when it is too small to be a region.
    ///
    /// The drag arrives in view points, whose vertical axis runs down from the top; Vision measures
    /// up from the bottom, so the flip happens here once, and the result is clamped to the frame.
    static func visionRect(dragStart: CGPoint, dragEnd: CGPoint, in fitted: CGRect) -> CGRect? {
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let drag = CGRect(
            x: min(dragStart.x, dragEnd.x),
            y: min(dragStart.y, dragEnd.y),
            width: abs(dragEnd.x - dragStart.x),
            height: abs(dragEnd.y - dragStart.y)
        )
        guard drag.width >= minimumDragPoints, drag.height >= minimumDragPoints else { return nil }
        let clamped = drag.intersection(fitted)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        let x = (clamped.minX - fitted.minX) / fitted.width
        let yTop = (clamped.minY - fitted.minY) / fitted.height
        let width = clamped.width / fitted.width
        let height = clamped.height / fitted.height
        return CGRect(x: x, y: 1 - yTop - height, width: width, height: height)
    }
}

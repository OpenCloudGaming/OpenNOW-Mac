//  Region mode's frozen frame, and the geometry that turns a drag into a rectangle of it.
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
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - fittedSize.width) / 2,
            y: (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// The Vision-normalized rectangle a drag names, or nil when it is too small to be a region.
    ///
    /// View points run down from the top and Vision measures up from the bottom, so the flip happens
    /// here once; the result is clamped to the frame.
    static func visionRect(dragStart: CGPoint, dragEnd: CGPoint, in fittedFrame: CGRect) -> CGRect? {
        guard fittedFrame.width > 0, fittedFrame.height > 0 else { return nil }
        let draggedRect = CGRect(
            x: min(dragStart.x, dragEnd.x),
            y: min(dragStart.y, dragEnd.y),
            width: abs(dragEnd.x - dragStart.x),
            height: abs(dragEnd.y - dragStart.y)
        )
        guard draggedRect.width >= minimumDragPoints, draggedRect.height >= minimumDragPoints else { return nil }
        let clampedRect = draggedRect.intersection(fittedFrame)
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else { return nil }
        let x = (clampedRect.minX - fittedFrame.minX) / fittedFrame.width
        let yFromTop = (clampedRect.minY - fittedFrame.minY) / fittedFrame.height
        let width = clampedRect.width / fittedFrame.width
        let height = clampedRect.height / fittedFrame.height
        return CGRect(x: x, y: 1 - yFromTop - height, width: width, height: height)
    }
}

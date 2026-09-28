//  The rectangle the reader dragged over a stream to select text.
//

import CoreGraphics
import Foundation

/// The pointer in Vision's normalized space, or nil when the event carries no usable viewport.
extension NativeNVSTAbsoluteMouseEvent {
    /// The wire position is top-left origin; Vision measures from the bottom-left, so the vertical
    /// axis is flipped here once rather than at every use.
    var visionUnitPoint: CGPoint? {
        guard viewportWidth > 0, viewportHeight > 0 else { return nil }
        let unitX = Double(x) / Double(viewportWidth)
        let unitY = Double(y) / Double(viewportHeight)
        guard unitX.isFinite, unitY.isFinite else { return nil }
        return CGPoint(x: min(max(unitX, 0), 1), y: min(max(1 - unitY, 0), 1))
    }
}

/// Tracks the last left-button drag, so a copy can be read from the rectangle the reader selected.
struct StreamPointerSelectionTracker: Equatable, Sendable {
    /// A drag has to cover this share of the frame before it is a selection rather than a click.
    static let minimumWidth = 0.02
    static let minimumHeight = 0.01

    private var latestPointerPoint: CGPoint?
    private var dragStartPoint: CGPoint?
    private(set) var lastSelectionRect: CGRect?
    private(set) var lastSelectionAt: Date?

    /// Records the latest absolute pointer position, normalized.
    mutating func notePointer(_ point: CGPoint) {
        latestPointerPoint = point
    }

    /// Records the latest position straight from the wire event. An event with no viewport leaves the
    /// previous position alone rather than erasing it.
    mutating func notePointer(_ event: NativeNVSTAbsoluteMouseEvent) {
        guard let point = event.visionUnitPoint else { return }
        latestPointerPoint = point
    }

    /// A left-button edge. A large enough drag becomes the selection; a click drops whatever was
    /// selected before, because the reader has moved on.
    mutating func noteLeftButton(isPressed: Bool, at date: Date) {
        guard isPressed else {
            recordSelection(at: date)
            return
        }
        dragStartPoint = latestPointerPoint
    }

    /// The drag rectangle while it is still the reader's most recent act of selection.
    func recentSelection(at date: Date, maximumAge: TimeInterval) -> CGRect? {
        guard let lastSelectionRect, let lastSelectionAt else { return nil }
        return date.timeIntervalSince(lastSelectionAt) <= maximumAge ? lastSelectionRect : nil
    }

    private mutating func recordSelection(at date: Date) {
        defer { dragStartPoint = nil }
        guard let dragStartPoint, let dragEndPoint = latestPointerPoint else { return }
        let dragRect = CGRect(
            x: min(dragStartPoint.x, dragEndPoint.x),
            y: min(dragStartPoint.y, dragEndPoint.y),
            width: abs(dragEndPoint.x - dragStartPoint.x),
            height: abs(dragEndPoint.y - dragStartPoint.y)
        )
        guard dragRect.width >= Self.minimumWidth, dragRect.height >= Self.minimumHeight else {
            lastSelectionRect = nil
            lastSelectionAt = nil
            return
        }
        lastSelectionRect = dragRect
        lastSelectionAt = date
    }
}

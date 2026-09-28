//  The rectangle the reader dragged over a stream to select text.
//
//  A selection is made with the pointer, and the client already sees those positions precisely — so
//  the drag is a better answer to "which text did they mean" than guessing at highlight colours,
//  which cannot tell a text selection from a coloured banner. The rectangle is recorded in Vision's
//  normalized space (origin bottom-left), the space a text-read region is expressed in.
//
//  Only an absolute pointer carries a position; under a captured relative pointer there is no place
//  on screen this could name, so nothing is recorded and the caller falls back to its other reads.
//

import CoreGraphics
import Foundation

extension NativeNVSTAbsoluteMouseEvent {
    /// The pointer in Vision's normalized space, or nil when the event carries no usable viewport.
    ///
    /// The wire position is top-left origin within the source frame (`OPNPillarboxPointerMapping`),
    /// while Vision measures from the bottom-left, so the vertical axis is flipped here once rather
    /// than at every use.
    var visionUnitPoint: CGPoint? {
        guard viewportWidth > 0, viewportHeight > 0 else { return nil }
        let u = Double(x) / Double(viewportWidth)
        let v = Double(y) / Double(viewportHeight)
        guard u.isFinite, v.isFinite else { return nil }
        return CGPoint(x: min(max(u, 0), 1), y: min(max(1 - v, 0), 1))
    }
}

/// Tracks the last left-button drag so a copy can be read from the rectangle the reader selected.
struct StreamPointerSelectionTracker: Equatable, Sendable {
    /// A drag has to cover this share of the frame before it is a selection rather than a click.
    static let minimumWidth = 0.02
    static let minimumHeight = 0.01

    private var pointer: CGPoint?
    private var dragStart: CGPoint?
    private(set) var lastSelection: CGRect?
    private(set) var lastSelectionAt: Date?

    /// The latest absolute pointer position, normalized. Called for every accepted move.
    mutating func notePointer(_ point: CGPoint) {
        pointer = point
    }

    /// The same, straight from the wire event. An event with no viewport is ignored rather than
    /// clearing the position, so a malformed packet cannot erase where the pointer is.
    mutating func notePointer(_ event: NativeNVSTAbsoluteMouseEvent) {
        guard let point = event.visionUnitPoint else { return }
        pointer = point
    }

    /// A left-button edge. A large enough drag becomes the selection; a click drops whatever was
    /// selected before, because the reader has moved on to something else.
    mutating func noteLeftButton(isPressed: Bool, at date: Date) {
        guard isPressed else {
            defer { dragStart = nil }
            guard let start = dragStart, let end = pointer else { return }
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            guard rect.width >= Self.minimumWidth, rect.height >= Self.minimumHeight else {
                lastSelection = nil
                lastSelectionAt = nil
                return
            }
            lastSelection = rect
            lastSelectionAt = date
            return
        }
        dragStart = pointer
    }

    /// The drag rectangle, while it is still the reader's most recent act of selection. An old drag
    /// is not a selection any more: the reader has done other things since, and reading its region
    /// would answer a copy with text they stopped thinking about.
    func recentSelection(at date: Date, maximumAge: TimeInterval) -> CGRect? {
        guard let lastSelection, let lastSelectionAt else { return nil }
        return date.timeIntervalSince(lastSelectionAt) <= maximumAge ? lastSelection : nil
    }
}

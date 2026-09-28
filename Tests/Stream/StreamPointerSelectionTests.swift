import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

/// The drag the reader makes to select text, turned into the rectangle a capture is read from.
struct StreamPointerSelectionTrackerTests {
    private func event(x: Int32, y: Int32, width: Int32 = 100, height: Int32 = 100) -> NativeNVSTAbsoluteMouseEvent {
        NativeNVSTAbsoluteMouseEvent(
            x: x,
            y: y,
            viewportWidth: width,
            viewportHeight: height,
            timestamp: MediaTimestamp(nanoseconds: 0)
        )
    }

    /// The wire position is top-left origin; Vision measures from the bottom-left, so the vertical
    /// axis flips exactly once, here.
    @Test func thePointerIsConvertedIntoVisionsSpace() throws {
        let point = try #require(event(x: 50, y: 25).visionUnitPoint)
        #expect(point.x == 0.5)
        #expect(point.y == 0.75)
    }

    @Test func aPositionlessEventHasNoUnitPoint() {
        #expect(event(x: 10, y: 10, width: 0, height: 0).visionUnitPoint == nil)
    }

    @Test func aDragBecomesTheSelectionRectangle() {
        var tracker = StreamPointerSelectionTracker()
        let start = Date()
        tracker.notePointer(CGPoint(x: 0.125, y: 0.75))
        tracker.noteLeftButton(isPressed: true, at: start)
        tracker.notePointer(CGPoint(x: 0.5, y: 0.5))
        tracker.noteLeftButton(isPressed: false, at: start)
        #expect(tracker.lastSelection == CGRect(x: 0.125, y: 0.5, width: 0.375, height: 0.25))
    }

    @Test func aBackwardsDragNormalisesTheSameWay() {
        var tracker = StreamPointerSelectionTracker()
        let start = Date()
        tracker.notePointer(CGPoint(x: 0.5, y: 0.5))
        tracker.noteLeftButton(isPressed: true, at: start)
        tracker.notePointer(CGPoint(x: 0.125, y: 0.75))
        tracker.noteLeftButton(isPressed: false, at: start)
        #expect(tracker.lastSelection == CGRect(x: 0.125, y: 0.5, width: 0.375, height: 0.25))
    }

    /// A click is not a selection, and it also means the reader has moved on: whatever was selected
    /// before is no longer what a copy should read.
    @Test func aClickClearsAnEarlierSelection() {
        var tracker = StreamPointerSelectionTracker()
        let start = Date()
        tracker.notePointer(CGPoint(x: 0.1, y: 0.8))
        tracker.noteLeftButton(isPressed: true, at: start)
        tracker.notePointer(CGPoint(x: 0.5, y: 0.6))
        tracker.noteLeftButton(isPressed: false, at: start)
        tracker.notePointer(CGPoint(x: 0.2, y: 0.2))
        tracker.noteLeftButton(isPressed: true, at: start.addingTimeInterval(1))
        tracker.noteLeftButton(isPressed: false, at: start.addingTimeInterval(1))
        #expect(tracker.lastSelection == nil)
    }

    @Test func anOldSelectionIsNoLongerOffered() {
        var tracker = StreamPointerSelectionTracker()
        let start = Date()
        tracker.notePointer(CGPoint(x: 0.1, y: 0.8))
        tracker.noteLeftButton(isPressed: true, at: start)
        tracker.notePointer(CGPoint(x: 0.5, y: 0.6))
        tracker.noteLeftButton(isPressed: false, at: start)
        #expect(tracker.recentSelection(at: start.addingTimeInterval(5), maximumAge: 20) != nil)
        #expect(tracker.recentSelection(at: start.addingTimeInterval(21), maximumAge: 20) == nil)
    }
}

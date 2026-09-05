//  The gate's whole job is telling "AppKit is between events" from "AppKit is inside a nested run
//  loop of its own". A zoom animation is neither live resize nor observable through a notification
//  — it is only visible as the run loop mode it spins in, `_NSMoveTimerRunLoopMode`.
//
//  The gate also owns `releaseAspectRatioLock`, which is what actually fixes the titlebar
//  double-click crash: zeroing a window aspect ratio leaves AppKit dividing by zero when it
//  computes the zoom target, and the resulting NaN height traps.
//
//  The mode test is exercised through `isNestedRunLoopMode` rather than by spinning a real nested
//  loop: doing that inside the test harness segfaults it.
//

import AppKit
import CoreFoundation
import Foundation
import Testing
@testable import OpenNOW

@Suite("StreamWindowGeometryGate")
struct StreamWindowGeometryGateTests {
    @Test("event tracking, and the loop a zoom animation spins, read as nested")
    func trackingModeReadsAsNested() {
        #expect(StreamWindowGeometryGate.isNestedRunLoopMode(CFRunLoopMode("NSEventTrackingRunLoopMode" as CFString)))
        #expect(StreamWindowGeometryGate.isNestedRunLoopMode(CFRunLoopMode("NSModalPanelRunLoopMode" as CFString)))
        #expect(StreamWindowGeometryGate.isNestedRunLoopMode(CFRunLoopMode("_NSMoveTimerRunLoopMode" as CFString)))
    }

    @Test("the default mode, and no running loop at all, read as mutable")
    func defaultModeReadsAsMutable() {
        #expect(!StreamWindowGeometryGate.isNestedRunLoopMode(.defaultMode))
        #expect(!StreamWindowGeometryGate.isNestedRunLoopMode(nil))
    }

    @Test("releasing a lock cancels the ratio through resize increments instead of zeroing it")
    @MainActor
    func releaseAspectRatioLockCancelsTheRatio() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.aspectRatio = NSSize(width: 16, height: 9)

        StreamWindowGeometryGate.releaseAspectRatioLock(window)

        // Aspect ratio and resize increments are mutually exclusive, so the increments are what
        // cancel the ratio. A window left holding a zeroed ratio instead computes a NaN zoom
        // target and traps on the next titlebar double-click.
        #expect(window.resizeIncrements == NSSize(width: 1, height: 1))
        #expect(window.contentResizeIncrements == NSSize(width: 1, height: 1))
        #expect(window.aspectRatio == .zero)
        #expect(window.contentAspectRatio == .zero)
    }
}

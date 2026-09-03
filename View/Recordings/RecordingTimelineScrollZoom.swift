//
//  RecordingTimelineScrollZoom.swift
//  OpenNOW
//
//  Scroll-wheel zoom for the editor timeline.
//
//  A window-level event monitor rather than a view that overrides `scrollWheel`: the track already
//  owns click-to-seek, drag-to-select and the trim handles, and an `NSView` layered over it to catch
//  scrolling would have to be hit-testable to receive the event - which is exactly what would steal
//  those gestures. The monitor sees the event without being in the hit chain, and passes anything
//  outside the track straight through.
//

import AppKit
import SwiftUI

struct RecordingTimelineScrollZoom: NSViewRepresentable {
    /// Factor to multiply the current zoom by. Above 1 zooms in.
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ScrollZoomProbe {
        ScrollZoomProbe()
    }

    func updateNSView(_ nsView: ScrollZoomProbe, context: Context) {
        nsView.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: ScrollZoomProbe, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class ScrollZoomProbe: NSView {
        var onZoom: ((Double) -> Void)?
        private var monitor: Any?

        /// Never in the hit chain: it exists to measure where the track is, not to take input from
        /// it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                stopMonitoring()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let pointInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(pointInView) else { return event }
                // A trackpad reports many small precise deltas where a wheel reports few large
                // ones; scaling them apart keeps a two-finger swipe from snapping to full zoom.
                let raw = Double(event.scrollingDeltaY)
                let delta = event.hasPreciseScrollingDeltas ? raw * 0.004 : raw * 0.05
                guard abs(delta) > 0.0001 else { return nil }
                self.onZoom?(exp(delta))
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // No `deinit` teardown: the monitor is a non-Sendable `Any` and a nonisolated `deinit`
        // cannot touch it. `viewDidMoveToWindow(nil)` and `dismantleNSView` both cover removal.
    }
}

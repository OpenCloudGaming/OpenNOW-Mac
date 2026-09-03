//
//  RecordingTimelineGeometry.swift
//  OpenNOW
//
//  The seconds-to-pixels mapping for the editor timeline, as a value rather than as arithmetic
//  scattered through the view. Zoom made that necessary: eight places computed `seconds / total *
//  width` independently, and every one of them had to learn about the visible window at once.
//
//  Deliberately outside the view: a SwiftUI `View` is `@MainActor`, and this is pure geometry that
//  tests should be able to call directly.
//

import CoreGraphics
import Foundation

struct RecordingTimelineGeometry: Equatable {
    /// The whole edited timeline, in cumulative seconds.
    let totalDuration: Double
    /// The track's on-screen width.
    let width: CGFloat
    /// 1 shows the whole timeline; 4 shows a quarter of it.
    let zoom: Double
    /// Where the visible window starts, in the same cumulative seconds.
    let visibleStartSeconds: Double

    static let minimumZoom = 1.0
    static let maximumZoom = 32.0

    /// A zoomed timeline follows the playhead rather than offering a pan gesture: the track already
    /// owns click-to-seek and drag-to-select, and a third gesture on the same surface would be
    /// guesswork for the user. The moment being trimmed is where the playhead is.
    init(totalDuration: Double, width: CGFloat, zoom: Double, playheadSeconds: Double) {
        let safeDuration = max(totalDuration.isFinite ? totalDuration : 0, 0.01)
        let safeZoom = min(max(zoom.isFinite ? zoom : 1, Self.minimumZoom), Self.maximumZoom)
        self.totalDuration = safeDuration
        self.width = max(width, 1)
        self.zoom = safeZoom
        let visible = safeDuration / safeZoom
        let centred = (playheadSeconds.isFinite ? playheadSeconds : 0) - visible / 2
        visibleStartSeconds = min(max(0, centred), max(0, safeDuration - visible))
    }

    var visibleDuration: Double { totalDuration / zoom }

    var visibleEndSeconds: Double { visibleStartSeconds + visibleDuration }

    var isZoomed: Bool { zoom > Self.minimumZoom + 0.0001 }

    /// Unclamped on purpose: a clip that starts before the window has to be laid out at a negative
    /// x so the part of it that is visible lands in the right place.
    func x(forSeconds seconds: Double) -> CGFloat {
        CGFloat((seconds - visibleStartSeconds) / visibleDuration) * width
    }

    func seconds(forX x: CGFloat) -> Double {
        let ratio = Double(x / width)
        return min(max(0, visibleStartSeconds + ratio * visibleDuration), totalDuration)
    }

    /// The part of a span that is worth giving a view, clamped to the track plus one screen of
    /// overscan.
    ///
    /// `x(forSeconds:)` is unclamped by design so off-window content lands in the right place, but
    /// feeding that straight into `.frame(width:)` makes the view as wide as the zoom: at 32x a
    /// full-length clip asked for ~28,800 pt, past the ~16,384 pt a layer's backing store can take.
    /// Everything outside the track is clipped anyway, so nothing visible is lost.
    func displayFrame(x: CGFloat, width spanWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let overscan = self.width
        let lower = max(x, -overscan)
        let upper = min(x + max(0, spanWidth), self.width + overscan)
        guard upper > lower else { return (lower, 0) }
        return (lower, upper - lower)
    }

    /// Pulls a dragged handle onto a nearby landmark - the playhead, a clip edge, either end of the
    /// timeline. Without it, trimming to the frame the playhead is parked on is a pixel hunt.
    static func snapped(x: CGFloat, to candidates: [CGFloat], threshold: CGFloat) -> CGFloat {
        guard threshold > 0 else { return x }
        var best: CGFloat?
        var bestDistance = threshold
        for candidate in candidates {
            let distance = abs(candidate - x)
            if distance <= bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best ?? x
    }

    /// Roughly six to twelve labels whatever is on screen, off a scale people already read on a
    /// clock rather than an arbitrary division of the width.
    static func rulerStepSeconds(visibleDuration: Double) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return candidates.first { visibleDuration / $0 <= 8 } ?? 3600
    }

    /// The tick times inside the window, aligned to the step so labels stay on round numbers as the
    /// window slides rather than drifting with it.
    func rulerTickSeconds() -> [Double] {
        let step = Self.rulerStepSeconds(visibleDuration: visibleDuration)
        let first = (visibleStartSeconds / step).rounded(.down) * step
        var ticks: [Double] = []
        var seconds = first
        // The window holds at most eight steps by construction; the cap is a guard, not a limit.
        while seconds <= visibleEndSeconds, ticks.count < 24 {
            if seconds >= 0 { ticks.append(seconds) }
            seconds += step
        }
        return ticks
    }
}

//
//  RemoteCoOpVideoRateLimiter.swift
//  OpenNOW
//
//  Decides, per frame, whether a guest's video relay forwards it or drops it.
//
//  This replaced a pacer that held one frame and released it on its own timer at the guest preset's
//  frame rate. Two faults in that, which together cost a guest roughly 400 ms of latency:
//
//  - The timer ran on its own clock and beat against the seat's independent ~60 Hz cadence. With a
//    single-frame slot, an early frame was dropped and a late one left the slot empty; and because
//    the next deadline was set *after* the I420 conversion ran, the release rate sat just below the
//    source rate, so the slot was almost always full and frames were dropped in steady state.
//  - Outgoing capture timestamps were synthesised from the release time instead of carried from the
//    source. libwebrtc's receiver infers network jitter from how capture timestamps relate to
//    arrival times, so re-stamping a smooth source with a jittery clock reads as a jittery network
//    and the receiver grows its jitter buffer to absorb it - measured at 407 ms on a 4 ms LAN route
//    with `playoutDelayHint` already zero.
//
//  So: never delay a frame. Forward it now or drop it now, and carry the source's timestamp
//  through. Rate limiting stays only to avoid paying for an I420 conversion on a frame libwebrtc's
//  own adapter would discard anyway.
//

import Foundation

public struct OPNRemoteCoOpVideoRateLimiter: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Hand the frame over now, stamped with this capture time.
        case forward(timeStampNs: Int64)
        case drop
    }

    /// Headroom on the minimum gap, so ordinary source jitter does not cause a drop.
    ///
    /// Without it a source running at exactly the preset rate loses every marginally-early frame,
    /// which halves the delivered rate: the gap between two frames of a 60 fps source is sometimes
    /// 16.5 ms and sometimes 16.8 ms, and a hard 16.67 ms floor rejects the first of each pair.
    static let intervalTolerance = 0.85

    public let targetFps: Int
    public private(set) var lastForwardedTimestampNs: Int64 = 0
    public private(set) var forwardedCount: UInt64 = 0
    public private(set) var droppedCount: UInt64 = 0

    public init(targetFps: Int) {
        self.targetFps = max(1, targetFps)
    }

    public var minimumFrameIntervalNs: Int64 {
        Int64(Double(1_000_000_000 / targetFps) * Self.intervalTolerance)
    }

    /// `arrivalNs` is only a fallback clock: it is used when the source hands over a timestamp that
    /// is not strictly increasing, which libwebrtc rejects outright.
    public mutating func decide(sourceTimestampNs: Int64, arrivalNs: Int64) -> Decision {
        var timestampNs = sourceTimestampNs
        if timestampNs <= lastForwardedTimestampNs {
            timestampNs = max(arrivalNs, lastForwardedTimestampNs + 1)
        }
        if lastForwardedTimestampNs != 0, timestampNs - lastForwardedTimestampNs < minimumFrameIntervalNs {
            droppedCount &+= 1
            return .drop
        }
        lastForwardedTimestampNs = timestampNs
        forwardedCount &+= 1
        return .forward(timeStampNs: timestampNs)
    }
}

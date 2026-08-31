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
//  The decimation rule went through one more revision after that. The first version gated on time
//  since the last *forwarded* frame - a hard floor - which measured ~40 fps delivered against a
//  60 fps target and 60 fps of source arriving, confirmed independent of the guest's resolution
//  preset (720p and 1080p produced the identical ceiling, which rules out the encoder). The seat's
//  decode does not arrive in perfectly even 16.7 ms steps; when two frames land close together, the
//  second fails the floor and is dropped, and the timing credit from the gap before them is simply
//  discarded rather than banked - so a source whose *average* rate matches the target still gets
//  under-admitted by however bursty its arrival is. A leaky-bucket accumulator fixes this: credit
//  builds continuously from real elapsed source time and is spent, not reset, on every forward, so
//  a burst is admitted using credit banked during the preceding gap instead of being penalised for it.
//

import Foundation

public struct OPNRemoteCoOpVideoRateLimiter: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Hand the frame over now, stamped with this capture time.
        case forward(timeStampNs: Int64)
        case drop
    }

    public let targetFps: Int
    public private(set) var lastSourceTimestampNs: Int64 = 0
    public private(set) var forwardedCount: UInt64 = 0
    public private(set) var droppedCount: UInt64 = 0
    /// Time in hand toward the next forwarded frame, in nanoseconds. Never goes negative and never
    /// exceeds one interval: a source that outruns the target cannot bank enough during a pause to
    /// let two frames straight through later, which would show up as a stutter rather than a
    /// smooth rate reduction.
    private var bankedNs: Int64 = 0

    public init(targetFps: Int) {
        self.targetFps = max(1, targetFps)
    }

    public var targetFrameIntervalNs: Int64 {
        Int64(1_000_000_000 / targetFps)
    }

    /// `arrivalNs` is only a fallback clock: it is used when the source hands over a timestamp that
    /// is not strictly increasing, which libwebrtc rejects outright.
    public mutating func decide(sourceTimestampNs: Int64, arrivalNs: Int64) -> Decision {
        var timestampNs = sourceTimestampNs
        let isFirstFrame = lastSourceTimestampNs == 0
        if !isFirstFrame, timestampNs <= lastSourceTimestampNs {
            timestampNs = max(arrivalNs, lastSourceTimestampNs + 1)
        }
        let interval = targetFrameIntervalNs
        // The gap since the frame this function last *saw*, forwarded or not - crediting every
        // frame's arrival is what lets a burst spend timing credit a dropped predecessor banked.
        // The first frame has no predecessor to gap from; it starts fully banked so the stream
        // begins with a frame rather than waiting out a whole interval first.
        //
        // Each gap is capped at one interval's worth of credit before it is banked - not the
        // running total afterward. Capping the total instead (tried first) has a degenerate fixed
        // point: after any gap of two intervals or more forwards a frame and leaves exactly one
        // interval banked, and a source that then resumes at *precisely* the target rate keeps
        // adding one interval and paying back exactly one interval forever, so the leftover never
        // drains below the forwarding threshold and every subsequent frame forwards for free. That
        // reproduces the very symptom this exists to fix, just relocated to any decode gap rather
        // than only a genuine pause. Capping what a single gap can contribute keeps a real pause
        // from releasing a burst on resumption while still letting genuine burstiness - two frames
        // close together compensated by the gap between pairs - spend the credit their own gap
        // earned.
        if isFirstFrame {
            bankedNs = interval
        } else {
            bankedNs += min(interval, timestampNs - lastSourceTimestampNs)
        }
        lastSourceTimestampNs = timestampNs
        guard bankedNs >= interval else {
            droppedCount &+= 1
            return .drop
        }
        bankedNs -= interval
        forwardedCount &+= 1
        return .forward(timeStampNs: timestampNs)
    }
}

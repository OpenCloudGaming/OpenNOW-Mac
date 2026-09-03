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
    /// The clock the accumulator actually runs on: the source's own timestamps while they advance,
    /// and the arrival clock while they do not. Kept strictly increasing, because that is what
    /// libwebrtc requires of a capture time.
    private var lastEmittedTimestampNs: Int64 = 0
    /// Added to the arrival clock while the source's is unusable.
    ///
    /// The two have unrelated bases - the source carries the seat's RTP clock, the arrival clock is
    /// this machine's uptime - so a source that wraps its 32-bit RTP timestamp restarts near zero
    /// while the emitted clock is still hours ahead of any arrival reading. Taken once, at the
    /// switch, so arrival deltas keep their real spacing afterwards.
    private var arrivalClockBiasNs: Int64 = 0
    /// Time in hand toward the next forwarded frame, in nanoseconds. Never goes negative, and never
    /// carries more than one interval past a forwarded frame: a source that pauses cannot bank
    /// enough to let a burst straight through later, which would show up as a stutter rather than a
    /// smooth rate reduction.
    private var bankedNs: Int64 = 0

    public init(targetFps: Int) {
        self.targetFps = max(1, targetFps)
    }

    public var targetFrameIntervalNs: Int64 {
        Int64(1_000_000_000 / targetFps)
    }

    /// The most credit a forwarded frame may leave behind, seven tenths of an interval.
    var carryCeilingNs: Int64 {
        (targetFrameIntervalNs * 7) / 10
    }

    /// `arrivalNs` is only a fallback clock: it is used when the source hands over a timestamp that
    /// is not strictly increasing, which libwebrtc rejects outright.
    public mutating func decide(sourceTimestampNs: Int64, arrivalNs: Int64) -> Decision {
        let isFirstFrame = lastSourceTimestampNs == 0
        lastSourceTimestampNs = sourceTimestampNs
        let timestampNs: Int64
        if sourceTimestampNs > lastEmittedTimestampNs {
            timestampNs = sourceTimestampNs
            arrivalClockBiasNs = 0
        } else {
            // The source clock did not advance - a repeat, a decoder restart, or an RTP wrap. Rebasing
            // onto `lastEmittedTimestampNs + 1` worked only while the arrival clock happened to be
            // ahead of it; when it was behind, every later frame advanced the accumulator by a single
            // nanosecond and none of them ever reached an interval again, so the guest's video froze
            // for the rest of the session with no way back.
            if arrivalNs &+ arrivalClockBiasNs <= lastEmittedTimestampNs {
                arrivalClockBiasNs = lastEmittedTimestampNs &+ 1 &- arrivalNs
            }
            timestampNs = arrivalNs &+ arrivalClockBiasNs
        }
        let interval = targetFrameIntervalNs
        // The gap since the frame this function last *saw*, forwarded or not - crediting every
        // frame's arrival is what lets a burst spend timing credit a dropped predecessor banked.
        // The first frame has no predecessor to gap from; it starts fully banked so the stream
        // begins with a frame rather than waiting out a whole interval first.
        //
        // Each gap credits its full elapsed time, and only the leftover *after* a frame is paid for
        // is capped. Capping the gap itself instead threw away exactly the credit this accumulator
        // exists to bank: with a 60 fps source arriving in alternating 10 ms / 23.3 ms steps against
        // a 60 fps target, each pair earned min(I, 10) + min(I, 23.3) = 26.7 ms toward a 33.3 ms
        // cost, so a source whose average rate matched the target was permanently under-admitted -
        // 48 fps delivered from 60, and worse the burstier the decode.
        //
        // `carryCeilingNs` is the whole of the tuning, and it is bracketed from both sides. It has to
        // exceed one interval minus the earliest a frame realistically arrives - a third of an
        // interval ahead, in the paired-burst pattern this was measured against - or that frame is
        // dropped and the credit its early arrival represents is thrown away. It has to stay below
        // one interval minus the margin that still counts as a burst, or a resumed pause hands the
        // frame after next a free pass however soon it lands.
        if isFirstFrame {
            bankedNs = interval
        } else {
            bankedNs += timestampNs - lastEmittedTimestampNs
        }
        lastEmittedTimestampNs = timestampNs
        guard bankedNs >= interval else {
            droppedCount &+= 1
            return .drop
        }
        bankedNs = min(bankedNs - interval, carryCeilingNs)
        forwardedCount &+= 1
        return .forward(timeStampNs: timestampNs)
    }
}

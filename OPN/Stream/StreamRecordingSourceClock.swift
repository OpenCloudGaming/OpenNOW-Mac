//  The recording's own presentation timeline, driven by the presentation time the decoder supplies.
//

import CoreMedia
import Foundation

/// Maps the decoder's presentation clock onto the recording's timeline.
///
/// Stamping a frame with the moment its decode callback ran bakes that callback's jitter into the
/// file: a loss-free 120 fps recording measured only 54.6 % nominal presentation gaps, with 28.5 %
/// of them short (NEC-135). The decoder already carries the seat's capture instant, so the file
/// keeps that spacing and this type's only other job is keeping the timeline strictly increasing —
/// `AVAssetWriterInputPixelBufferAdaptor.append` refuses a time that does not advance, and that
/// refusal used to cost the whole recording.
struct StreamRecorderSourceClock {
    /// The recording's timescale. 600 divides the 90 kHz RTP clock into whole ticks at every frame
    /// rate the seat negotiates, so a 120 fps frame is exactly 5 ticks and a 30 fps frame exactly 20.
    static let timescale: CMTimeScale = 600

    /// The whole span of a 32-bit RTP timestamp in recording ticks: it wraps roughly every 13 hours
    /// at 90 kHz, which a long recording outlives.
    static let rtpTimestampSpanTicks = (CMTimeValue(UInt32.max) + 1) * CMTimeValue(timescale) / CMTimeValue(NvstVideoToolboxDecoder.clockRate)

    /// A backward step at least half the RTP span wide is that wrap; a narrower one is a frame that
    /// did not advance and has to be dropped.
    static let wrapThresholdTicks = rtpTimestampSpanTicks / 2

    /// A forward step past this is the seat restarting its clock rather than stalling: the timeline
    /// carries on from the previous frame instead of freezing the file for the width of the gap.
    static let clockRestartThresholdTicks = CMTimeValue(timescale) * 10

    /// Skipped frames this many in a row mean the clock restarted inside the wrap threshold, and
    /// skipping the rest of the recording would be worse than the restart itself.
    static let maximumConsecutiveSkippedFrames = 30

    /// What the clock did with a frame, so the writer's counters can report wraps and restarts and
    /// a skipped frame never reaches the encoder.
    enum Resolution {
        case recordingTime(CMTime)
        case wrapped(CMTime)
        case restarted(CMTime)
        case skipped
    }

    private let nominalFrameIntervalTicks: CMTimeValue
    private var originTicks: CMTimeValue?
    private var lastSourceTicks: CMTimeValue?
    private var wrapOffsetTicks: CMTimeValue = 0
    private var lastRecordingTime = CMTime.zero
    private var consecutiveSkippedFrames = 0

    init(frameRate: Int = 60) {
        nominalFrameIntervalTicks = max(1, CMTimeValue(Self.timescale) / CMTimeValue(max(1, frameRate)))
    }

    mutating func recordingTime(forSourceTime sourceTime: CMTime) -> Resolution {
        guard sourceTime.isNumeric else { return .skipped }
        let sourceTicks = CMTimeConvertScale(sourceTime, timescale: Self.timescale, method: .roundHalfAwayFromZero).value
        guard let lastSourceTicks else { return .recordingTime(accept(sourceTicks: sourceTicks)) }
        let extendedTicks = sourceTicks + wrapOffsetTicks
        let stepTicks = extendedTicks - lastSourceTicks
        guard stepTicks != 0 else { return skip(sourceTicks: sourceTicks) }
        guard stepTicks > 0 else {
            guard -stepTicks < Self.wrapThresholdTicks else {
                wrapOffsetTicks += Self.rtpTimestampSpanTicks
                return .wrapped(accept(sourceTicks: sourceTicks + wrapOffsetTicks))
            }
            return skip(sourceTicks: sourceTicks)
        }
        guard stepTicks < Self.clockRestartThresholdTicks else { return restart(sourceTicks: sourceTicks) }
        return .recordingTime(accept(sourceTicks: extendedTicks))
    }

    private mutating func accept(sourceTicks: CMTimeValue) -> CMTime {
        consecutiveSkippedFrames = 0
        let originTicks = originTicks ?? sourceTicks
        self.originTicks = originTicks
        lastSourceTicks = sourceTicks
        lastRecordingTime = CMTime(value: sourceTicks - originTicks, timescale: Self.timescale)
        return lastRecordingTime
    }

    /// The seat's clock moved somewhere the timeline cannot follow: carry on one nominal frame
    /// interval after the previous frame, anchored on the new epoch, so the file stays continuous.
    private mutating func restart(sourceTicks: CMTimeValue) -> Resolution {
        consecutiveSkippedFrames = 0
        wrapOffsetTicks = 0
        let recordingTicks = lastRecordingTime.value + nominalFrameIntervalTicks
        originTicks = sourceTicks - recordingTicks
        lastSourceTicks = sourceTicks
        lastRecordingTime = CMTime(value: recordingTicks, timescale: Self.timescale)
        return .restarted(lastRecordingTime)
    }

    private mutating func skip(sourceTicks: CMTimeValue) -> Resolution {
        consecutiveSkippedFrames += 1
        guard consecutiveSkippedFrames >= Self.maximumConsecutiveSkippedFrames else { return .skipped }
        return restart(sourceTicks: sourceTicks)
    }
}

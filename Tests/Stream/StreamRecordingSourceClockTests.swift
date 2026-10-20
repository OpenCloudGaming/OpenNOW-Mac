import CoreMedia
import Foundation
import Testing
@testable import OpenNOW

@Suite("Stream recording source clock")
struct StreamRecordingSourceClockTests {
    private let frameRate = 120
    private var ticksPerFrame: UInt32 { UInt32(NvstVideoToolboxDecoder.clockRate) / UInt32(frameRate) }

    private func sourceTime(rtpTimestamp: UInt32) -> CMTime {
        CMTime(value: CMTimeValue(rtpTimestamp), timescale: NvstVideoToolboxDecoder.clockRate)
    }

    /// The recording tick a frame landed on, or nil when the clock dropped it.
    private func recordingTicks(_ resolution: StreamRecorderSourceClock.Resolution) -> CMTimeValue? {
        switch resolution {
        case .recordingTime(let time), .wrapped(let time), .restarted(let time):
            return time.value
        case .skipped:
            return nil
        }
    }

    @Test("it lays uniform source times out at the configured frame interval")
    func laysUniformSourceTimesOutAtTheConfiguredFrameInterval() {
        var clock = StreamRecorderSourceClock(frameRate: frameRate)
        for frameIndex in 0..<10 {
            let resolution = clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame * UInt32(frameIndex)))
            #expect(recordingTicks(resolution) == CMTimeValue(frameIndex) * CMTimeValue(StreamRecorderSourceClock.timescale) / CMTimeValue(frameRate))
        }
    }

    @Test("it drops a frame whose source time does not advance")
    func dropsAFrameWhoseSourceTimeDoesNotAdvance() {
        var clock = StreamRecorderSourceClock(frameRate: frameRate)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == 0)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame))) == 5)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame))) == nil)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == nil)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame * 2))) == 10)
    }

    @Test("it drops a frame whose source time is not usable")
    func dropsAFrameWhoseSourceTimeIsNotUsable() {
        var clock = StreamRecorderSourceClock(frameRate: frameRate)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: .invalid)) == nil)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: .indefinite)) == nil)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == 0)
    }

    @Test("it carries the timeline across a 32-bit RTP timestamp wrap")
    func carriesTheTimelineAcrossAnRtpTimestampWrap() {
        var clock = StreamRecorderSourceClock(frameRate: frameRate)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: UInt32.max - ticksPerFrame))) == 0)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: UInt32.max))) == 5)
        let wrapped = clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame - 1))
        guard case .wrapped = wrapped else {
            Issue.record("Expected a wrap, got \(wrapped)")
            return
        }
        #expect(recordingTicks(wrapped) == 10)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame * 2 - 1))) == 15)
    }

    @Test("it continues the timeline when the source clock jumps forward past a stall")
    func continuesTheTimelineWhenTheSourceClockJumpsForwardPastAStall() {
        var clock = StreamRecorderSourceClock(frameRate: frameRate)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == 0)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame))) == 5)
        let afterTheGap = UInt32(NvstVideoToolboxDecoder.clockRate) * 30
        let restarted = clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: afterTheGap))
        guard case .restarted = restarted else {
            Issue.record("Expected a restart, got \(restarted)")
            return
        }
        #expect(recordingTicks(restarted) == 10)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: afterTheGap + ticksPerFrame))) == 15)
    }

    /// A restart to a nearby value leaves every following frame behind the last accepted one, and
    /// dropping the rest of the recording would be worse than the discontinuity itself.
    @Test("it restarts the timeline when the source clock stays behind the last accepted frame")
    func restartsTheTimelineWhenTheSourceClockStaysBehindTheLastAcceptedFrame() {
        var clock = StreamRecorderSourceClock(frameRate: frameRate)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == 0)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame))) == 5)
        for _ in 0..<(StreamRecorderSourceClock.maximumConsecutiveSkippedFrames - 1) {
            #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == nil)
        }
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: 0))) == 10)
        #expect(recordingTicks(clock.recordingTime(forSourceTime: sourceTime(rtpTimestamp: ticksPerFrame))) == 15)
    }
}

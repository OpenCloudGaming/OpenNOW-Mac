//  What the recording file's presentation timeline is made of: the decoder's own presentation
//  times rather than the moment each frame's decode callback ran.
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import OpenNOW

/// Serialized because the file tests drive a real `AVAssetWriter`, and concurrent encoders on a
/// loaded runner change which frames a recording keeps.
@Suite("Stream recording timeline", .serialized)
struct StreamRecordingTimelineTests {
    /// The cadence in the file has to be the seat's, not the decode callback's: these frames arrive
    /// unevenly but carry uniform source presentation times, so the gaps come out nominal.
    @Test("a recording keeps the source cadence when frames arrive unevenly")
    func recordingKeepsSourceCadenceWhenFramesArriveUnevenly() async throws {
        let frameRate = 120
        let recording = RecordingTestFixtures.startNativeRecording(title: "Source Cadence Regression", frameRate: frameRate)
        guard let warmUp = try await RecordingTestFixtures.warmUpNativeRecording(recording, frameRate: frameRate) else {
            Issue.record("Expected the recording to start")
            return
        }

        var frameIndex = warmUp.nextFrameIndex
        for _ in 0..<40 {
            try RecordingTestFixtures.appendNativeFrame(
                to: recording.recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            frameIndex += 1
            // Deliberately uneven arrival against a nominal 8.3 ms frame interval.
            try await Task.sleep(for: .milliseconds(frameIndex.isMultiple(of: 2) ? 4 : 20))
        }

        guard let finished = try await RecordingTestFixtures.finishRecording(recording) else {
            Issue.record("Expected a finished recording, got \(String(describing: await recording.statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(finished.file) }

        let presentationTimes = try await RecordingTestFixtures.presentationTimes(url: finished.file.videoURL, mediaType: .video)
        let frameIntervals = RecordingTestFixtures.frameIntervals(presentationTimes, frameRate: frameRate)
        #expect(frameIntervals.count >= 20)
        #expect(frameIntervals.allSatisfy(RecordingTestFixtures.isWholeFrameInterval),
                "every gap must be a whole number of source frame intervals, got \(frameIntervals)")
        let nominalIntervalCount = frameIntervals.filter { abs($0 - 1) < 0.05 }.count
        #expect(nominalIntervalCount >= Int(Double(frameIntervals.count) * 0.9),
                "expected mostly nominal gaps, got \(nominalIntervalCount) of \(frameIntervals.count)")
        #expect(finished.diagnostics.selectedVideoSource == .native)
        #expect(finished.diagnostics.nativeVideo.appendedFrames == presentationTimes.count)
        #expect(finished.diagnostics.nativeVideo.offeredFrames
                == finished.diagnostics.nativeVideo.appendedFrames + finished.diagnostics.nativeVideo.rejectedFrames)
    }

    /// The inverse: the feed is metronomic and the source presentation times are not, so the file
    /// has to carry the source's uneven spacing rather than the feed's uniform one.
    @Test("a recording keeps uneven source spacing that arrives uniformly")
    func recordingKeepsUnevenSourceSpacingThatArrivesUniformly() async throws {
        let frameRate = 120
        let ticksPerFrame = UInt32(NvstVideoToolboxDecoder.clockRate) / UInt32(frameRate)
        let recording = RecordingTestFixtures.startNativeRecording(title: "Uneven Source Spacing Regression", frameRate: frameRate)
        guard let warmUp = try await RecordingTestFixtures.warmUpNativeRecording(recording, frameRate: frameRate) else {
            Issue.record("Expected the recording to start")
            return
        }

        var frameIndex = warmUp.nextFrameIndex
        var rtpTimestamp = warmUp.lastRtpTimestamp
        for index in 0..<40 {
            rtpTimestamp += index.isMultiple(of: 2) ? ticksPerFrame : ticksPerFrame * 2
            try RecordingTestFixtures.appendNativeFrame(to: recording.recorder, frameIndex: frameIndex, rtpTimestamp: rtpTimestamp)
            frameIndex += 1
            // Uniform arrival: arrival-time stamping would make every gap one frame interval.
            try await Task.sleep(for: .milliseconds(8))
        }

        guard let finished = try await RecordingTestFixtures.finishRecording(recording) else {
            Issue.record("Expected a finished recording, got \(String(describing: await recording.statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(finished.file) }

        let presentationTimes = try await RecordingTestFixtures.presentationTimes(url: finished.file.videoURL, mediaType: .video)
        let frameIntervals = RecordingTestFixtures.frameIntervals(presentationTimes, frameRate: frameRate)
        #expect(frameIntervals.count >= 20)
        #expect(frameIntervals.allSatisfy(RecordingTestFixtures.isWholeFrameInterval),
                "every gap must be a whole number of source frame intervals, got \(frameIntervals)")
        let singleIntervalCount = frameIntervals.filter { abs($0 - 1) < 0.05 }.count
        let doubleIntervalCount = frameIntervals.filter { abs($0 - 2) < 0.05 }.count
        #expect(singleIntervalCount >= frameIntervals.count / 4, "the source's single intervals are missing")
        #expect(doubleIntervalCount >= frameIntervals.count / 4, "the source's double intervals are missing")
    }

    /// A seat's clock does not only run forward. A duplicate, a backward step and a 32-bit wrap each
    /// cost at most the frame they belong to; none of them may cost the recording.
    @Test("a recording survives non-monotonic and wrapping source presentation times")
    func recordingSurvivesNonMonotonicWrappingSourcePresentationTimes() async throws {
        let frameRate = 120
        let ticksPerFrame = UInt32(NvstVideoToolboxDecoder.clockRate) / UInt32(frameRate)
        // Close enough to the 32-bit ceiling that this feed wraps it part way through.
        let firstRtpTimestamp = UInt32.max - (ticksPerFrame * 10)
        let recording = RecordingTestFixtures.startNativeRecording(title: "Source Clock Wrap Regression", frameRate: frameRate)
        guard let warmUp = try await RecordingTestFixtures.warmUpNativeRecording(recording,
                                                                                frameRate: frameRate,
                                                                                firstRtpTimestamp: firstRtpTimestamp) else {
            Issue.record("Expected the recording to start")
            return
        }

        var frameIndex = warmUp.nextFrameIndex
        var rtpTimestamp = warmUp.lastRtpTimestamp
        for index in 0..<40 {
            switch index {
            // A duplicate: the same timestamp the previous frame carried.
            case 5, 15: break
            case 9, 19: rtpTimestamp = rtpTimestamp &- (ticksPerFrame * 4)
            default: rtpTimestamp = rtpTimestamp &+ ticksPerFrame
            }
            try RecordingTestFixtures.appendNativeFrame(to: recording.recorder, frameIndex: frameIndex, rtpTimestamp: rtpTimestamp)
            frameIndex += 1
            try await Task.sleep(for: .milliseconds(12))
        }

        guard let finished = try await RecordingTestFixtures.finishRecording(recording) else {
            Issue.record("Expected a finished recording, got \(String(describing: await recording.statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(finished.file) }

        #expect(await recording.statuses.isFailed() == false)
        #expect(finished.diagnostics.sourceClockWraps >= 1)
        #expect(finished.diagnostics.nativeVideo.nonMonotonicPresentationTimeSkips >= 1)
        #expect(finished.diagnostics.nativeVideo.appendedFrames >= 20)
        #expect(finished.diagnostics.nativeVideo.offeredFrames
                == finished.diagnostics.nativeVideo.appendedFrames + finished.diagnostics.nativeVideo.rejectedFrames)
        let presentationTimes = try await RecordingTestFixtures.presentationTimes(url: finished.file.videoURL, mediaType: .video)
        let frameIntervals = RecordingTestFixtures.frameIntervals(presentationTimes, frameRate: frameRate)
        #expect(frameIntervals.allSatisfy(RecordingTestFixtures.isWholeFrameInterval),
                "the wrap must not put a backwards or fractional gap in the file, got \(frameIntervals)")
    }

    /// Audio has to land on the video track's timeline rather than on the wall clock. This source
    /// clock runs under half the arrival rate, so arrival-time stamping would end audio twice late.
    @Test("audio stays on the video timeline when the source clock runs slower than arrival")
    func audioStaysOnTheVideoTimelineWhenTheSourceClockRunsSlowerThanArrival() async throws {
        let frameRate = 120
        let recording = RecordingTestFixtures.startNativeRecording(title: "Audio Clock Regression", frameRate: frameRate)
        guard let warmUp = try await RecordingTestFixtures.warmUpNativeRecording(recording, frameRate: frameRate) else {
            Issue.record("Expected the recording to start")
            return
        }

        var frameIndex = warmUp.nextFrameIndex
        let feedStartedAt = ContinuousClock.now
        for _ in 0..<40 {
            try RecordingTestFixtures.appendNativeFrame(
                to: recording.recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            recording.recorder.appendGameAudioSamples(RecordingTestFixtures.makeSineSamples(frameCount: 480, frameIndex: frameIndex), sampleRate: 48_000, channels: 2)
            frameIndex += 1
            // 20 ms of wall clock per frame against a nominal 8.3 ms source frame interval.
            try await Task.sleep(for: .milliseconds(20))
        }
        let feedDuration = ContinuousClock.now - feedStartedAt
        let feedSeconds = Double(feedDuration.components.seconds) + Double(feedDuration.components.attoseconds) / 1e18

        guard let finished = try await RecordingTestFixtures.finishRecording(recording) else {
            Issue.record("Expected a finished recording, got \(String(describing: await recording.statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(finished.file) }

        let videoSeconds = try await RecordingTestFixtures.trackEndSeconds(url: finished.file.videoURL, mediaType: .video)
        let audioSeconds = try await RecordingTestFixtures.trackEndSeconds(url: finished.file.videoURL, mediaType: .audio)
        #expect(videoSeconds > 0.2)
        #expect(finished.diagnostics.audio.appendedBuffers > 0)
        #expect(abs(audioSeconds - videoSeconds) < 0.15, "audio ended at \(audioSeconds)s against video at \(videoSeconds)s")
        #expect(audioSeconds < feedSeconds * 0.75, "audio followed the wall clock (\(feedSeconds)s) instead of the video timeline")
        #expect(finished.diagnostics.videoClockRatio < 0.75)
        let audioSamples = try await RecordingTestFixtures.trackSamples(url: finished.file.videoURL, mediaType: .audio)
        #expect(RecordingTestFixtures.overlappingSampleCount(audioSamples) == 0, "audio buffers must not overlap in the file")
    }

    /// A buffer arriving sooner than its own duration cannot be stamped inside the previous one:
    /// the sample-count cursor is the floor, whatever the arrival clock says.
    @Test("audio buffers stay contiguous when they arrive faster than they play")
    func audioBuffersStayContiguousWhenTheyArriveFasterThanTheyPlay() {
        let bufferTicks = CMTimeValue(Double(480) / 48_000 * Double(StreamRecorderSourceClock.timescale))
        let recorder = StreamRecorder()
        recorder.capturedVideoFrame = true
        recorder.lastPresentationTime = .zero
        recorder.lastVideoArrivalHostTime = 100

        let first = recorder.audioPresentationTime(arrivalHostTime: 100.010, frameCount: 480, sampleRate: 48_000)
        let second = recorder.audioPresentationTime(arrivalHostTime: 100.012, frameCount: 480, sampleRate: 48_000)
        let third = recorder.audioPresentationTime(arrivalHostTime: 100.500, frameCount: 480, sampleRate: 48_000)

        #expect(first?.value == bufferTicks, "the first buffer lands where the video timeline puts it")
        #expect(second?.value == (first?.value ?? 0) + bufferTicks,
                "a buffer arriving 2 ms later still starts where the previous one ends")
        #expect(third?.value ?? 0 > (second?.value ?? 0) + bufferTicks,
                "a real gap in delivery stays a gap in the file")
    }
}

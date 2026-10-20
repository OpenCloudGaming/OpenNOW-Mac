//  What the recording file's presentation timeline is made of: the decoder's own presentation
//  times rather than the moment each frame's decode callback ran.
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import OpenNOW

/// Serialized for the same reason as `StreamRecordingTests`: every test here drives a real
/// `AVAssetWriter`, and concurrent encoders on a loaded runner report not-ready long enough to
/// change which frames a recording keeps.
@Suite("Stream recording timeline", .serialized)
struct StreamRecordingTimelineTests {
    /// The cadence in the file has to be the seat's, not the decode callback's: these frames arrive
    /// unevenly but carry uniform source presentation times, so the gaps come out nominal. The same
    /// feed stamped on arrival time measured 3-4 tick gaps and one 68 tick gap (NEC-135).
    @Test("a recording keeps the source cadence when frames arrive unevenly")
    func recordingKeepsSourceCadenceWhenFramesArriveUnevenly() async throws {
        let frameRate = 120
        let recorder = StreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: RecordingTestFixtures.nativeConfiguration(title: "Source Cadence Regression", frameRate: frameRate))

        var frameIndex = 0
        var hasStartedRecording = false
        // The encoder reports not-ready while it spins up, and those frames are lost whatever they
        // are stamped with, so the measured feed starts once one has been accepted.
        let warmUpDeadline = ContinuousClock.now + .seconds(15)
        while !hasStartedRecording, ContinuousClock.now < warmUpDeadline {
            if await statuses.terminalStatus() != nil { break }
            try RecordingTestFixtures.appendNativeFrame(
                to: recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            frameIndex += 1
            hasStartedRecording = await statuses.hasStartedRecording()
            try await Task.sleep(for: .milliseconds(12))
        }
        guard hasStartedRecording else {
            Issue.record("Expected the recording to start")
            return
        }

        for _ in 0..<40 {
            try RecordingTestFixtures.appendNativeFrame(
                to: recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            frameIndex += 1
            // Deliberately uneven arrival against a nominal 8.3 ms frame interval.
            try await Task.sleep(for: .milliseconds(frameIndex.isMultiple(of: 2) ? 4 : 20))
        }

        // The writer's queue drains before the counters are read: finishing clears them, and the
        // native gate allows only one frame in flight, so this is the whole accounting.
        try await Task.sleep(for: .milliseconds(300))
        let diagnostics = recorder.diagnosticsSnapshot()
        recorder.stop()
        guard case .finished(let recording) = try await RecordingTestFixtures.waitForTerminalStatus(statuses) else {
            Issue.record("Expected a finished recording, got \(String(describing: await statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(recording) }

        let presentationTimes = try await RecordingTestFixtures.presentationTimes(url: recording.videoURL, mediaType: .video)
        let frameIntervals = RecordingTestFixtures.frameIntervals(presentationTimes, frameRate: frameRate)
        #expect(frameIntervals.count >= 20)
        #expect(frameIntervals.allSatisfy { abs($0 - $0.rounded()) < 0.05 && $0.rounded() >= 1 },
                "every gap must be a whole number of source frame intervals, got \(frameIntervals)")
        let nominalIntervalCount = frameIntervals.filter { abs($0 - 1) < 0.05 }.count
        #expect(nominalIntervalCount >= Int(Double(frameIntervals.count) * 0.9),
                "expected mostly nominal gaps, got \(nominalIntervalCount) of \(frameIntervals.count)")
        #expect(diagnostics.selectedVideoSource == .native)
        #expect(diagnostics.nativeVideo.appendedFrames == presentationTimes.count)
        #expect(diagnostics.nativeVideo.offeredFrames == diagnostics.nativeVideo.appendedFrames + diagnostics.nativeVideo.rejectedFrames)
    }

    /// The inverse: the feed is metronomic and the source presentation times are not, so the file
    /// has to carry the source's uneven spacing rather than the feed's uniform one.
    @Test("a recording keeps uneven source spacing that arrives uniformly")
    func recordingKeepsUnevenSourceSpacingThatArrivesUniformly() async throws {
        let frameRate = 120
        let ticksPerFrame = UInt32(NvstVideoToolboxDecoder.clockRate) / UInt32(frameRate)
        let recorder = StreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: RecordingTestFixtures.nativeConfiguration(title: "Uneven Source Spacing Regression", frameRate: frameRate))

        var frameIndex = 0
        var rtpTimestamp: UInt32 = 0
        var hasStartedRecording = false
        let warmUpDeadline = ContinuousClock.now + .seconds(15)
        while !hasStartedRecording, ContinuousClock.now < warmUpDeadline {
            if await statuses.terminalStatus() != nil { break }
            try RecordingTestFixtures.appendNativeFrame(to: recorder, frameIndex: frameIndex, rtpTimestamp: rtpTimestamp)
            frameIndex += 1
            rtpTimestamp += ticksPerFrame
            hasStartedRecording = await statuses.hasStartedRecording()
            try await Task.sleep(for: .milliseconds(12))
        }
        guard hasStartedRecording else {
            Issue.record("Expected the recording to start")
            return
        }

        for index in 0..<40 {
            rtpTimestamp += index.isMultiple(of: 2) ? ticksPerFrame : ticksPerFrame * 2
            try RecordingTestFixtures.appendNativeFrame(to: recorder, frameIndex: frameIndex, rtpTimestamp: rtpTimestamp)
            frameIndex += 1
            // Uniform arrival: arrival-time stamping would make every gap one frame interval.
            try await Task.sleep(for: .milliseconds(8))
        }

        try await Task.sleep(for: .milliseconds(300))
        let diagnostics = recorder.diagnosticsSnapshot()
        recorder.stop()
        guard case .finished(let recording) = try await RecordingTestFixtures.waitForTerminalStatus(statuses) else {
            Issue.record("Expected a finished recording, got \(String(describing: await statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(recording) }

        let presentationTimes = try await RecordingTestFixtures.presentationTimes(url: recording.videoURL, mediaType: .video)
        let frameIntervals = RecordingTestFixtures.frameIntervals(presentationTimes, frameRate: frameRate)
        #expect(frameIntervals.count >= 20)
        #expect(frameIntervals.allSatisfy { abs($0 - $0.rounded()) < 0.05 && $0.rounded() >= 1 },
                "every gap must be a whole number of source frame intervals, got \(frameIntervals)")
        let singleIntervalCount = frameIntervals.filter { abs($0 - 1) < 0.05 }.count
        let doubleIntervalCount = frameIntervals.filter { abs($0 - 2) < 0.05 }.count
        #expect(singleIntervalCount >= frameIntervals.count / 4, "the source's single intervals are missing")
        #expect(doubleIntervalCount >= frameIntervals.count / 4, "the source's double intervals are missing")
        #expect(diagnostics.nativeVideo.appendedFrames == presentationTimes.count)
    }

    /// A seat's clock does not only run forward. A duplicate, a backward step and a 32-bit wrap each
    /// cost at most the frame they belong to; none of them may cost the recording.
    @Test("a recording survives non-monotonic and wrapping source presentation times")
    func recordingSurvivesNonMonotonicAndWrappingSourcePresentationTimes() async throws {
        let frameRate = 120
        let ticksPerFrame = UInt32(NvstVideoToolboxDecoder.clockRate) / UInt32(frameRate)
        // Close enough to the 32-bit ceiling that this feed wraps it part way through.
        var rtpTimestamp = UInt32.max - (ticksPerFrame * 10)
        let recorder = StreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: RecordingTestFixtures.nativeConfiguration(title: "Source Clock Wrap Regression", frameRate: frameRate))

        var frameIndex = 0
        var hasStartedRecording = false
        let warmUpDeadline = ContinuousClock.now + .seconds(15)
        while !hasStartedRecording, ContinuousClock.now < warmUpDeadline {
            if await statuses.terminalStatus() != nil { break }
            try RecordingTestFixtures.appendNativeFrame(to: recorder, frameIndex: frameIndex, rtpTimestamp: rtpTimestamp)
            frameIndex += 1
            rtpTimestamp = rtpTimestamp &+ ticksPerFrame
            hasStartedRecording = await statuses.hasStartedRecording()
            try await Task.sleep(for: .milliseconds(12))
        }
        guard hasStartedRecording else {
            Issue.record("Expected the recording to start")
            return
        }

        for index in 0..<40 {
            switch index {
            // A duplicate: the same timestamp the previous frame carried.
            case 5, 15: break
            case 9, 19: rtpTimestamp = rtpTimestamp &- (ticksPerFrame * 4)
            default: rtpTimestamp = rtpTimestamp &+ ticksPerFrame
            }
            try RecordingTestFixtures.appendNativeFrame(to: recorder, frameIndex: frameIndex, rtpTimestamp: rtpTimestamp)
            frameIndex += 1
            try await Task.sleep(for: .milliseconds(12))
        }

        try await Task.sleep(for: .milliseconds(300))
        let diagnostics = recorder.diagnosticsSnapshot()
        recorder.stop()
        guard case .finished(let recording) = try await RecordingTestFixtures.waitForTerminalStatus(statuses) else {
            Issue.record("Expected a finished recording, got \(String(describing: await statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(recording) }

        #expect(await statuses.hasFailed() == false)
        #expect(diagnostics.sourceClockWraps >= 1)
        #expect(diagnostics.nativeVideo.nonMonotonicPresentationTimeSkips >= 1)
        #expect(diagnostics.nativeVideo.appendedFrames >= 20)
        #expect(diagnostics.nativeVideo.offeredFrames == diagnostics.nativeVideo.appendedFrames + diagnostics.nativeVideo.rejectedFrames)
        let presentationTimes = try await RecordingTestFixtures.presentationTimes(url: recording.videoURL, mediaType: .video)
        #expect(presentationTimes.count == diagnostics.nativeVideo.appendedFrames)
        let frameIntervals = RecordingTestFixtures.frameIntervals(presentationTimes, frameRate: frameRate)
        #expect(frameIntervals.allSatisfy { abs($0 - $0.rounded()) < 0.05 && $0.rounded() >= 1 },
                "the wrap must not put a backwards or fractional gap in the file, got \(frameIntervals)")
    }

    /// Audio has to land on the video track's timeline rather than on the wall clock. This source
    /// clock runs at under half the arrival rate, so stamping audio with arrival time would end the
    /// audio track at roughly twice the video's presentation time and drift the whole way through.
    @Test("audio stays on the video timeline when the source clock runs slower than arrival")
    func audioStaysOnTheVideoTimelineWhenTheSourceClockRunsSlowerThanArrival() async throws {
        let frameRate = 120
        let recorder = StreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: RecordingTestFixtures.nativeConfiguration(title: "Audio Clock Regression", frameRate: frameRate))

        var frameIndex = 0
        var hasStartedRecording = false
        let warmUpDeadline = ContinuousClock.now + .seconds(15)
        while !hasStartedRecording, ContinuousClock.now < warmUpDeadline {
            if await statuses.terminalStatus() != nil { break }
            try RecordingTestFixtures.appendNativeFrame(
                to: recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            frameIndex += 1
            hasStartedRecording = await statuses.hasStartedRecording()
            try await Task.sleep(for: .milliseconds(12))
        }
        guard hasStartedRecording else {
            Issue.record("Expected the recording to start")
            return
        }

        let feedStartedAt = ContinuousClock.now
        for _ in 0..<40 {
            try RecordingTestFixtures.appendNativeFrame(
                to: recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            recorder.appendGameAudioSamples(RecordingTestFixtures.makeSineSamples(frameCount: 480, frameIndex: frameIndex), sampleRate: 48_000, channels: 2)
            frameIndex += 1
            // 20 ms of wall clock per frame against a nominal 8.3 ms source frame interval.
            try await Task.sleep(for: .milliseconds(20))
        }
        let feedDuration = ContinuousClock.now - feedStartedAt
        let feedSeconds = Double(feedDuration.components.seconds) + Double(feedDuration.components.attoseconds) / 1e18

        try await Task.sleep(for: .milliseconds(300))
        let diagnostics = recorder.diagnosticsSnapshot()
        recorder.stop()
        guard case .finished(let recording) = try await RecordingTestFixtures.waitForTerminalStatus(statuses) else {
            Issue.record("Expected a finished recording, got \(String(describing: await statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(recording) }

        let videoSeconds = try await RecordingTestFixtures.trackEndSeconds(url: recording.videoURL, mediaType: .video)
        let audioSeconds = try await RecordingTestFixtures.trackEndSeconds(url: recording.videoURL, mediaType: .audio)
        #expect(videoSeconds > 0.2)
        #expect(diagnostics.audio.appendedBuffers > 0)
        #expect(abs(audioSeconds - videoSeconds) < 0.15, "audio ended at \(audioSeconds)s against video at \(videoSeconds)s")
        #expect(audioSeconds < feedSeconds * 0.75, "audio followed the wall clock (\(feedSeconds)s) instead of the video timeline")
        #expect(diagnostics.videoClockRatio < 0.75)
    }

}

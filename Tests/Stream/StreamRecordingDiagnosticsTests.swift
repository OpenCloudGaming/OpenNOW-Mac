import Foundation
import QuartzCore
import Testing
@testable import OpenNOW

/// The lines a recording's diagnostics logger produced, in the order it produced them.
actor StreamRecordingLogRecorder {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func summaries() -> [String] {
        lines.filter { $0.contains("recording summary") }
    }
}

/// Serialized because the reporting test drives a real `AVAssetWriter`, and concurrent encoders on
/// a loaded runner report not-ready long enough to change which frames a recording keeps.
@Suite("Stream recording diagnostics", .serialized)
struct StreamRecordingDiagnosticsTests {
    private static let everyRejection: [StreamRecorderVideoRejection] = [
        .gate, .staleRecording, .notRecording, .rejectedSource, .rejectedFormat,
        .writerUnavailable, .writerStartFailed, .encoderNotReady, .nonMonotonicPresentationTime, .appendFailure,
    ]

    /// The accounting a support report reconciles against the produced file: nothing may fall
    /// between two buckets, or the log's offered count stops matching the frames the stream sent.
    @Test("every offered frame lands in exactly one bucket")
    func everyOfferedFrameLandsInExactlyOneBucket() {
        var counters = StreamRecorderVideoFrameCounters()
        #expect(counters.isIdle)
        counters.recordAppend()
        for rejection in Self.everyRejection {
            counters.record(rejection)
        }
        #expect(counters.offeredFrames == Self.everyRejection.count + 1)
        #expect(counters.appendedFrames == 1)
        #expect(counters.offeredFrames == counters.appendedFrames + counters.rejectedFrames)
        #expect(counters.isIdle == false)
        #expect(abs(counters.retentionRatio - 1 / Double(Self.everyRejection.count + 1)) < 0.0001)
    }

    @Test("the latency window reports the tail percentiles and the whole recording's extremes")
    func latencyWindowReportsTailPercentilesWithWholeRecordingExtremes() {
        var window = StreamRecorderLatencyWindow()
        #expect(window.percentile(0.5) == -1)
        #expect(window.meanMilliseconds == 0)
        for milliseconds in 1...100 {
            window.record(milliseconds: Double(milliseconds))
        }
        #expect(window.percentile(0.5) == 50.5)
        #expect(window.percentile(0.95) == 95.05)
        #expect(window.maximumMilliseconds == 100)
        #expect(window.meanMilliseconds == 50.5)
        #expect(window.measurementCount == 100)
    }

    /// A stall that happened an hour ago has to survive the window rolling past it, which is the
    /// whole reason `max` and `mean` are whole-recording while the percentiles are not.
    @Test("the latency window rolls past old samples but keeps the whole recording's maximum")
    func latencyWindowRollsPastOldSamplesButKeepsTheWholeRecordingsMaximum() {
        var window = StreamRecorderLatencyWindow()
        for _ in 0..<StreamRecorderLatencyWindow.capacity {
            window.record(milliseconds: 1000)
        }
        for _ in 0..<StreamRecorderLatencyWindow.capacity {
            window.record(milliseconds: 1)
        }
        #expect(window.percentile(0.5) == 1)
        #expect(window.maximumMilliseconds == 1000)
        #expect(window.measurementCount == StreamRecorderLatencyWindow.capacity * 2)
    }

    /// The number that decides whether audio can keep stamping arrival time: how fast the seat's
    /// presentation clock runs against the host's wall clock.
    @Test("the video clock ratio compares the source timeline against the wall clock")
    func videoClockRatioComparesTheSourceTimelineAgainstTheWallClock() {
        var diagnostics = StreamRecorderDiagnostics()
        #expect(diagnostics.isIdle)
        #expect(diagnostics.videoClockRatio == 1)
        diagnostics.recordVideoFrameAppended(makeAppendMeasurement(presentationSeconds: 0, arrivalHostTime: 100))
        #expect(diagnostics.videoClockRatio == 1, "a single frame spans no time")
        diagnostics.recordVideoFrameAppended(makeAppendMeasurement(presentationSeconds: 1, arrivalHostTime: 102))
        #expect(diagnostics.videoArrivalSeconds == 2)
        #expect(diagnostics.videoPresentationSeconds == 1)
        #expect(diagnostics.videoClockRatio == 0.5)
        #expect(diagnostics.nativeVideo.appendedFrames == 2)
        #expect(diagnostics.enhancedVideo.isIdle)
        #expect(diagnostics.isIdle == false)

        var nonsensical = StreamRecorderDiagnostics()
        nonsensical.recordVideoFrameAppended(makeAppendMeasurement(presentationSeconds: 0, arrivalHostTime: 100))
        nonsensical.recordVideoFrameAppended(makeAppendMeasurement(presentationSeconds: 1000, arrivalHostTime: 101))
        #expect(nonsensical.videoClockRatio == 4, "the ratio is clamped so one odd interval cannot scale audio into nonsense")
    }

    /// The counters only help a support report if they reach the session log when the recording
    /// closes: the in-memory copy is cleared by the finish that produces the line.
    @Test("a finished recording reports its frame accounting to the session log")
    func aFinishedRecordingReportsItsFrameAccountingToTheSessionLog() async throws {
        let frameRate = 30
        let logged = StreamRecordingLogRecorder()
        let recording = RecordingTestFixtures.startNativeRecording(title: "Diagnostics Summary", frameRate: frameRate)
        recording.recorder.diagnosticsLogger = { line in Task { await logged.append(line) } }
        guard let warmUp = try await RecordingTestFixtures.warmUpNativeRecording(recording, frameRate: frameRate) else {
            Issue.record("Expected the recording to start")
            return
        }

        var frameIndex = warmUp.nextFrameIndex
        for _ in 0..<10 {
            try RecordingTestFixtures.appendNativeFrame(
                to: recording.recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            frameIndex += 1
            try await Task.sleep(for: .milliseconds(12))
        }

        guard let finished = try await RecordingTestFixtures.finishRecording(recording) else {
            Issue.record("Expected a finished recording, got \(String(describing: await recording.statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(finished.file) }

        var summaries: [String] = []
        let summaryDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < summaryDeadline {
            summaries = await logged.summaries()
            if !summaries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(summaries.count == 1, "expected one terminal summary, got \(summaries)")
        guard let summary = summaries.first else { return }
        #expect(summary.contains("outcome=finished"))
        #expect(summary.contains("source=native"))
        #expect(summary.contains("appendMs[p50=") && summary.contains("queueMs[p50="))
        #expect(Self.integer(after: "native[offered=", in: summary) == finished.diagnostics.nativeVideo.offeredFrames)
        #expect(Self.integer(after: "native[offered=\(finished.diagnostics.nativeVideo.offeredFrames) appended=", in: summary)
                == finished.diagnostics.nativeVideo.appendedFrames)
        #expect(finished.diagnostics.enhancedVideo.isIdle, "a native-only recording must not report enhanced frames")
    }

    /// Which bucket a refused frame lands in, and that a frame arriving with no recording running
    /// lands in none: counting idle frames logs a recording line for a session that never recorded.
    @Test("a refused frame is counted by the gate that refused it")
    func aRefusedFrameIsCountedByTheGateThatRefusedIt() async throws {
        guard let pixelBuffer = RecordingTestFixtures.makeNV12Frame(width: 64, height: 64, frameIndex: 0) else {
            throw StreamRecordingTestError.unableToCreatePixelBuffer
        }
        let idleRecorder = StreamRecorder()
        idleRecorder.appendNativePixelBuffer(pixelBuffer, sourcePresentationTime: RecordingTestFixtures.makeSourcePresentationTime(rtpTimestamp: 0))
        idleRecorder.appendEnhancedPixelBuffer(pixelBuffer)
        #expect(idleRecorder.diagnosticsSnapshot().isIdle, "a frame with no recording running is not a recording's refused frame")

        let recording = RecordingTestFixtures.startNativeRecording(title: "Gate Rejection Buckets", frameRate: 30)
        let startDeadline = ContinuousClock.now + .seconds(5)
        while await recording.statuses.values.isEmpty, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recording.recorder.appendEnhancedPixelBuffer(pixelBuffer)
        let snapshot = recording.recorder.diagnosticsSnapshot()
        recording.recorder.stop()
        #expect(snapshot.enhancedVideo.rejectedSourceRejections == 1, "the native source owns this recording")
        #expect(snapshot.enhancedVideo.gateRejections == 0)
        #expect(snapshot.nativeVideo.isIdle, "the refused frame belongs to the enhanced counters alone")
    }

    private static func integer(after marker: String, in line: String) -> Int? {
        guard let start = line.range(of: marker)?.upperBound else { return nil }
        let digits = line[start...].prefix(while: \.isNumber)
        return Int(digits)
    }

    private func makeAppendMeasurement(presentationSeconds: Double, arrivalHostTime: CFTimeInterval) -> StreamRecorderVideoFrameAppendMeasurement {
        StreamRecorderVideoFrameAppendMeasurement(
            source: .native,
            presentationSeconds: presentationSeconds,
            arrivalHostTime: arrivalHostTime,
            queueDelayMilliseconds: 0.5,
            appendMilliseconds: 1.5
        )
    }
}

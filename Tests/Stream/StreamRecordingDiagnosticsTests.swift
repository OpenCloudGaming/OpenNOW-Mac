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
    func latencyWindowReportsTheTailPercentilesAndTheWholeRecordingsExtremes() {
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
        let recorder = StreamRecorder()
        let logged = StreamRecordingLogRecorder()
        recorder.diagnosticsLogger = { line in Task { await logged.append(line) } }
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in Task { await statuses.append(status) } }
        recorder.start(configuration: RecordingTestFixtures.nativeConfiguration(title: "Diagnostics Summary", frameRate: frameRate))

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
        for _ in 0..<10 {
            try RecordingTestFixtures.appendNativeFrame(
                to: recorder,
                frameIndex: frameIndex,
                rtpTimestamp: RecordingTestFixtures.nominalRtpTimestamp(frameIndex: frameIndex, frameRate: frameRate)
            )
            frameIndex += 1
            try await Task.sleep(for: .milliseconds(12))
        }

        // Read before the finish clears them, so the logged line can be checked against the
        // accounting the recorder itself held.
        try await Task.sleep(for: .milliseconds(300))
        let diagnostics = recorder.diagnosticsSnapshot()
        recorder.stop()
        guard case .finished(let recording) = try await RecordingTestFixtures.waitForTerminalStatus(statuses) else {
            Issue.record("Expected a finished recording, got \(String(describing: await statuses.terminalStatus()))")
            return
        }
        defer { try? StreamRecordingLibrary.delete(recording) }

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
        #expect(Self.integer(after: "native[offered=", in: summary) == diagnostics.nativeVideo.offeredFrames)
        #expect(Self.integer(after: "native[offered=\(diagnostics.nativeVideo.offeredFrames) appended=", in: summary) == diagnostics.nativeVideo.appendedFrames)
        #expect(diagnostics.enhancedVideo.isIdle, "a native-only recording must not report enhanced frames")
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

//  What the recording writer counts, and the lines it reports those counts on.
//

import CoreMedia
import Foundation
import QuartzCore

/// Why a frame the stream offered the recorder never reached the encoder.
enum StreamRecorderVideoRejection: Sendable {
    /// The ingress gate refused it: the native path allows one frame in flight, the enhanced path four.
    case gate
    /// The queued frame belonged to a recording that had already ended.
    case staleRecording
    /// Recording is not running, or the writer has already failed.
    case notRecording
    /// The other video source owns this recording.
    case rejectedSource
    /// The surface could not be converted to a layout the encoder accepts.
    case rejectedFormat
    /// The writer, its video input or its pixel buffer adaptor is missing.
    case writerUnavailable
    /// `AVAssetWriter.startWriting` refused, so the file was never opened.
    case writerStartFailed
    /// The video input reported it could not take more media data.
    case encoderNotReady
    /// The frame's presentation time does not advance past the previous frame's.
    case nonMonotonicPresentationTime
    /// The pixel buffer adaptor refused the frame, which fails the recording with it.
    case appendFailure
}

/// One video source's frame accounting. Every offered frame lands in exactly one bucket, so the
/// log reconciles against the number of frames in the produced file.
struct StreamRecorderVideoFrameCounters: Equatable, Sendable {
    var offeredFrames = 0
    var appendedFrames = 0
    var gateRejections = 0
    var staleRecordingRejections = 0
    var notRecordingRejections = 0
    var rejectedSourceRejections = 0
    var rejectedFormatRejections = 0
    var writerUnavailableRejections = 0
    var writerStartFailedRejections = 0
    var encoderNotReadyRejections = 0
    var nonMonotonicPresentationTimeSkips = 0
    var appendFailures = 0

    var isIdle: Bool { offeredFrames == 0 }

    var retentionRatio: Double {
        guard offeredFrames > 0 else { return 0 }
        return Double(appendedFrames) / Double(offeredFrames)
    }

    /// The rejections, which with `appendedFrames` sum back to `offeredFrames`.
    var rejectedFrames: Int {
        gateRejections + staleRecordingRejections + notRecordingRejections + rejectedSourceRejections
            + rejectedFormatRejections + writerUnavailableRejections + writerStartFailedRejections
            + encoderNotReadyRejections + nonMonotonicPresentationTimeSkips + appendFailures
    }

    mutating func recordAppend() {
        offeredFrames += 1
        appendedFrames += 1
    }

    mutating func record(_ rejection: StreamRecorderVideoRejection) {
        offeredFrames += 1
        switch rejection {
        case .gate: gateRejections += 1
        case .staleRecording: staleRecordingRejections += 1
        case .notRecording: notRecordingRejections += 1
        case .rejectedSource: rejectedSourceRejections += 1
        case .rejectedFormat: rejectedFormatRejections += 1
        case .writerUnavailable: writerUnavailableRejections += 1
        case .writerStartFailed: writerStartFailedRejections += 1
        case .encoderNotReady: encoderNotReadyRejections += 1
        case .nonMonotonicPresentationTime: nonMonotonicPresentationTimeSkips += 1
        case .appendFailure: appendFailures += 1
        }
    }

    var summary: String {
        String(format: "offered=%d appended=%d retained=%.4f gate=%d stale=%d notRecording=%d wrongSource=%d"
               + " format=%d writer=%d writerStart=%d encoderNotReady=%d nonMonotonic=%d appendFailed=%d",
               offeredFrames, appendedFrames, retentionRatio, gateRejections, staleRecordingRejections,
               notRecordingRejections, rejectedSourceRejections, rejectedFormatRejections,
               writerUnavailableRejections, writerStartFailedRejections, encoderNotReadyRejections,
               nonMonotonicPresentationTimeSkips, appendFailures)
    }
}

struct StreamRecorderAudioCounters: Equatable, Sendable {
    var appendedBuffers = 0
    var droppedBuffers = 0
    var lastPresentationSeconds = 0.0

    var summary: String {
        String(format: "buffers=%d dropped=%d seconds=%.3f", appendedBuffers, droppedBuffers, lastPresentationSeconds)
    }
}

/// The last `capacity` measurements, frame-counted rather than time-windowed so the window covers
/// the same slice of the recording at any frame rate. A lifetime mean hides the tail.
struct StreamRecorderLatencyWindow: Equatable, Sendable {
    static let capacity = 1024

    private var samplesMilliseconds: [Double] = []
    private var writeIndex = 0
    private(set) var measurementCount = 0
    private(set) var totalMilliseconds = 0.0
    /// Whole-recording, not windowed: one 300 ms stall still shows after the window has rolled past it.
    private(set) var maximumMilliseconds = 0.0

    mutating func record(milliseconds: Double) {
        measurementCount += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        guard samplesMilliseconds.count >= Self.capacity else {
            samplesMilliseconds.append(milliseconds)
            return
        }
        samplesMilliseconds[writeIndex] = milliseconds
        writeIndex = (writeIndex + 1) % Self.capacity
    }

    /// Linear-interpolated between the two nearest ranks, so a percentile moves smoothly as frames
    /// arrive. Negative when nothing has been measured, matching the pipeline's own window.
    func percentile(_ fraction: Double) -> Double {
        guard !samplesMilliseconds.isEmpty else { return -1 }
        let sorted = samplesMilliseconds.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = fraction * Double(sorted.count - 1)
        let low = Int(rank)
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    var meanMilliseconds: Double {
        guard measurementCount > 0 else { return 0 }
        return totalMilliseconds / Double(measurementCount)
    }

    /// `p50`/`p95` describe the window, `max`/`mean` the whole recording, and `n` says how much of
    /// the recording the window covers.
    var summary: String {
        String(format: "p50=%.2f p95=%.2f max=%.2f mean=%.2f n=%d/%d",
               percentile(0.5), percentile(0.95), maximumMilliseconds, meanMilliseconds,
               samplesMilliseconds.count, measurementCount)
    }
}

/// One appended frame's measurements, taken on the writer's queue.
struct StreamRecorderVideoFrameAppendMeasurement {
    let source: StreamRecorder.VideoFrameSource
    let presentationSeconds: Double
    let arrivalHostTime: CFTimeInterval
    let queueDelayMilliseconds: Double
    let appendMilliseconds: Double
}

/// Everything the writer counted for one recording. Counts and durations only, no identifiers and
/// no paths, so the line needs no redaction before it goes into a support report.
struct StreamRecorderDiagnostics: Equatable, Sendable {
    var nativeVideo = StreamRecorderVideoFrameCounters()
    var enhancedVideo = StreamRecorderVideoFrameCounters()
    var audio = StreamRecorderAudioCounters()
    var queueDelay = StreamRecorderLatencyWindow()
    var appendDuration = StreamRecorderLatencyWindow()
    var sourceClockWraps = 0
    var sourceClockRestarts = 0
    var selectedVideoSource: StreamRecorder.VideoFrameSource?
    /// The presentation span of the appended video frames, on the recording's own timeline.
    var videoPresentationSeconds = 0.0
    private var firstVideoArrivalHostTime: CFTimeInterval?
    private var lastVideoArrivalHostTime: CFTimeInterval?

    var isIdle: Bool {
        nativeVideo.isIdle && enhancedVideo.isIdle && audio.appendedBuffers == 0 && audio.droppedBuffers == 0
    }

    /// The wall-clock span the appended video frames arrived over.
    var videoArrivalSeconds: Double {
        guard let firstVideoArrivalHostTime, let lastVideoArrivalHostTime else { return 0 }
        return max(0, lastVideoArrivalHostTime - firstVideoArrivalHostTime)
    }

    /// The seat's presentation clock against the host's wall clock, which is what audio's arrival
    /// time is scaled by. Clamped so one odd interval cannot scale audio into nonsense.
    var videoClockRatio: Double {
        guard videoArrivalSeconds > 0, videoPresentationSeconds > 0 else { return 1 }
        return min(max(videoPresentationSeconds / videoArrivalSeconds, 0.25), 4)
    }

    mutating func recordVideoFrameAppended(_ measurement: StreamRecorderVideoFrameAppendMeasurement) {
        switch measurement.source {
        case .native: nativeVideo.recordAppend()
        case .enhanced: enhancedVideo.recordAppend()
        }
        queueDelay.record(milliseconds: measurement.queueDelayMilliseconds)
        appendDuration.record(milliseconds: measurement.appendMilliseconds)
        videoPresentationSeconds = measurement.presentationSeconds
        if firstVideoArrivalHostTime == nil { firstVideoArrivalHostTime = measurement.arrivalHostTime }
        lastVideoArrivalHostTime = measurement.arrivalHostTime
    }

    var summary: String {
        String(format: "source=%@ videoSeconds=%.3f arrivalSeconds=%.3f clockRatio=%.4f",
               selectedVideoSource.map { "\($0)" } ?? "none",
               videoPresentationSeconds, videoArrivalSeconds, videoClockRatio)
            + " native[\(nativeVideo.summary)]"
            + " enhanced[\(enhancedVideo.summary)]"
            + " audio[\(audio.summary)]"
            + " queueMs[\(queueDelay.summary)]"
            + " appendMs[\(appendDuration.summary)]"
            + " sourceClock[wraps=\(sourceClockWraps) restarts=\(sourceClockRestarts)]"
    }
}

extension StreamRecorder {
    func recordVideoFrameAppended(_ measurement: StreamRecorderVideoFrameAppendMeasurement) {
        diagnosticsLock.withLock { diagnostics.recordVideoFrameAppended(measurement) }
    }

    func recordVideoFrameRejected(_ rejection: StreamRecorderVideoRejection,
                                  source: VideoFrameSource,
                                  queueDelayMilliseconds: Double? = nil,
                                  appendMilliseconds: Double? = nil) {
        diagnosticsLock.withLock {
            switch source {
            case .native: diagnostics.nativeVideo.record(rejection)
            case .enhanced: diagnostics.enhancedVideo.record(rejection)
            }
            guard let queueDelayMilliseconds else { return }
            diagnostics.queueDelay.record(milliseconds: queueDelayMilliseconds)
            guard let appendMilliseconds else { return }
            diagnostics.appendDuration.record(milliseconds: appendMilliseconds)
        }
    }

    func recordSourceClockWrap() {
        diagnosticsLock.withLock { diagnostics.sourceClockWraps += 1 }
    }

    func recordSourceClockRestart() {
        diagnosticsLock.withLock { diagnostics.sourceClockRestarts += 1 }
    }

    func recordAudioBufferAppended(presentationSeconds: Double) {
        diagnosticsLock.withLock {
            diagnostics.audio.appendedBuffers += 1
            diagnostics.audio.lastPresentationSeconds = presentationSeconds
        }
    }

    func recordAudioBufferDropped() {
        diagnosticsLock.withLock { diagnostics.audio.droppedBuffers += 1 }
    }

    /// The rate the video track's timeline has been advancing at against the wall clock, which is
    /// what audio's video-derived target is scaled by. See `audioPresentationTime`.
    func videoClockRatio() -> Double {
        diagnosticsLock.withLock { diagnostics.videoClockRatio }
    }

    func diagnosticsSnapshot() -> StreamRecorderDiagnostics {
        var snapshot = diagnosticsLock.withLock { diagnostics }
        snapshot.selectedVideoSource = frameLock.withLock { selectedVideoFrameSource }
        return snapshot
    }

    /// The closing accounting line: everything this recording counted, so a support report can
    /// reconcile the frames the stream offered against the file the writer produced.
    func logDiagnosticsSummary(outcome: String) {
        guard let diagnosticsLogger else { return }
        let snapshot = diagnosticsSnapshot()
        guard !snapshot.isIdle else { return }
        diagnosticsLogger("recording summary outcome=\(outcome) \(snapshot.summary)")
    }

    func resetDiagnostics() {
        diagnosticsLock.withLock { diagnostics = StreamRecorderDiagnostics() }
    }
}

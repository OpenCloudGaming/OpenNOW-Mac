//  Synthetic frames, audio and finished recordings for the recording tests.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import OpenNOW

actor StreamRecordingStatusRecorder {
    private(set) var values: [StreamRecordingStatus] = []

    func append(_ status: StreamRecordingStatus) {
        values.append(status)
    }

    func terminalStatus() -> StreamRecordingStatus? {
        values.first { $0.isTerminal }
    }

    func isRecordingStarted() -> Bool {
        values.contains { status in
            if case .recording = status { return true }
            return false
        }
    }

    func isFailed() -> Bool {
        values.contains { status in
            if case .failed = status { return true }
            return false
        }
    }
}

/// A recorder writing a real file, plus every status it emits for the assertions to read.
struct RecordingUnderTest {
    let recorder: StreamRecorder
    let statuses: StreamRecordingStatusRecorder
}

enum RecordingTestFixtures {
    /// Starts a native recording writing a real file, keeping every status it emits.
    static func startNativeRecording(title: String, frameRate: Int) -> RecordingUnderTest {
        let recorder = StreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: nativeConfiguration(title: title, frameRate: frameRate))
        return RecordingUnderTest(recorder: recorder, statuses: statuses)
    }

    /// Feeds nominal frames until the writer accepts one, so what a test measures starts on a
    /// running recording rather than on the encoder's spin-up. Nil when the recording ended first.
    static func warmUpNativeRecording(_ recording: RecordingUnderTest,
                                      frameRate: Int,
                                      firstRtpTimestamp: UInt32 = 0) async throws -> (nextFrameIndex: Int, lastRtpTimestamp: UInt32)? {
        let ticksPerFrame = UInt32(NvstVideoToolboxDecoder.clockRate) / UInt32(max(1, frameRate))
        var nextFrameIndex = 0
        var lastRtpTimestamp = firstRtpTimestamp
        var isFrameFed = false
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if await recording.statuses.isRecordingStarted() { break }
            if await recording.statuses.terminalStatus() != nil { return nil }
            if isFrameFed { lastRtpTimestamp = lastRtpTimestamp &+ ticksPerFrame }
            try appendNativeFrame(to: recording.recorder, frameIndex: nextFrameIndex, rtpTimestamp: lastRtpTimestamp)
            isFrameFed = true
            nextFrameIndex += 1
            try await Task.sleep(for: .milliseconds(12))
        }
        guard await recording.statuses.isRecordingStarted() else { return nil }
        return (nextFrameIndex, lastRtpTimestamp)
    }

    /// Stops the recording and hands back the finished file with the counters captured just before
    /// the finish cleared them. Nil when the recording did not finish.
    static func finishRecording(_ recording: RecordingUnderTest) async throws -> (file: StreamRecording, diagnostics: StreamRecorderDiagnostics)? {
        try await Task.sleep(for: .milliseconds(300))
        let diagnostics = recording.recorder.diagnosticsSnapshot()
        recording.recorder.stop()
        guard case .finished(let file) = try await waitForTerminalStatus(recording.statuses) else { return nil }
        return (file, diagnostics)
    }

    /// A gap that is a whole number of source frame intervals, which source-clock stamping produces
    /// and arrival-time stamping does not.
    static func isWholeFrameInterval(_ interval: Double) -> Bool {
        abs(interval - interval.rounded()) < 0.05 && interval.rounded() >= 1
    }

    static func nativeConfiguration(title: String, frameRate: Int) -> StreamRecordingConfiguration {
        StreamRecordingConfiguration(
            title: title,
            applicationID: "100",
            width: 64,
            height: 64,
            fps: frameRate,
            videoBitrateMbps: 1,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        )
    }

    /// The presentation time the decoder hands over: the seat's RTP timestamp on its 90 kHz clock.
    static func makeSourcePresentationTime(rtpTimestamp: UInt32) -> CMTime {
        CMTime(value: CMTimeValue(rtpTimestamp), timescale: NvstVideoToolboxDecoder.clockRate)
    }

    /// The RTP timestamp of a frame `frameIndex` frames into a stream holding its nominal cadence,
    /// truncated the way the transport's 32-bit counter does.
    static func nominalRtpTimestamp(frameIndex: Int, frameRate: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: frameIndex * Int(NvstVideoToolboxDecoder.clockRate) / frameRate)
    }

    /// One decoded frame offered the way the decoder offers it: an NV12 surface plus its source
    /// presentation time.
    static func appendNativeFrame(to recorder: StreamRecorder, frameIndex: Int, rtpTimestamp: UInt32) throws {
        guard let pixelBuffer = makeNV12Frame(width: 64, height: 64, frameIndex: frameIndex) else {
            throw StreamRecordingTestError.unableToCreatePixelBuffer
        }
        recorder.appendNativePixelBuffer(pixelBuffer, sourcePresentationTime: makeSourcePresentationTime(rtpTimestamp: rtpTimestamp))
    }

    /// Every timed sample in a finished file's track, in the reader's decode order and without the
    /// timing-less parameter-set buffers. A caller needing playback order sorts what it gets.
    static func trackSamples(url: URL, mediaType: AVMediaType) async throws -> [(presentationTime: CMTime, duration: CMTime)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
            throw StreamRecordingTestError.missingTrack(mediaType.rawValue)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw StreamRecordingTestError.unableToReadRecording("the reader refused the track") }
        reader.add(output)
        guard reader.startReading() else {
            throw StreamRecordingTestError.unableToReadRecording(reader.error?.localizedDescription ?? "the reader did not start")
        }
        var samples: [(presentationTime: CMTime, duration: CMTime)] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentationTime.isNumeric else { continue }
            samples.append((presentationTime, CMSampleBufferGetDuration(sampleBuffer)))
        }
        reader.cancelReading()
        return samples
    }

    /// The presentation times of the frames stored in a finished file, in the order they play.
    static func presentationTimes(url: URL, mediaType: AVMediaType) async throws -> [CMTime] {
        try await trackSamples(url: url, mediaType: mediaType)
            .map(\.presentationTime)
            .sorted { CMTimeCompare($0, $1) < 0 }
    }

    /// Where a track's media ends: the latest sample's presentation time plus its own duration,
    /// since audio arrives in buffers holding many samples rather than one per buffer.
    static func trackEndSeconds(url: URL, mediaType: AVMediaType) async throws -> Double {
        try await trackSamples(url: url, mediaType: mediaType)
            .map { sample in
                let end = sample.duration.isValid ? sample.presentationTime + sample.duration : sample.presentationTime
                return end.seconds
            }
            .max() ?? 0
    }

    /// Samples that start before the previous one ends, which is what a timeline derived from
    /// arrival time alone produces.
    static func overlappingSampleCount(_ samples: [(presentationTime: CMTime, duration: CMTime)]) -> Int {
        var previousEnd = CMTime(value: -1, timescale: StreamRecorderSourceClock.timescale)
        var overlapCount = 0
        for sample in samples.sorted(by: { CMTimeCompare($0.presentationTime, $1.presentationTime) < 0 }) {
            if CMTimeCompare(sample.presentationTime, previousEnd) < 0 { overlapCount += 1 }
            let end = sample.duration.isValid ? sample.presentationTime + sample.duration : sample.presentationTime
            previousEnd = CMTimeCompare(end, previousEnd) > 0 ? end : previousEnd
        }
        return overlapCount
    }

    /// The gaps between consecutive presentation times, in units of one frame interval of the
    /// configured frame rate: 1.0 is the nominal gap, 2.0 is one frame's worth of missing footage.
    static func frameIntervals(_ presentationTimes: [CMTime], frameRate: Int) -> [Double] {
        let nominalSeconds = 1 / Double(frameRate)
        return presentationTimes.dropFirst().enumerated().map { index, presentationTime in
            (presentationTime - presentationTimes[index]).seconds / nominalSeconds
        }
    }

    /// Finishing an AVAssetWriter waits on its own queue and a loaded test process pushes that past
    /// the old 2s loop; the happy path still returns the moment the status lands.
    static func waitForTerminalStatus(_ statuses: StreamRecordingStatusRecorder) async throws -> StreamRecordingStatus? {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let terminalStatus = await statuses.terminalStatus() { return terminalStatus }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    static func makeSineSamples(frameCount: Int, frameIndex: Int) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            let phase = Float(frameIndex * frameCount + frame) * 0.01
            let value = sin(phase) * 0.25
            samples.append(value)
            samples.append(value)
        }
        return samples
    }

    static func makeNV12Frame(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let lumaPixels = luma.assumingMemoryBound(to: UInt8.self)
        let chromaPixels = chroma.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                lumaPixels[y * lumaRow + x] = UInt8((x + y + frameIndex * 13) % 256)
            }
        }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                chromaPixels[y * chromaRow + x * 2] = UInt8((x + frameIndex * 7) % 256)
                chromaPixels[y * chromaRow + x * 2 + 1] = UInt8((y + frameIndex * 5) % 256)
            }
        }
        return pixelBuffer
    }

    static func makeBGRAFrame(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x + frameIndex * 11) % 256)
                pixels[offset + 1] = UInt8((y + frameIndex * 17) % 256)
                pixels[offset + 2] = UInt8((x + y + frameIndex * 23) % 256)
                pixels[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    static func makeRecording(title: String, width: Int, height: Int, frames: Int) async throws -> StreamRecording {
        let recorder = StreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: StreamRecordingConfiguration(
            title: title,
            applicationID: "100",
            width: width,
            height: height,
            fps: 30,
            videoBitrateMbps: 1,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: true
        ))

        // Feed frames until the writer accepts one; on loaded CI runners the asset
        // writer input reports not-ready during spin-up and a fixed burst would all
        // be dropped, tripping the first-frame timeout despite frames flowing.
        var frameIndex = 0
        var sawRecording = false
        var framesAfterStart = 0
        let feedDeadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < feedDeadline {
            if await statuses.terminalStatus() != nil { break }
            if let pixelBuffer = makeBGRAFrame(width: width, height: height, frameIndex: frameIndex) {
                recorder.appendEnhancedPixelBuffer(pixelBuffer)
                frameIndex += 1
                if sawRecording { framesAfterStart += 1 }
            } else {
                throw StreamRecordingTestError.unableToCreatePixelBuffer
            }
            if !sawRecording {
                sawRecording = await statuses.values.contains { status in
                    if case .recording = status { return true }
                    return false
                }
            }
            if sawRecording && framesAfterStart >= frames { break }
            // This feed carries no source presentation time, so the writer stamps arrival time and
            // the sleep sets the recorded cadence: a faster feed makes a shorter clip.
            try await Task.sleep(for: .milliseconds(12))
        }
        recorder.stop()
        var terminalStatus: StreamRecordingStatus?
        for _ in 0..<60 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .finished(let recording) = terminalStatus else { throw StreamRecordingTestError.recordingFailed(String(describing: terminalStatus)) }
        return recording
    }
}

enum StreamRecordingTestError: LocalizedError {
    case unableToCreatePixelBuffer
    case recordingFailed(String)
    case missingTrack(String)
    case unableToReadRecording(String)

    var errorDescription: String? {
        switch self {
        case .unableToCreatePixelBuffer:
            return "Unable to create test pixel buffer."
        case .recordingFailed(let status):
            return "Recording failed with status \(status)."
        case .missingTrack(let mediaType):
            return "The recording has no \(mediaType) track."
        case .unableToReadRecording(let reason):
            return "Unable to read the recording: \(reason)."
        }
    }
}

//  One segment of the instant-replay ring: an `AVAssetWriter` of its own, so its first sample is
//  always a keyframe and a sealed segment can be copied through without re-encoding.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A finalized segment, as the clip exporter needs it: where the file is, the capture window it
/// covers on the replay clock and the encoded shape that window was written at.
struct StreamReplaySealedSegment: Sendable {
    let url: URL
    let hostStart: CFTimeInterval
    let hostEnd: CFTimeInterval
    let width: Int
    let height: Int
}

/// How a segment's file closed: `.empty` is a rotation that landed before the encoder took a frame.
enum StreamReplaySegmentFinishResult: Sendable {
    case sealed(StreamReplaySealedSegment)
    case empty
    case failed(String)
}

/// Writes one short file for the replay ring. Driven entirely from `StreamReplayBuffer`'s serial
/// queue, so it keeps no lock of its own.
final class StreamReplaySegmentWriter {
    let outputURL: URL
    private let configuration: StreamRecordingConfiguration
    private let pixelTransfer: OPNPixelBufferTransfer
    private let originHostTime: CFTimeInterval
    /// 0 keeps the stream's own height; the replay quality tier caps it otherwise.
    private let maxHeight: Int
    /// 0 lets the recording bitrate setting decide.
    private let bitrateCeilingMbps: Int

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private(set) var width = 0
    private(set) var height = 0
    private(set) var lastVideoHostTime: CFTimeInterval?
    private(set) var isVideoWritten = false

    var outputFileSizeBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    init(outputURL: URL,
         configuration: StreamRecordingConfiguration,
         pixelTransfer: OPNPixelBufferTransfer,
         originHostTime: CFTimeInterval,
         maxHeight: Int,
         bitrateCeilingMbps: Int) {
        self.outputURL = outputURL
        self.configuration = configuration
        self.pixelTransfer = pixelTransfer
        self.originHostTime = originHostTime
        self.maxHeight = maxHeight
        self.bitrateCeilingMbps = bitrateCeilingMbps
    }

    /// Appends one decoded frame. False means the frame was dropped — a busy encoder or a format the
    /// writer was not declared for — never that the segment is broken.
    func appendVideo(pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) -> Bool {
        guard writer == nil || writer?.status == .unknown || writer?.status == .writing else { return false }
        // Capped first, so the writer is declared at the size that is actually encoded and a small
        // tier never pays for a full-resolution frame.
        guard let scaled = pixelTransfer.scaled(pixelBuffer, maxHeight: maxHeight),
              let compatible = WebRTCStreamRecorder.encoderCompatiblePixelBuffer(scaled, using: pixelTransfer) else { return false }
        guard prepareWriterIfNeeded(pixelBuffer: compatible) else { return false }
        guard let writer, let input = videoInput, let adaptor = pixelBufferAdaptor else { return false }
        if writer.status == .unknown {
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)
        }
        guard input.isReadyForMoreMediaData else { return false }
        let time = CMTime(seconds: max(0, hostTime - originHostTime), preferredTimescale: 600)
        guard adaptor.append(compatible, withPresentationTime: time) else { return false }
        lastVideoHostTime = hostTime
        isVideoWritten = true
        return true
    }

    /// Appends decoded PCM. Dropped until the segment has a first video frame, so every segment's
    /// audio starts inside the window its video does.
    func appendAudio(data: Data, frameCount: UInt32, sampleRate: Double, channels: UInt32, hostTime: CFTimeInterval) -> Bool {
        guard isVideoWritten, let writer, writer.status == .writing, let input = audioInput, input.isReadyForMoreMediaData else { return false }
        let seconds = hostTime - originHostTime
        guard seconds >= 0 else { return false }
        let presentationTime = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let sampleBuffer = WebRTCStreamRecorder.makeAudioSampleBuffer(
            data: data,
            frameCount: frameCount,
            sampleRate: sampleRate,
            channels: channels,
            presentationTime: presentationTime
        ) else { return false }
        return input.append(sampleBuffer)
    }

    /// Closes the file. The result arrives on `AVAssetWriter`'s own queue.
    func finish(completion: @escaping @Sendable (StreamReplaySegmentFinishResult) -> Void) {
        guard let writer else {
            try? FileManager.default.removeItem(at: outputURL)
            completion(.empty)
            return
        }
        guard writer.status == .writing else {
            let failure = writer.error.map(Self.message)
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            completion(failure.map(StreamReplaySegmentFinishResult.failed) ?? .empty)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let context = StreamReplaySegmentFinishContext(
            writer: writer,
            url: outputURL,
            hostStart: originHostTime,
            hostEnd: lastVideoHostTime,
            width: width,
            height: height,
            completion: completion
        )
        writer.finishWriting {
            context.finish()
        }
    }

    static func message(for error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    private func prepareWriterIfNeeded(pixelBuffer: CVPixelBuffer) -> Bool {
        if writer != nil { return true }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false
            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: WebRTCStreamRecorder.videoSettings(
                    configuration: configuration,
                    width: width,
                    height: height,
                    bitrateCeiling: bitrateCeilingMbps > 0 ? bitrateCeilingMbps * 1_000_000 : nil
                )
            )
            videoInput.expectsMediaDataInRealTime = true
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: WebRTCStreamRecorder.adaptorPixelFormat(for: pixelBuffer),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
            guard writer.canAdd(videoInput) else { throw WebRTCStreamRecorderError.unableToAddVideoInput }
            writer.add(videoInput)

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: WebRTCStreamRecorder.audioSettings(configuration: configuration))
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput); self.audioInput = audioInput }

            self.writer = writer
            self.videoInput = videoInput
            self.pixelBufferAdaptor = adaptor
            self.width = width
            self.height = height
            return true
        } catch {
            return false
        }
    }
}

/// Carries the sealed values into `AVAssetWriter.finishWriting`. The buffer no longer touches the
/// writer once `finish` is called, which is what makes the unchecked conformance honest.
private final class StreamReplaySegmentFinishContext: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let url: URL
    private let hostStart: CFTimeInterval
    private let hostEnd: CFTimeInterval?
    private let width: Int
    private let height: Int
    private let completion: @Sendable (StreamReplaySegmentFinishResult) -> Void

    init(writer: AVAssetWriter,
         url: URL,
         hostStart: CFTimeInterval,
         hostEnd: CFTimeInterval?,
         width: Int,
         height: Int,
         completion: @escaping @Sendable (StreamReplaySegmentFinishResult) -> Void) {
        self.writer = writer
        self.url = url
        self.hostStart = hostStart
        self.hostEnd = hostEnd
        self.width = width
        self.height = height
        self.completion = completion
    }

    func finish() {
        guard writer.status == .completed else {
            let failure = writer.error.map(StreamReplaySegmentWriter.message)
            try? FileManager.default.removeItem(at: url)
            completion(failure.map(StreamReplaySegmentFinishResult.failed) ?? .empty)
            return
        }
        guard let hostEnd else {
            try? FileManager.default.removeItem(at: url)
            completion(.empty)
            return
        }
        completion(.sealed(StreamReplaySealedSegment(
            url: url,
            hostStart: hostStart,
            hostEnd: hostEnd,
            width: width,
            height: height
        )))
    }
}

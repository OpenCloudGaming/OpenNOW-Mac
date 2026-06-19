import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import WebRTC

public struct WebRTCStreamRecording: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let applicationID: String
    public let createdAt: Date
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
    public let videoBitrateMbps: Int
    public let audioBitrateKbps: Int
    public let enhancedVideo: Bool
    public let fileName: String
    public let fileSizeBytes: Int64

    public var videoURL: URL { WebRTCStreamRecordingLibrary.recordingsDirectory.appendingPathComponent(fileName) }
    public var metadataURL: URL { WebRTCStreamRecordingLibrary.metadataURL(for: id) }
}

public enum WebRTCStreamRecordingLibrary {
    public static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("OpenNOW", isDirectory: true).appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func metadataURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }

    public static func loadRecordings() -> [WebRTCStreamRecording] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension.caseInsensitiveCompare("json") == .orderedSame }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.recordingDecoder.decode(WebRTCStreamRecording.self, from: data)
            }
            .filter { FileManager.default.fileExists(atPath: $0.videoURL.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func delete(_ recording: WebRTCStreamRecording) throws {
        if FileManager.default.fileExists(atPath: recording.videoURL.path) { try FileManager.default.removeItem(at: recording.videoURL) }
        if FileManager.default.fileExists(atPath: recording.metadataURL.path) { try FileManager.default.removeItem(at: recording.metadataURL) }
    }
}

public struct WebRTCStreamRecordingConfiguration: Equatable, Sendable {
    public let title: String
    public let applicationID: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let videoBitrateMbps: Int
    public let audioBitrateKbps: Int
    public let enhancedVideoEnabled: Bool

    public init(title: String, applicationID: String, width: Int, height: Int, fps: Int, videoBitrateMbps: Int, audioBitrateKbps: Int, enhancedVideoEnabled: Bool) {
        self.title = title.isEmpty ? "GeForce NOW Stream" : title
        self.applicationID = applicationID
        self.width = max(1, width)
        self.height = max(1, height)
        self.fps = max(1, fps)
        self.videoBitrateMbps = max(0, videoBitrateMbps)
        self.audioBitrateKbps = min(max(audioBitrateKbps, 64), 320)
        self.enhancedVideoEnabled = enhancedVideoEnabled
    }
}

public enum WebRTCStreamRecordingStatus: Equatable, Sendable {
    case idle
    case starting
    case recording(startedAt: Date, elapsedSeconds: Double)
    case finishing
    case finished(WebRTCStreamRecording)
    case failed(String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

final class WebRTCStreamRecorder: @unchecked Sendable {
    var onStatusChanged: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?

    private let queue = DispatchQueue(label: "io.opencg.opennow.recording.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var configuration: WebRTCStreamRecordingConfiguration?
    private var id = UUID()
    private var outputURL: URL?
    private var createdAt = Date()
    private var startedAt: Date?
    private var firstHostTime: CFTimeInterval?
    private var lastPresentationTime = CMTime.zero
    private var lastStatusHostTime: CFTimeInterval = 0
    private var finishing = false
    private var failed = false

    var wantsEnhancedVideo: Bool { configuration?.enhancedVideoEnabled == true && isRecording }
    var isRecording: Bool { writer != nil && !finishing && !failed }

    func start(configuration: WebRTCStreamRecordingConfiguration) {
        queue.async {
            guard self.writer == nil else { return }
            do {
                try WebRTCStreamRecordingLibrary.ensureDirectory()
                self.id = UUID()
                self.configuration = configuration
                self.createdAt = Date()
                self.startedAt = nil
                self.firstHostTime = nil
                self.lastPresentationTime = .zero
                self.lastStatusHostTime = 0
                self.finishing = false
                self.failed = false
                let url = WebRTCStreamRecordingLibrary.recordingsDirectory.appendingPathComponent(self.id.uuidString).appendingPathExtension("mp4")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                self.outputURL = url
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                writer.shouldOptimizeForNetworkUse = false

                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: self.videoSettings(configuration: configuration))
                videoInput.expectsMediaDataInRealTime = true
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: configuration.width,
                    kCVPixelBufferHeightKey as String: configuration.height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
                guard writer.canAdd(videoInput) else { throw WebRTCStreamRecorderError.unableToAddVideoInput }
                writer.add(videoInput)

                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: self.audioSettings(configuration: configuration))
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) { writer.add(audioInput); self.audioInput = audioInput } else { self.audioInput = nil }

                self.writer = writer
                self.videoInput = videoInput
                self.pixelBufferAdaptor = adaptor
                self.emit(.starting)
            } catch {
                self.reset()
                self.emit(.failed(Self.message(for: error)))
            }
        }
    }

    func stop() {
        queue.async { self.finish() }
    }

    func appendVideoFrame(_ frame: RTCVideoFrame) {
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
        appendPixelBuffer(buffer.pixelBuffer)
    }

    func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        appendPixelBuffer(pixelBuffer)
    }

    func appendGameAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList else { return }
        let copied = Self.audioData(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), channels: max(1, Int(channels)))
        guard !copied.isEmpty else { return }
        queue.async {
            guard self.isRecording, let input = self.audioInput, input.isReadyForMoreMediaData else { return }
            guard let time = self.presentationTime() else { return }
            guard let sampleBuffer = Self.makeAudioSampleBuffer(data: copied, frameCount: frameCount, sampleRate: sampleRate, channels: channels, presentationTime: time) else { return }
            input.append(sampleBuffer)
        }
    }

    private func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        queue.async {
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(bitPattern: retainedPixelBuffer)!).takeRetainedValue()
            guard self.isRecording,
                  let writer = self.writer,
                  let input = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor,
                  input.isReadyForMoreMediaData else { return }
            guard let time = self.presentationTime() else { return }
            if writer.status == .unknown {
                guard writer.startWriting() else {
                    self.fail(writer.error)
                    return
                }
                writer.startSession(atSourceTime: .zero)
            }
            let normalizedTime = CMTimeSubtract(time, self.firstPresentationTime)
            guard adaptor.append(pixelBuffer, withPresentationTime: normalizedTime) else {
                self.fail(writer.error)
                return
            }
            self.lastPresentationTime = normalizedTime
            self.emitElapsedIfNeeded()
        }
    }

    private var firstPresentationTime: CMTime { .zero }

    private func presentationTime() -> CMTime? {
        let now = CACurrentMediaTime()
        if firstHostTime == nil {
            firstHostTime = now
            startedAt = Date()
            emit(.recording(startedAt: startedAt ?? createdAt, elapsedSeconds: 0))
        }
        guard let firstHostTime else { return nil }
        return CMTime(seconds: max(0, now - firstHostTime), preferredTimescale: 600)
    }

    private func finish() {
        guard let writer else { return }
        guard !finishing else { return }
        finishing = true
        emit(.finishing)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            queue.async { self.finishCompletedRecording() }
        }
    }

    private func finishCompletedRecording() {
        defer { reset() }
        guard let writer, writer.status == .completed, let configuration, let outputURL else {
            emit(.failed(Self.message(for: writer?.error)))
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let recording = WebRTCStreamRecording(
            id: id,
            title: configuration.title,
            applicationID: configuration.applicationID,
            createdAt: createdAt,
            durationSeconds: max(0, lastPresentationTime.seconds),
            width: configuration.width,
            height: configuration.height,
            videoBitrateMbps: configuration.videoBitrateMbps,
            audioBitrateKbps: configuration.audioBitrateKbps,
            enhancedVideo: configuration.enhancedVideoEnabled,
            fileName: outputURL.lastPathComponent,
            fileSizeBytes: fileSize
        )
        do {
            let data = try JSONEncoder.recordingEncoder.encode(recording)
            try data.write(to: WebRTCStreamRecordingLibrary.metadataURL(for: recording.id), options: .atomic)
            emit(.finished(recording))
        } catch {
            emit(.failed(Self.message(for: error)))
        }
    }

    private func fail(_ error: Error?) {
        failed = true
        writer?.cancelWriting()
        reset()
        emit(.failed(Self.message(for: error)))
    }

    private func reset() {
        writer = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        audioInput = nil
        configuration = nil
        outputURL = nil
        startedAt = nil
        firstHostTime = nil
        finishing = false
        failed = false
    }

    private func emitElapsedIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastStatusHostTime >= 0.5, let startedAt else { return }
        lastStatusHostTime = now
        emit(.recording(startedAt: startedAt, elapsedSeconds: max(0, now - (firstHostTime ?? now))))
    }

    private func emit(_ status: WebRTCStreamRecordingStatus) {
        Task { @MainActor [onStatusChanged] in onStatusChanged?(status) }
    }

    private func videoSettings(configuration: WebRTCStreamRecordingConfiguration) -> [String: Any] {
        let bitrate = configuration.videoBitrateMbps > 0 ? configuration.videoBitrateMbps * 1_000_000 : max(4_000_000, configuration.width * configuration.height * configuration.fps / 8)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.fps,
                AVVideoMaxKeyFrameIntervalKey: configuration.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    private func audioSettings(configuration: WebRTCStreamRecordingConfiguration) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: configuration.audioBitrateKbps * 1_000,
        ]
    }

    private static func audioData(from audioBufferList: UnsafePointer<AudioBufferList>, channels: Int) -> Data {
        var data = Data()
        let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)
        withUnsafePointer(to: audioBufferList.pointee.mBuffers) { firstBuffer in
            let buffers = UnsafeBufferPointer(start: firstBuffer, count: bufferCount)
            for buffer in buffers {
                guard let source = buffer.mData, buffer.mDataByteSize > 0 else { continue }
                data.append(source.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
            }
        }
        return data
    }

    private static func makeAudioSampleBuffer(data: Data, frameCount: UInt32, sampleRate: Double, channels: UInt32, presentationTime: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { pointer in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer).flatMapStatus {
                guard let baseAddress = pointer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: data.count)
            }
        }
        guard status == noErr, let blockBuffer else { return nil }
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate > 0 ? sampleRate : 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: max(1, channels) * 2, mFramesPerPacket: 1, mBytesPerFrame: max(1, channels) * 2, mChannelsPerFrame: max(1, channels), mBitsPerChannel: 16, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate > 0 ? sampleRate : 48_000)), presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription, sampleCount: CMItemCount(frameCount), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    private static func message(for error: Error?) -> String {
        guard let error else { return "Recording failed." }
        return error.localizedDescription.isEmpty ? "Recording failed." : error.localizedDescription
    }
}

private enum WebRTCStreamRecorderError: LocalizedError {
    case unableToAddVideoInput

    var errorDescription: String? {
        switch self {
        case .unableToAddVideoInput: return "Unable to create the recording video encoder."
        }
    }
}

private extension JSONEncoder {
    static var recordingEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var recordingDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension OSStatus {
    func flatMapStatus(_ next: () -> OSStatus) -> OSStatus {
        self == noErr ? next() : self
    }
}

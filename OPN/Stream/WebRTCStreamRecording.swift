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
    public let storageDirectoryPath: String?

    public var videoURL: URL { storageDirectory.appendingPathComponent(fileName) }
    public var metadataURL: URL { storageDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    private var storageDirectory: URL {
        guard let storageDirectoryPath, !storageDirectoryPath.isEmpty else { return WebRTCStreamRecordingLibrary.recordingsDirectory(forGameTitle: title) }
        return URL(fileURLWithPath: storageDirectoryPath, isDirectory: true)
    }
}

public enum WebRTCStreamRecordingLibrary {
    public static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return base.appendingPathComponent("NVIDIA", isDirectory: true).appendingPathComponent("GeForce NOW", isDirectory: true)
    }

    public static func recordingsDirectory(forGameTitle title: String) -> URL {
        recordingsDirectory.appendingPathComponent(gameDirectoryName(title), isDirectory: true)
    }

    public static func metadataURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    @discardableResult
    public static func ensureDirectory(forGameTitle title: String) throws -> URL {
        let directory = recordingsDirectory(forGameTitle: title)
        try ensureWritableDirectory(at: directory)
        return directory
    }

    public static func loadRecordings() -> [WebRTCStreamRecording] {
        recordingMetadataURLs()
            .filter { $0.pathExtension.caseInsensitiveCompare("json") == .orderedSame }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let recording = try? JSONDecoder.recordingDecoder.decode(WebRTCStreamRecording.self, from: data) else { return nil }
                if recording.storageDirectoryPath == nil {
                    return WebRTCStreamRecording(
                        id: recording.id,
                        title: recording.title,
                        applicationID: recording.applicationID,
                        createdAt: recording.createdAt,
                        durationSeconds: recording.durationSeconds,
                        width: recording.width,
                        height: recording.height,
                        videoBitrateMbps: recording.videoBitrateMbps,
                        audioBitrateKbps: recording.audioBitrateKbps,
                        enhancedVideo: recording.enhancedVideo,
                        fileName: recording.fileName,
                        fileSizeBytes: recording.fileSizeBytes,
                        storageDirectoryPath: url.deletingLastPathComponent().path
                    )
                }
                return recording
            }
            .filter { FileManager.default.fileExists(atPath: $0.videoURL.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func delete(_ recording: WebRTCStreamRecording) throws {
        if FileManager.default.fileExists(atPath: recording.videoURL.path) { try FileManager.default.removeItem(at: recording.videoURL) }
        if FileManager.default.fileExists(atPath: recording.metadataURL.path) { try FileManager.default.removeItem(at: recording.metadataURL) }
        let directory = recording.videoURL.deletingLastPathComponent()
        if let remaining = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), remaining.isEmpty {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func recordingMetadataURLs() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: recordingsDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            guard url.pathExtension.caseInsensitiveCompare("json") == .orderedSame else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == false ? nil : url
        }
    }

    private static func gameDirectoryName(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "GeForce NOW Stream" : String(trimmed.prefix(120))
    }

    private static func ensureWritableDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".opennow-write-test", isDirectory: false)
        try Data().write(to: probe, options: .atomic)
        try? FileManager.default.removeItem(at: probe)
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

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed:
            true
        case .idle, .starting, .recording, .finishing:
            false
        }
    }
}

final class WebRTCStreamRecorder: @unchecked Sendable {
    /// Written by whoever owns the recorder, read on `queue` by `emit`. Locked because those are
    /// different threads and the NVST transport installs the handler from its actor.
    var onStatusChanged: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)? {
        get { statusHandlerLock.withLock { storedStatusHandler } }
        set { statusHandlerLock.withLock { storedStatusHandler = newValue } }
    }

    private let statusHandlerLock = NSLock()
    private var storedStatusHandler: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?
    var statusHandler: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)? {
        statusHandlerLock.withLock { storedStatusHandler }
    }

    /// The previous status delivery, so `emit` can keep them in order. Touched only on `queue`.
    var statusDeliveryTask: Task<Void, Never>?

    enum VideoFrameSource {
        case native
        case enhanced
    }

    let queue = DispatchQueue(label: "io.opencg.opennow.recording.writer")
    private let conversionQueue = DispatchQueue(label: "io.opencg.opennow.recording.conversion", qos: .userInitiated)
    let frameLock = NSLock()
    let firstFrameTimeout: DispatchTimeInterval
    let maxQueuedEnhancedVideoFrames = 4
    var writer: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    var audioInput: AVAssetWriterInput?
    var configuration: WebRTCStreamRecordingConfiguration?
    var id = UUID()
    var outputURL: URL?
    let i420BGRAConverter = WebRTCI420BGRAConverter()
    var i420PixelBufferPool: CVPixelBufferPool?
    var i420PixelBufferPoolWidth = 0
    var i420PixelBufferPoolHeight = 0
    var createdAt = Date()
    var startedAt: Date?
    var firstHostTime: CFTimeInterval?
    var lastPresentationTime = CMTime.zero
    var lastStatusHostTime: CFTimeInterval = 0
    var capturedVideoFrame = false
    /// A frame reached the writer, whether or not the encoder took it. Distinguishes a stalled
    /// encoder from a video path that is delivering nothing.
    var offeredVideoFrame = false
    var firstFrameTimeoutExtensions = 0
    /// How many extra `firstFrameTimeout` windows a recording gets while frames keep arriving but
    /// the encoder has still not accepted one. Bounded so a permanently stuck encoder still fails
    /// rather than recording forever into nothing.
    static let maxFirstFrameTimeoutExtensions = 3
    var recordingWidth = 0
    var recordingHeight = 0
    var finishing = false
    var failed = false
    var activeRecordingId: UUID?
    var enhancedVideoPreferred = false
    var selectedVideoFrameSource: VideoFrameSource?
    var pendingNativeVideoRecordingId: UUID?
    var pendingEnhancedVideoFrameCount = 0

    init(firstFrameTimeout: DispatchTimeInterval = .seconds(5)) {
        self.firstFrameTimeout = firstFrameTimeout
    }

    var wantsEnhancedVideo: Bool { configuration?.enhancedVideoEnabled == true && isRecording }
    var isRecording: Bool {
        guard configuration != nil, !finishing, !failed else { return false }
        guard let writer else { return true }
        return writer.status == .unknown || writer.status == .writing
    }

    func start(configuration: WebRTCStreamRecordingConfiguration) {
        queue.async {
            guard self.configuration == nil, self.writer == nil else { return }
            do {
                let directory = try WebRTCStreamRecordingLibrary.ensureDirectory(forGameTitle: configuration.title)
                self.id = UUID()
                self.setActiveRecordingId(self.id, enhancedVideoPreferred: configuration.enhancedVideoEnabled)
                self.configuration = configuration
                self.createdAt = Date()
                self.startedAt = nil
                self.firstHostTime = nil
                self.lastPresentationTime = .zero
                self.lastStatusHostTime = 0
                self.capturedVideoFrame = false
                self.offeredVideoFrame = false
                self.firstFrameTimeoutExtensions = 0
                self.recordingWidth = 0
                self.recordingHeight = 0
                self.finishing = false
                self.failed = false
                let url = directory.appendingPathComponent(self.id.uuidString).appendingPathExtension("mp4")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                self.outputURL = url
                self.startedAt = self.createdAt
                self.firstHostTime = CACurrentMediaTime()
                self.emit(.starting)
                self.scheduleFirstFrameTimeout(recordingId: self.id)
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
        guard let recordingId = beginVideoFrameAppend(source: .native) else { return }
        let captureHostTime = CACurrentMediaTime()
        if let buffer = frame.buffer as? RTCCVPixelBuffer, Self.isWritableBGRA(buffer.pixelBuffer) {
            appendPixelBuffer(buffer.pixelBuffer, recordingId: recordingId, source: .native, captureHostTime: captureHostTime)
            return
        }
        let retainedFrame = UInt(bitPattern: Unmanaged.passRetained(frame).toOpaque())
        conversionQueue.async {
            guard let framePointer = UnsafeRawPointer(bitPattern: retainedFrame) else {
                self.finishVideoFrameAppend(recordingId: recordingId, source: .native)
                return
            }
            let frame = Unmanaged<RTCVideoFrame>.fromOpaque(framePointer).takeRetainedValue()
            let i420Frame = frame.newI420()
            guard let i420 = i420Frame.buffer as? RTCI420Buffer,
                  let pixelBuffer = self.newBGRAFramebuffer(from: i420) else {
                self.finishVideoFrameAppend(recordingId: recordingId, source: .native)
                return
            }
            let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
            self.queue.async {
                defer { self.finishVideoFrameAppend(recordingId: recordingId, source: .native) }
                guard let pixelBufferPointer = UnsafeRawPointer(bitPattern: retainedPixelBuffer) else { return }
                let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBufferPointer).takeRetainedValue()
                guard self.isActiveRecording(recordingId) else { return }
                self.appendPixelBufferOnQueue(pixelBuffer, source: .native, captureHostTime: captureHostTime)
            }
        }
    }

    /// Appends a decoded frame that is already a `CVPixelBuffer`, with no libwebrtc frame around
    /// it. The native NVST transport owns its VideoToolbox decoder, so its frames arrive here
    /// directly instead of through `appendVideoFrame`, skipping the I420/BGRA conversion that path
    /// needs — the writer takes the decoder's format as-is.
    func appendNativePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let recordingId = beginVideoFrameAppend(source: .native) else { return }
        appendPixelBuffer(pixelBuffer, recordingId: recordingId, source: .native, captureHostTime: CACurrentMediaTime())
    }

    func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let recordingId = beginVideoFrameAppend(source: .enhanced) else { return }
        appendPixelBuffer(pixelBuffer, recordingId: recordingId, source: .enhanced, captureHostTime: CACurrentMediaTime())
    }

    /// Appends decoded PCM that never passed through an audio device: interleaved `Float` samples,
    /// which is what the NVST Opus decoder produces when audio runs on its own socket instead of
    /// through libwebrtc. Converted here rather than at the call site so both audio feeds land in
    /// the same Int16 writer path.
    func appendGameAudioSamples(_ samples: [Float], sampleRate: Double, channels: UInt32) {
        let channelCount = max(1, Int(channels))
        guard !samples.isEmpty, samples.count % channelCount == 0 else { return }
        var interleaved = [Int16](unsafeUninitializedCapacity: samples.count) { buffer, initializedCount in
            for index in 0..<samples.count {
                let clamped = min(max(samples[index], -1), 1)
                buffer[index] = Int16(clamped * 32767)
            }
            initializedCount = samples.count
        }
        let frameCount = UInt32(samples.count / channelCount)
        let data = interleaved.withUnsafeMutableBytes { Data($0) }
        queue.async {
            guard self.isRecording,
                  self.capturedVideoFrame,
                  self.writer?.status == .writing,
                  let input = self.audioInput,
                  input.isReadyForMoreMediaData else { return }
            guard let time = self.presentationTime() else { return }
            guard let sampleBuffer = Self.makeAudioSampleBuffer(data: data, frameCount: frameCount, sampleRate: sampleRate, channels: channels, presentationTime: time) else { return }
            input.append(sampleBuffer)
        }
    }

    func appendGameAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList else { return }
        let copied = Self.audioData(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), channels: max(1, Int(channels)))
        guard !copied.isEmpty else { return }
        queue.async {
            guard self.isRecording,
                  self.capturedVideoFrame,
                  self.writer?.status == .writing,
                  let input = self.audioInput,
                  input.isReadyForMoreMediaData else { return }
            guard let time = self.presentationTime() else { return }
            guard let sampleBuffer = Self.makeAudioSampleBuffer(data: copied, frameCount: frameCount, sampleRate: sampleRate, channels: channels, presentationTime: time) else { return }
            input.append(sampleBuffer)
        }
    }

}

enum WebRTCStreamRecorderError: LocalizedError {
    case noFramesCaptured
    case unableToAddVideoInput
    case videoFramesUnavailable

    var errorDescription: String? {
        switch self {
        case .noFramesCaptured: return "Recording stopped before any video frames were captured."
        case .unableToAddVideoInput: return "Unable to create the recording video encoder."
        case .videoFramesUnavailable: return "Recording could not capture video frames."
        }
    }
}

extension JSONEncoder {
    static var recordingEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var recordingDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension OSStatus {
    /// Chains a second CoreAudio call, short-circuiting on the first failure.
    func flatMapStatus(_ next: () -> OSStatus) -> OSStatus {
        self == noErr ? next() : self
    }
}

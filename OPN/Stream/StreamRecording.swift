import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

public struct StreamRecording: Codable, Equatable, Identifiable, Sendable {
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
    /// Where the video and its sidecar live. Mutable so a library scan can heal a stale path from the
    /// sidecar's own directory when the reader has moved the folder.
    public var storageDirectoryPath: String?

    public var videoURL: URL { storageDirectory.appendingPathComponent(fileName) }
    public var metadataURL: URL { storageDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    private var storageDirectory: URL {
        guard let storageDirectoryPath, !storageDirectoryPath.isEmpty else { return StreamRecordingLibrary.recordingsDirectory(forGameTitle: title) }
        return URL(fileURLWithPath: storageDirectoryPath, isDirectory: true)
    }
}

public enum StreamRecordingLibrary {
    /// Where the reader's recordings live. A thin forwarder: `OPNCaptureLocations` owns the default,
    /// the reader's override, and its validation.
    public static var recordingsDirectory: URL {
        OPNCaptureLocations.recordingsDirectory
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

    public static func loadRecordings() -> [StreamRecording] {
        recordingMetadataURLs()
            .filter { $0.pathExtension.caseInsensitiveCompare("json") == .orderedSame }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard var recording = try? JSONDecoder.recordingDecoder.decode(StreamRecording.self, from: data) else { return nil }
                // A stored path that no longer exists — the folder moved, in Finder or by us — falls
                // back to the sidecar's own directory, which also backfills a sidecar written before
                // the field existed. Retained-replay clips keep their Application Support path.
                recording.storageDirectoryPath = StreamScreenshotLibrary.resolvedStorageDirectoryPath(
                    stored: recording.storageDirectoryPath,
                    sidecarDirectory: url.deletingLastPathComponent()
                )
                return recording
            }
            .filter { FileManager.default.fileExists(atPath: $0.videoURL.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func delete(_ recording: StreamRecording) throws {
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
        try OPNCaptureLocations.ensureWritableDirectory(at: directory)
    }
}

public struct StreamRecordingConfiguration: Equatable, Sendable {
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

public enum StreamRecordingStatus: Equatable, Sendable {
    case idle
    case starting
    case recording(startedAt: Date, elapsedSeconds: Double)
    case finishing
    case finished(StreamRecording)
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

final class StreamRecorder: @unchecked Sendable {
    /// Converts surfaces the asset-writer adaptor was not declared for. See `encoderCompatiblePixelBuffer`.
    let pixelTransfer = OPNPixelBufferTransfer()
    /// Written by whoever owns the recorder, read on `queue` by `emit`. Locked because those are
    /// different threads and the NVST transport installs the handler from its actor.
    var onStatusChanged: (@MainActor @Sendable (StreamRecordingStatus) -> Void)? {
        get { statusHandlerLock.withLock { storedStatusHandler } }
        set { statusHandlerLock.withLock { storedStatusHandler = newValue } }
    }

    private let statusHandlerLock = NSLock()
    private var storedStatusHandler: (@MainActor @Sendable (StreamRecordingStatus) -> Void)?
    var statusHandler: (@MainActor @Sendable (StreamRecordingStatus) -> Void)? {
        statusHandlerLock.withLock { storedStatusHandler }
    }

    /// The previous status delivery, so `emit` can keep them in order. Touched only on `queue`.
    var statusDeliveryTask: Task<Void, Never>?

    enum VideoFrameSource {
        case native
        case enhanced
    }

    let queue = DispatchQueue(label: "io.opencg.opennow.recording.writer")
    let frameLock = NSLock()
    let firstFrameTimeout: DispatchTimeInterval
    let maxQueuedEnhancedVideoFrames = 4
    var writer: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    var audioInput: AVAssetWriterInput?
    var configuration: StreamRecordingConfiguration?
    var id = UUID()
    var outputURL: URL?
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

    func start(configuration: StreamRecordingConfiguration) {
        queue.async {
            guard self.configuration == nil, self.writer == nil else { return }
            do {
                let directory = try StreamRecordingLibrary.ensureDirectory(forGameTitle: configuration.title)
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

enum StreamRecorderError: LocalizedError {
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

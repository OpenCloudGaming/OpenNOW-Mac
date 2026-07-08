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
    var onStatusChanged: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?

    private enum VideoFrameSource {
        case native
        case enhanced
    }

    private let queue = DispatchQueue(label: "io.opencg.opennow.recording.writer")
    private let conversionQueue = DispatchQueue(label: "io.opencg.opennow.recording.conversion", qos: .userInitiated)
    private let frameLock = NSLock()
    private let firstFrameTimeout: DispatchTimeInterval
    private let maxQueuedEnhancedVideoFrames = 4
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var configuration: WebRTCStreamRecordingConfiguration?
    private var id = UUID()
    private var outputURL: URL?
    private let i420BGRAConverter = WebRTCI420BGRAConverter()
    private var i420PixelBufferPool: CVPixelBufferPool?
    private var i420PixelBufferPoolWidth = 0
    private var i420PixelBufferPoolHeight = 0
    private var createdAt = Date()
    private var startedAt: Date?
    private var firstHostTime: CFTimeInterval?
    private var lastPresentationTime = CMTime.zero
    private var lastStatusHostTime: CFTimeInterval = 0
    private var capturedVideoFrame = false
    private var recordingWidth = 0
    private var recordingHeight = 0
    private var finishing = false
    private var failed = false
    private var activeRecordingId: UUID?
    private var enhancedVideoPreferred = false
    private var selectedVideoFrameSource: VideoFrameSource?
    private var pendingNativeVideoRecordingId: UUID?
    private var pendingEnhancedVideoFrameCount = 0

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
            let frame = Unmanaged<RTCVideoFrame>.fromOpaque(UnsafeRawPointer(bitPattern: retainedFrame)!).takeRetainedValue()
            let i420Frame = frame.newI420()
            guard let i420 = i420Frame.buffer as? RTCI420Buffer,
                  let pixelBuffer = self.newBGRAFramebuffer(from: i420) else {
                self.finishVideoFrameAppend(recordingId: recordingId, source: .native)
                return
            }
            let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
            self.queue.async {
                defer { self.finishVideoFrameAppend(recordingId: recordingId, source: .native) }
                let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(bitPattern: retainedPixelBuffer)!).takeRetainedValue()
                guard self.isActiveRecording(recordingId) else { return }
                self.appendPixelBufferOnQueue(pixelBuffer, source: .native, captureHostTime: captureHostTime)
            }
        }
    }

    func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let recordingId = beginVideoFrameAppend(source: .enhanced) else { return }
        appendPixelBuffer(pixelBuffer, recordingId: recordingId, source: .enhanced, captureHostTime: CACurrentMediaTime())
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

    private func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, recordingId: UUID, source: VideoFrameSource, captureHostTime: CFTimeInterval) {
        let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        queue.async {
            defer { self.finishVideoFrameAppend(recordingId: recordingId, source: source) }
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(bitPattern: retainedPixelBuffer)!).takeRetainedValue()
            guard self.isActiveRecording(recordingId) else { return }
            self.appendPixelBufferOnQueue(pixelBuffer, source: source, captureHostTime: captureHostTime)
        }
    }

    private func appendPixelBufferOnQueue(_ pixelBuffer: CVPixelBuffer, source: VideoFrameSource, captureHostTime: CFTimeInterval) {
        guard isRecording,
              selectVideoFrameSourceIfNeeded(source),
              let configuration,
              let outputURL,
              prepareWriterIfNeeded(pixelBuffer: pixelBuffer, configuration: configuration, outputURL: outputURL),
              let writer,
              let input = videoInput,
              let adaptor = pixelBufferAdaptor else { return }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                fail(writer.error)
                return
            }
            writer.startSession(atSourceTime: .zero)
        }
        guard input.isReadyForMoreMediaData else { return }
        if !capturedVideoFrame {
            capturedVideoFrame = true
            startedAt = Date()
            firstHostTime = captureHostTime
            emit(.recording(startedAt: startedAt ?? createdAt, elapsedSeconds: 0))
        }
        guard let time = presentationTime(hostTime: captureHostTime) else { return }
        let normalizedTime = CMTimeSubtract(time, firstPresentationTime)
        guard adaptor.append(pixelBuffer, withPresentationTime: normalizedTime) else {
            fail(writer.error)
            return
        }
        lastPresentationTime = normalizedTime
        emitElapsedIfNeeded()
    }

    private var firstPresentationTime: CMTime { .zero }

    private func presentationTime(hostTime: CFTimeInterval = CACurrentMediaTime()) -> CMTime? {
        if firstHostTime == nil {
            firstHostTime = hostTime
            startedAt = Date()
            emit(.recording(startedAt: startedAt ?? createdAt, elapsedSeconds: 0))
        }
        guard let firstHostTime else { return nil }
        return CMTime(seconds: max(0, hostTime - firstHostTime), preferredTimescale: 600)
    }

    private func finish() {
        guard writer != nil || configuration != nil else { return }
        guard !finishing else { return }
        finishing = true
        emit(.finishing)
        guard let writer else {
            reset()
            emit(.failed(Self.message(for: WebRTCStreamRecorderError.noFramesCaptured)))
            return
        }
        switch writer.status {
        case .unknown:
            writer.cancelWriting()
            reset()
            emit(.failed(Self.message(for: WebRTCStreamRecorderError.noFramesCaptured)))
        case .writing:
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { self.finishCompletedRecording() }
            }
        case .completed:
            finishCompletedRecording()
        case .failed, .cancelled:
            finishCompletedRecording()
        @unknown default:
            writer.cancelWriting()
            reset()
            emit(.failed(Self.message(for: writer.error)))
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
            durationSeconds: completedRecordingDurationSeconds(),
            width: recordingWidth > 0 ? recordingWidth : configuration.width,
            height: recordingHeight > 0 ? recordingHeight : configuration.height,
            videoBitrateMbps: configuration.videoBitrateMbps,
            audioBitrateKbps: configuration.audioBitrateKbps,
            enhancedVideo: configuration.enhancedVideoEnabled,
            fileName: outputURL.lastPathComponent,
            fileSizeBytes: fileSize,
            storageDirectoryPath: outputURL.deletingLastPathComponent().path
        )
        do {
            let data = try JSONEncoder.recordingEncoder.encode(recording)
            try data.write(to: recording.metadataURL, options: .atomic)
            emit(.finished(recording))
        } catch {
            emit(.failed(Self.message(for: error)))
        }
    }

    private func completedRecordingDurationSeconds() -> Double {
        let presentationDuration = max(0, lastPresentationTime.seconds)
        guard presentationDuration == 0, capturedVideoFrame, let startedAt else { return presentationDuration }
        return max(0, Date().timeIntervalSince(startedAt))
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
        recordingWidth = 0
        recordingHeight = 0
        startedAt = nil
        firstHostTime = nil
        capturedVideoFrame = false
        finishing = false
        failed = false
        setActiveRecordingId(nil, enhancedVideoPreferred: false)
    }

    private func setActiveRecordingId(_ recordingId: UUID?, enhancedVideoPreferred: Bool) {
        frameLock.withLock {
            activeRecordingId = recordingId
            self.enhancedVideoPreferred = enhancedVideoPreferred
            selectedVideoFrameSource = nil
            pendingNativeVideoRecordingId = nil
            pendingEnhancedVideoFrameCount = 0
        }
    }

    private func beginVideoFrameAppend(source: VideoFrameSource) -> UUID? {
        frameLock.withLock {
            guard let activeRecordingId else { return nil }
            switch source {
            case .native:
                guard selectedVideoFrameSource != .enhanced, pendingNativeVideoRecordingId == nil else { return nil }
                pendingNativeVideoRecordingId = activeRecordingId
            case .enhanced:
                guard enhancedVideoPreferred, selectedVideoFrameSource != .native else { return nil }
                guard pendingEnhancedVideoFrameCount < maxQueuedEnhancedVideoFrames else { return nil }
                pendingEnhancedVideoFrameCount += 1
            }
            return activeRecordingId
        }
    }

    private func finishVideoFrameAppend(recordingId: UUID, source: VideoFrameSource) {
        frameLock.withLock {
            switch source {
            case .native:
                if pendingNativeVideoRecordingId == recordingId { pendingNativeVideoRecordingId = nil }
            case .enhanced:
                if pendingEnhancedVideoFrameCount > 0 { pendingEnhancedVideoFrameCount -= 1 }
            }
        }
    }

    private func isActiveRecording(_ recordingId: UUID) -> Bool {
        frameLock.withLock { activeRecordingId == recordingId }
    }

    private func selectVideoFrameSourceIfNeeded(_ source: VideoFrameSource) -> Bool {
        frameLock.withLock {
            if let selectedVideoFrameSource {
                return selectedVideoFrameSource == source
            }
            selectedVideoFrameSource = source
            return true
        }
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

    private func videoSettings(configuration: WebRTCStreamRecordingConfiguration, width: Int, height: Int) -> [String: Any] {
        let bitrate = configuration.videoBitrateMbps > 0 ? configuration.videoBitrateMbps * 1_000_000 : max(4_000_000, width * height * configuration.fps / 8)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.fps,
                AVVideoMaxKeyFrameIntervalKey: configuration.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    private func prepareWriterIfNeeded(pixelBuffer: CVPixelBuffer, configuration: WebRTCStreamRecordingConfiguration, outputURL: URL) -> Bool {
        if writer != nil { return true }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(configuration: configuration, width: width, height: height))
            videoInput.expectsMediaDataInRealTime = true
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
            guard writer.canAdd(videoInput) else { throw WebRTCStreamRecorderError.unableToAddVideoInput }
            writer.add(videoInput)

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(configuration: configuration))
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput); self.audioInput = audioInput } else { self.audioInput = nil }

            self.writer = writer
            self.videoInput = videoInput
            self.pixelBufferAdaptor = adaptor
            self.recordingWidth = width
            self.recordingHeight = height
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func audioSettings(configuration: WebRTCStreamRecordingConfiguration) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: configuration.audioBitrateKbps * 1_000,
        ]
    }

    private func newBGRAFramebuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0 else { return nil }
        let pool = i420BGRAFramebufferPool(width: width, height: height)
        var pixelBuffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        return i420BGRAConverter.copy(i420, toBGRAOutput: pixelBuffer) ? pixelBuffer : nil
    }

    private func scheduleFirstFrameTimeout(recordingId: UUID) {
        queue.asyncAfter(deadline: .now() + firstFrameTimeout) {
            guard self.configuration != nil,
                  self.id == recordingId,
                  !self.capturedVideoFrame,
                  !self.finishing,
                  !self.failed else { return }
            self.fail(WebRTCStreamRecorderError.videoFramesUnavailable)
        }
    }

    private static func isWritableBGRA(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
    }

    private func i420BGRAFramebufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if i420PixelBufferPool != nil, i420PixelBufferPoolWidth == width, i420PixelBufferPoolHeight == height {
            return i420PixelBufferPool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        i420PixelBufferPool = pool
        i420PixelBufferPoolWidth = width
        i420PixelBufferPoolHeight = height
        return pool
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

private extension OSStatus {
    func flatMapStatus(_ next: () -> OSStatus) -> OSStatus {
        self == noErr ? next() : self
    }
}

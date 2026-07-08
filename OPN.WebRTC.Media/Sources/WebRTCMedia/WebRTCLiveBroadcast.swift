import AudioToolbox
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import Security
import VideoToolbox
@preconcurrency import WebRTC

public struct WebRTCLiveBroadcastConfiguration: Equatable, Sendable {
    public let title: String
    public let applicationID: String
    public let rtmpURL: String
    public let streamKey: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let videoBitrateKbps: Int
    public let audioBitrateKbps: Int
    public let enhancedVideoEnabled: Bool

    public init(title: String,
                applicationID: String,
                rtmpURL: String,
                streamKey: String,
                width: Int,
                height: Int,
                fps: Int,
                videoBitrateKbps: Int,
                audioBitrateKbps: Int,
                enhancedVideoEnabled: Bool) {
        self.title = title.isEmpty ? "GeForce NOW Stream" : title
        self.applicationID = applicationID
        self.rtmpURL = rtmpURL
        self.streamKey = streamKey
        self.width = max(1, width)
        self.height = max(1, height)
        self.fps = max(1, fps)
        self.videoBitrateKbps = max(500, videoBitrateKbps)
        self.audioBitrateKbps = min(max(audioBitrateKbps, 64), 320)
        self.enhancedVideoEnabled = enhancedVideoEnabled
    }
}

public enum WebRTCLiveBroadcastStatus: Equatable, Sendable {
    case idle
    case connecting
    case publishing(startedAt: Date, elapsedSeconds: Double, droppedFrames: Int, videoBitrateKbps: Int)
    case live(startedAt: Date, elapsedSeconds: Double, droppedFrames: Int, videoBitrateKbps: Int)
    case stopping
    case failed(String)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    public var isBroadcasting: Bool {
        switch self {
        case .connecting, .publishing, .live, .stopping: return true
        case .idle, .failed: return false
        }
    }

    public var isTerminal: Bool {
        if case .failed = self { return true }
        return false
    }
}

public final class WebRTCLiveBroadcastController: @unchecked Sendable {
    public static let shared = WebRTCLiveBroadcastController()

    public var onStatusChanged: (@MainActor @Sendable (WebRTCLiveBroadcastStatus) -> Void)?
    public private(set) var status = WebRTCLiveBroadcastStatus.idle

    private let session = WebRTCLiveBroadcastSession()
    private let statusObserverLock = NSLock()
    private var statusObservers: [UUID: @MainActor @Sendable (WebRTCLiveBroadcastStatus) -> Void] = [:]

    public init() {
        session.onStatusChanged = { [weak self] status in
            self?.handleStatusChanged(status)
        }
    }

    @discardableResult
    public func addStatusObserver(_ observer: @escaping @MainActor @Sendable (WebRTCLiveBroadcastStatus) -> Void) -> UUID {
        let id = UUID()
        statusObserverLock.lock()
        statusObservers[id] = observer
        let status = status
        statusObserverLock.unlock()
        Task { @MainActor in observer(status) }
        return id
    }

    public func removeStatusObserver(_ id: UUID) {
        statusObserverLock.lock()
        statusObservers[id] = nil
        statusObserverLock.unlock()
    }

    public func start(configuration: WebRTCLiveBroadcastConfiguration) {
        session.start(configuration: configuration)
    }

    public func stop() {
        session.stop()
    }

    public var wantsEnhancedVideo: Bool {
        session.wantsEnhancedVideo
    }

    public func resumeUICapture() {
        session.resumeUICapture()
    }

    func appendVideoFrame(_ frame: RTCVideoFrame) {
        session.appendVideoFrame(frame)
    }

    func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        session.appendEnhancedPixelBuffer(pixelBuffer)
    }

    func appendGameAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        session.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
    }

    func appendMicrophoneAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        session.appendMicrophoneAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
    }

    @MainActor
    private func handleStatusChanged(_ status: WebRTCLiveBroadcastStatus) {
        statusObserverLock.lock()
        self.status = status
        let observers = Array(statusObservers.values)
        statusObserverLock.unlock()
        onStatusChanged?(status)
        for observer in observers {
            observer(status)
        }
    }
}

final class WebRTCLiveBroadcastSession: @unchecked Sendable {
    var onStatusChanged: (@MainActor @Sendable (WebRTCLiveBroadcastStatus) -> Void)?

    private let queue = DispatchQueue(label: "io.opencg.opennow.twitch.broadcast")
    private let conversionQueue = DispatchQueue(label: "io.opencg.opennow.twitch.broadcast.conversion", qos: .userInitiated)
    private let encoder = WebRTCH264LiveEncoder()
    private let audioEncoder = WebRTCAACLiveEncoder()
    private var publisher: RTMPPublisher?
    private var connectionTask: Task<Void, Never>?
    private var configuration: WebRTCLiveBroadcastConfiguration?
    private var startedAt: Date?
    private var firstFrameHostTime: CFTimeInterval?
    private var frameIndex: Int64 = 0
    private var audioSampleIndex: UInt64 = 0
    private var droppedFrames = 0
    private var lastStatusHostTime: CFTimeInterval = 0
    private var lastTelemetryStatusName = ""
    private var isStopping = false
    private var receivedGameVideoFrame = false
    private var uiCapture: WebRTCWindowBroadcastCapture?
    private var microphoneStereoSamples: [Int16] = []
    private let i420BGRAConverter = WebRTCI420BGRAConverter()
    private var i420PixelBufferPool: CVPixelBufferPool?
    private var i420PixelBufferPoolWidth = 0
    private var i420PixelBufferPoolHeight = 0

    var wantsEnhancedVideo: Bool { configuration?.enhancedVideoEnabled == true && isActive }

    var isActive: Bool {
        configuration != nil && !isStopping
    }

    func start(configuration: WebRTCLiveBroadcastConfiguration) {
        queue.async { [self] in
            guard self.configuration == nil else { return }
            self.configuration = configuration
            self.startedAt = Date()
            self.firstFrameHostTime = nil
            self.frameIndex = 0
            self.audioSampleIndex = 0
            self.droppedFrames = 0
            self.lastStatusHostTime = 0
            self.lastTelemetryStatusName = ""
            self.isStopping = false
            self.receivedGameVideoFrame = false
            self.uiCapture = nil
            self.microphoneStereoSamples.removeAll(keepingCapacity: true)
            self.audioEncoder.reset(bitrateKbps: configuration.audioBitrateKbps)
            self.emit(.connecting)
            let task = Task { [weak self] in
                guard let self else { return }
                await self.openPublisher(configuration: configuration)
            }
            self.connectionTask = task
        }
    }

    func stop() {
        queue.async {
            guard self.configuration != nil else { return }
            self.isStopping = true
            self.emit(.stopping)
            self.connectionTask?.cancel()
            self.connectionTask = nil
            let publisher = self.publisher
            self.publisher = nil
            self.encoder.invalidate()
            self.audioEncoder.reset(bitrateKbps: 160)
            self.stopUICapture()
            self.reset()
            self.emit(.idle)
            Task { await publisher?.close() }
        }
    }

    func appendVideoFrame(_ frame: RTCVideoFrame) {
        guard isActive else { return }
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(buffer.pixelBuffer).toOpaque())
            appendGamePixelBuffer(retainedPixelBuffer)
            return
        }
        let retainedFrame = UInt(bitPattern: Unmanaged.passRetained(frame).toOpaque())
        conversionQueue.async {
            let frame = Unmanaged<RTCVideoFrame>.fromOpaque(UnsafeRawPointer(bitPattern: retainedFrame)!).takeRetainedValue()
            let i420Frame = frame.newI420()
            guard let i420 = i420Frame.buffer as? RTCI420Buffer,
                  let pixelBuffer = self.newBGRAFramebuffer(from: i420) else { return }
            let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
            self.appendGamePixelBuffer(retainedPixelBuffer)
        }
    }

    func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        appendGamePixelBuffer(retainedPixelBuffer)
    }

    private func appendGamePixelBuffer(_ retainedPixelBuffer: UInt) {
        queue.async {
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(bitPattern: retainedPixelBuffer)!).takeRetainedValue()
            if !self.receivedGameVideoFrame {
                self.receivedGameVideoFrame = true
                self.stopUICapture()
            }
            self.appendPixelBufferOnQueue(pixelBuffer)
        }
    }

    private func appendUICapturePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        queue.async {
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(bitPattern: retainedPixelBuffer)!).takeRetainedValue()
            guard !self.receivedGameVideoFrame else { return }
            self.appendPixelBufferOnQueue(pixelBuffer)
        }
    }

    func appendGameAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList,
              let copied = Self.stereoPCM(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), frameCount: frameCount, channels: channels) else { return }
        let normalized = Self.resampledStereoPCM(copied, sourceSampleRate: sampleRate, targetSampleRate: 48_000)
        queue.async {
            guard let publisher = self.publisher, !self.isStopping else { return }
            if self.audioSampleIndex == 0, let firstFrameHostTime = self.firstFrameHostTime {
                let elapsedSeconds = max(0, CACurrentMediaTime() - firstFrameHostTime)
                self.audioSampleIndex = UInt64((elapsedSeconds * 48_000).rounded())
            }
            let mixed = self.mixWithMicrophone(gameStereoSamples: normalized)
            self.publishAudio(stereoSamples: mixed, publisher: publisher)
        }
    }

    func appendMicrophoneAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList,
              let copied = Self.stereoPCM(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), frameCount: frameCount, channels: channels) else { return }
        let normalized = Self.resampledStereoPCM(copied, sourceSampleRate: sampleRate, targetSampleRate: 48_000)
        queue.async {
            guard self.configuration != nil, !self.isStopping else { return }
            self.microphoneStereoSamples.append(contentsOf: normalized)
            let maximumBufferedSamples = 48_000 * 2
            if self.microphoneStereoSamples.count > maximumBufferedSamples {
                self.microphoneStereoSamples.removeFirst(self.microphoneStereoSamples.count - maximumBufferedSamples)
            }
        }
    }

    private func openPublisher(configuration: WebRTCLiveBroadcastConfiguration) async {
        do {
            try Task.checkCancellation()
            let publisher = try RTMPPublisher(rtmpURL: configuration.rtmpURL, streamKey: configuration.streamKey)
            let shouldConnect = await withCheckedContinuation { continuation in
                queue.async {
                    guard self.configuration == configuration, !self.isStopping, !Task.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.publisher = publisher
                    continuation.resume(returning: true)
                }
            }
            guard shouldConnect else {
                await publisher.close()
                return
            }
            WebRTCMediaTelemetry.capture("webrtc.broadcast.rtmp.connect", level: .info, message: "Connecting Twitch RTMP publisher.", attributes: ["applicationID": configuration.applicationID])
            try await publisher.connect()
            queue.async {
                guard self.configuration == configuration, !self.isStopping else {
                    Task { await publisher.close() }
                    return
                }
                self.connectionTask = nil
                self.startUICaptureIfNeeded()
                WebRTCMediaTelemetry.capture("webrtc.broadcast.rtmp.connected", level: .info, message: "Twitch RTMP publisher connected.", attributes: ["applicationID": configuration.applicationID])
                self.emit(.publishing(startedAt: self.startedAt ?? Date(), elapsedSeconds: 0, droppedFrames: 0, videoBitrateKbps: configuration.videoBitrateKbps))
            }
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            queue.async { [weak self] in
                guard let self, !wasCancelled else { return }
                self.connectionTask = nil
                self.fail(error)
            }
        }
    }

    private func appendPixelBufferOnQueue(_ pixelBuffer: CVPixelBuffer) {
        guard let configuration, let publisher, !isStopping else { return }
        if firstFrameHostTime == nil { firstFrameHostTime = CACurrentMediaTime() }
        guard let firstFrameHostTime else { return }
        let timestamp = CMTime(seconds: max(0, CACurrentMediaTime() - firstFrameHostTime), preferredTimescale: 1_000)
        do {
            let width = max(2, configuration.width)
            let height = max(2, configuration.height)
            let outputPixelBuffer = try targetPixelBuffer(from: pixelBuffer, width: width, height: height)
            let dimensionsChanged = encoder.isConfigured && (encoder.configuredWidth != width || encoder.configuredHeight != height)
            if !encoder.isConfigured || dimensionsChanged {
                try encoder.configure(width: width, height: height, fps: configuration.fps, bitrateKbps: configuration.videoBitrateKbps)
            }
            let frameIndex = self.frameIndex
            self.frameIndex += 1
            let callbackQueue = queue
            try encoder.encode(pixelBuffer: outputPixelBuffer, presentationTime: timestamp, forceKeyframe: frameIndex == 0 || dimensionsChanged) { [self] packet in
                Task { [self, publisher, callbackQueue] in
                    do {
                        try await publisher.publishVideo(packet)
                    } catch {
                        callbackQueue.async { [self, publisher] in
                            guard self.publisher === publisher else { return }
                            self.fail(error)
                        }
                    }
                }
            }
            emitElapsedIfNeeded(configuration: configuration)
        } catch {
            droppedFrames += 1
            fail(error)
        }
    }

    private func emitElapsedIfNeeded(configuration: WebRTCLiveBroadcastConfiguration) {
        let now = CACurrentMediaTime()
        guard now - lastStatusHostTime >= 1 else { return }
        lastStatusHostTime = now
        emit(.publishing(startedAt: startedAt ?? Date(), elapsedSeconds: max(0, now - (firstFrameHostTime ?? now)), droppedFrames: droppedFrames, videoBitrateKbps: configuration.videoBitrateKbps))
    }

    private func fail(_ error: Error) {
        let publisher = publisher
        let applicationID = configuration?.applicationID ?? ""
        connectionTask?.cancel()
        connectionTask = nil
        self.publisher = nil
        encoder.invalidate()
        audioEncoder.reset(bitrateKbps: 160)
        stopUICapture()
        reset()
        Task { await publisher?.close() }
        WebRTCMediaTelemetry.capture("webrtc.broadcast.rtmp.failed", level: .error, message: Self.message(for: error), attributes: ["applicationID": applicationID])
        emit(.failed(Self.message(for: error)))
    }

    private func targetPixelBuffer(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        if CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height { return pixelBuffer }
        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess, let output else {
            throw BroadcastError.encoder("Unable to allocate broadcast frame buffer.")
        }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = source.extent
        let scale = max(CGFloat(width) / max(sourceExtent.width, 1), CGFloat(height) / max(sourceExtent.height, 1))
        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let transform = CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: ((CGFloat(width) - scaledWidth) / 2) / scale, y: ((CGFloat(height) - scaledHeight) / 2) / scale)
        let image = source.transformed(by: transform)
        Self.ciContext.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    private func reset() {
        configuration = nil
        startedAt = nil
        firstFrameHostTime = nil
        frameIndex = 0
        audioSampleIndex = 0
        isStopping = false
        receivedGameVideoFrame = false
        droppedFrames = 0
        uiCapture = nil
        microphoneStereoSamples.removeAll(keepingCapacity: true)
    }

    private func startUICaptureIfNeeded() {
        guard uiCapture == nil, !receivedGameVideoFrame else { return }
        let capture = WebRTCWindowBroadcastCapture { [weak self] pixelBuffer in
            self?.appendUICapturePixelBuffer(pixelBuffer)
        }
        uiCapture = capture
        Task { [weak self, capture] in
            do {
                try await capture.start()
            } catch {
                guard let self else { return }
                self.queue.async { [self, capture] in
                    WebRTCMediaTelemetry.capture("webrtc.broadcast.ui_capture.unavailable", level: .warning, message: Self.message(for: error))
                    if self.uiCapture === capture { self.uiCapture = nil }
                }
            }
        }
    }

    private func stopUICapture() {
        let capture = uiCapture
        uiCapture = nil
        Task { await capture?.stop() }
    }

    func resumeUICapture() {
        queue.async {
            guard self.configuration != nil, self.publisher != nil, !self.isStopping else { return }
            self.receivedGameVideoFrame = false
            self.startUICaptureIfNeeded()
        }
    }

    private func mixWithMicrophone(gameStereoSamples: [Int16]) -> [Int16] {
        guard !microphoneStereoSamples.isEmpty else { return gameStereoSamples }
        var mixed = gameStereoSamples
        let count = min(mixed.count, microphoneStereoSamples.count)
        for index in 0..<count {
            let sample = Int(mixed[index]) + Int(microphoneStereoSamples[index])
            mixed[index] = Int16(max(Int(Int16.min), min(Int(Int16.max), sample)))
        }
        microphoneStereoSamples.removeFirst(count)
        return mixed
    }

    private func publishAudio(stereoSamples: [Int16], publisher: RTMPPublisher) {
        guard !stereoSamples.isEmpty else { return }
        do {
            let packets = try audioEncoder.encode(stereoSamples: stereoSamples)
            for packet in packets {
                let timestamp = UInt32(audioSampleIndex * 1_000 / 48_000)
                audioSampleIndex += UInt64(packet.inputFrameCount)
                let callbackQueue = queue
                Task { [self, publisher, packet, timestamp, callbackQueue] in
                    do {
                        try await publisher.publishAudio(packet, timestampMilliseconds: timestamp)
                    } catch {
                        callbackQueue.async { [self, publisher] in
                            guard self.publisher === publisher else { return }
                            self.fail(error)
                        }
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    private static func stereoPCM(from audioBufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32, channels: UInt32) -> [Int16]? {
        let outputFrames = Int(frameCount)
        guard outputFrames > 0 else { return nil }
        let sourceChannels = max(1, Int(channels))
        var samples = [Int16](repeating: 0, count: outputFrames * 2)
        let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)
        withUnsafePointer(to: audioBufferList.pointee.mBuffers) { firstBuffer in
            let buffers = UnsafeBufferPointer(start: firstBuffer, count: bufferCount)
            if bufferCount == 1, let buffer = buffers.first, let data = buffer.mData {
                let sourceSampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard sourceSampleCount >= outputFrames * sourceChannels else { return }
                let source = data.bindMemory(to: Int16.self, capacity: sourceSampleCount)
                for frame in 0..<outputFrames {
                    let sourceIndex = frame * sourceChannels
                    let left = source[sourceIndex]
                    let right = sourceChannels > 1 ? source[sourceIndex + 1] : left
                    samples[frame * 2] = left
                    samples[frame * 2 + 1] = right
                }
            } else {
                let leftSampleCount = buffers.indices.contains(0) ? Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size : 0
                let rightSampleCount = buffers.indices.contains(1) ? Int(buffers[1].mDataByteSize) / MemoryLayout<Int16>.size : 0
                for frame in 0..<outputFrames {
                    let leftBuffer = buffers.indices.contains(0) ? buffers[0].mData : nil
                    let rightBuffer = buffers.indices.contains(1) ? buffers[1].mData : nil
                    let left = frame < leftSampleCount ? leftBuffer?.bindMemory(to: Int16.self, capacity: leftSampleCount)[frame] ?? 0 : 0
                    let right = frame < rightSampleCount ? rightBuffer?.bindMemory(to: Int16.self, capacity: rightSampleCount)[frame] ?? left : left
                    samples[frame * 2] = left
                    samples[frame * 2 + 1] = right
                }
            }
        }
        return samples
    }

    private static func resampledStereoPCM(_ samples: [Int16], sourceSampleRate: Double, targetSampleRate: Double) -> [Int16] {
        guard sourceSampleRate > 0, abs(sourceSampleRate - targetSampleRate) > 0.5 else { return samples }
        let sourceFrames = samples.count / 2
        guard sourceFrames > 1 else { return samples }
        let targetFrames = max(1, Int((Double(sourceFrames) * targetSampleRate / sourceSampleRate).rounded()))
        var output = [Int16](repeating: 0, count: targetFrames * 2)
        for frame in 0..<targetFrames {
            let sourcePosition = Double(frame) * sourceSampleRate / targetSampleRate
            let lower = min(sourceFrames - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(sourceFrames - 1, lower + 1)
            let fraction = sourcePosition - Double(lower)
            for channel in 0..<2 {
                let a = Double(samples[lower * 2 + channel])
                let b = Double(samples[upper * 2 + channel])
                output[frame * 2 + channel] = Int16(max(Double(Int16.min), min(Double(Int16.max), a + ((b - a) * fraction))))
            }
        }
        return output
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private func emit(_ status: WebRTCLiveBroadcastStatus) {
        emitTelemetryIfNeeded(status)
        Task { @MainActor [onStatusChanged] in onStatusChanged?(status) }
    }

    private func emitTelemetryIfNeeded(_ status: WebRTCLiveBroadcastStatus) {
        let name: String
        let message: String
        let level: WebRTCMediaTelemetryLevel
        switch status {
        case .idle:
            name = "idle"
            message = "Twitch broadcast publisher is idle."
            level = .info
        case .connecting:
            name = "connecting"
            message = "Twitch broadcast publisher is connecting."
            level = .info
        case .publishing:
            name = "publishing"
            message = "Twitch broadcast publisher is publishing."
            level = .info
        case .live:
            name = "live"
            message = "Twitch broadcast publisher is live."
            level = .info
        case .stopping:
            name = "stopping"
            message = "Twitch broadcast publisher is stopping."
            level = .info
        case .failed(let error):
            name = "failed"
            message = error.isEmpty ? "Twitch broadcast publisher failed." : error
            level = .error
        }
        guard lastTelemetryStatusName != name else { return }
        lastTelemetryStatusName = name
        WebRTCMediaTelemetry.capture("webrtc.broadcast.status", level: level, message: message, attributes: ["applicationID": configuration?.applicationID ?? "", "status": name])
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

    private func i420BGRAFramebufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if i420PixelBufferPool != nil, i420PixelBufferPoolWidth == width, i420PixelBufferPoolHeight == height { return i420PixelBufferPool }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        i420PixelBufferPool = pool
        i420PixelBufferPoolWidth = width
        i420PixelBufferPoolHeight = height
        return pool
    }

    fileprivate static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Twitch broadcast failed." : error.localizedDescription
    }
}

private final class WebRTCWindowBroadcastCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.opencg.opennow.twitch.broadcast.ui-capture", qos: .userInitiated)
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private var stream: SCStream?

    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let candidateWindows = content.windows.filter { window in
            window.owningApplication?.processID == processID && window.frame.width >= 64 && window.frame.height >= 64
        }
        guard let window = candidateWindows.max(by: { lhs, rhs in lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height }) else {
            throw BroadcastError.capture("OpenNOW window is not available for broadcast capture.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Self.evenDimension(window.frame.width)
        configuration.height = Self.evenDimension(window.frame.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        WebRTCMediaTelemetry.capture("webrtc.broadcast.ui_capture.stop", level: .warning, message: WebRTCLiveBroadcastSession.message(for: error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame(pixelBuffer)
    }

    private static func evenDimension(_ value: CGFloat) -> Int {
        let rounded = max(64, Int(value.rounded()))
        return rounded - rounded % 2
    }
}

struct WebRTCH264Packet: Sendable {
    let isKeyframe: Bool
    let timestampMilliseconds: UInt32
    let sps: Data?
    let pps: Data?
    let nalUnits: [Data]
}

struct WebRTCAACPacket: Sendable {
    let data: Data
    let inputFrameCount: Int
    let includesSequenceHeader: Bool
}

private final class WebRTCAACInputContext {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    var offset = 0

    init(data: Data) {
        count = data.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: MemoryLayout<UInt8>.alignment)
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
    }

    deinit {
        pointer.deallocate()
    }
}

private let webRTCAACInputCallback: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
    guard let inUserData else { return noErr }
    let context = Unmanaged<WebRTCAACInputContext>.fromOpaque(inUserData).takeUnretainedValue()
    let remaining = context.count - context.offset
    guard remaining > 0 else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }
    let requestedBytes = Int(ioNumberDataPackets.pointee) * 4
    let byteCount = min(remaining, requestedBytes)
    ioData.pointee.mBuffers.mData = context.pointer.advanced(by: context.offset)
    context.offset += byteCount
    ioData.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
    ioData.pointee.mBuffers.mNumberChannels = 2
    ioNumberDataPackets.pointee = UInt32(byteCount / 4)
    return noErr
}

private final class WebRTCAACLiveEncoder: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var pcmBuffer = Data()
    private var bitrateKbps = 160
    private var sentSequenceHeader = false

    func reset(bitrateKbps: Int) {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        pcmBuffer.removeAll(keepingCapacity: true)
        self.bitrateKbps = min(max(bitrateKbps, 64), 320)
        sentSequenceHeader = false
    }

    func encode(stereoSamples: [Int16]) throws -> [WebRTCAACPacket] {
        guard !stereoSamples.isEmpty else { return [] }
        let samples = stereoSamples
        samples.withUnsafeBufferPointer { pcmBuffer.append(Data(buffer: $0)) }
        try configureIfNeeded()
        var packets: [WebRTCAACPacket] = []
        if !sentSequenceHeader {
            packets.append(WebRTCAACPacket(data: Data([0x11, 0x90]), inputFrameCount: 0, includesSequenceHeader: true))
            sentSequenceHeader = true
        }
        let frameByteCount = 1_024 * 2 * MemoryLayout<Int16>.size
        while pcmBuffer.count >= frameByteCount {
            let frameData = pcmBuffer.prefix(frameByteCount)
            pcmBuffer.removeFirst(frameByteCount)
            if let packet = try encodeFrame(Data(frameData)) {
                packets.append(packet)
            }
        }
        return packets
    }

    private func configureIfNeeded() throws {
        guard converter == nil else { return }
        var input = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1_024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var newConverter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &newConverter) == noErr, let newConverter else { throw BroadcastError.audio("Unable to create AAC encoder.") }
        var bitrate = UInt32(bitrateKbps * 1_000)
        AudioConverterSetProperty(newConverter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        converter = newConverter
    }

    private func encodeFrame(_ frameData: Data) throws -> WebRTCAACPacket? {
        guard let converter else { return nil }
        let context = WebRTCAACInputContext(data: frameData)
        let outputBufferSize = 4_096
        let output = UnsafeMutableRawPointer.allocate(byteCount: outputBufferSize, alignment: MemoryLayout<UInt8>.alignment)
        defer { output.deallocate() }
        var outputBuffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outputBufferSize), mData: output))
        var packetCount: UInt32 = 1
        let status = withUnsafeMutablePointer(to: &outputBuffer) { outputBufferPointer in
            AudioConverterFillComplexBuffer(converter, webRTCAACInputCallback, Unmanaged.passUnretained(context).toOpaque(), &packetCount, outputBufferPointer, nil)
        }
        guard status == noErr else { throw BroadcastError.audio("AAC encode failed (\(status)).") }
        guard packetCount > 0, outputBuffer.mBuffers.mDataByteSize > 0 else { return nil }
        return WebRTCAACPacket(data: Data(bytes: output, count: Int(outputBuffer.mBuffers.mDataByteSize)), inputFrameCount: 1_024, includesSequenceHeader: false)
    }
}

private final class WebRTCH264LiveEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private(set) var isConfigured = false
    private(set) var configuredWidth = 0
    private(set) var configuredHeight = 0

    func configure(width: Int, height: Int, fps: Int, bitrateKbps: Int) throws {
        invalidate()
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: Self.outputCallback, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &newSession)
        guard status == noErr, let newSession else { throw BroadcastError.encoder("Unable to create H.264 encoder (\(status)).") }
        session = newSession
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrateKbps * 1_000))
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(1, fps * 2)))
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        isConfigured = true
        configuredWidth = width
        configuredHeight = height
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool, callback: @escaping @Sendable (WebRTCH264Packet) -> Void) throws {
        guard let session else { throw BroadcastError.encoder("H.264 encoder is not configured.") }
        let callbackBox = WebRTCH264FrameCallback(callback)
        let sourceFrameRefcon = Unmanaged.passRetained(callbackBox).toOpaque()
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid, frameProperties: properties, sourceFrameRefcon: sourceFrameRefcon, infoFlagsOut: nil)
        if status != noErr { Unmanaged<WebRTCH264FrameCallback>.fromOpaque(sourceFrameRefcon).release() }
        guard status == noErr else { throw BroadcastError.encoder("H.264 frame encode failed (\(status)).") }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        isConfigured = false
        configuredWidth = 0
        configuredHeight = 0
    }

    private static let outputCallback: VTCompressionOutputCallback = { _, sourceFrameRefcon, status, _, sampleBuffer in
        guard let sourceFrameRefcon else { return }
        let callbackBox = Unmanaged<WebRTCH264FrameCallback>.fromOpaque(sourceFrameRefcon).takeRetainedValue()
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let packet = WebRTCH264LiveEncoder.packet(from: sampleBuffer) else { return }
        callbackBox.callback(packet)
    }

    private static func packet(from sampleBuffer: CMSampleBuffer) -> WebRTCH264Packet? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let timestamp = max(0, UInt32(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000))
        var sps: Data?
        var pps: Data?
        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            sps = parameterSet(description: description, index: 0)
            pps = parameterSet(description: description, index: 1)
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        var offset = 0
        var nalUnits: [Data] = []
        while offset + 4 <= length {
            let bytes = UnsafeRawBufferPointer(start: pointer + offset, count: 4)
            let size = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            offset += 4
            guard size > 0, offset + Int(size) <= length else { break }
            nalUnits.append(Data(bytes: pointer + offset, count: Int(size)))
            offset += Int(size)
        }
        return WebRTCH264Packet(isKeyframe: isKeyframe, timestampMilliseconds: timestamp, sps: sps, pps: pps, nalUnits: nalUnits)
    }

    private static func parameterSet(description: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}

private final class WebRTCH264FrameCallback: @unchecked Sendable {
    let callback: @Sendable (WebRTCH264Packet) -> Void

    init(_ callback: @escaping @Sendable (WebRTCH264Packet) -> Void) {
        self.callback = callback
    }
}

private actor RTMPPublisher {
    private static let outboundChunkSize = 128
    private static let operationTimeoutSeconds: TimeInterval = 12

    private let endpoint: RTMPEndpoint
    private var connection: NWConnection?
    private var streamID: UInt32 = 0
    private var inboundChunkSize = 128
    private var inboundHeaders: [UInt32: RTMPChunkHeader] = [:]

    init(rtmpURL: String, streamKey: String) throws {
        endpoint = try RTMPEndpoint(urlString: rtmpURL, streamKey: streamKey)
    }

    func connect() async throws {
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: endpoint.secure ? .tls : .tcp)
        self.connection = connection
        connection.start(queue: .global(qos: .userInitiated))
        do {
            try Task.checkCancellation()
            try await waitUntilReady(connection)
            try Task.checkCancellation()
            try await performHandshake(connection)
            try Task.checkCancellation()
            try await sendConnectCommand()
            try Task.checkCancellation()
            streamID = try await sendCreateStreamCommand()
            guard streamID > 0 else { throw BroadcastError.rtmp("RTMP server returned an invalid stream ID.") }
            try Task.checkCancellation()
            try await sendPublishCommand()
        } catch {
            close()
            throw error
        }
    }

    func publishVideo(_ packet: WebRTCH264Packet) async throws {
        guard connection != nil else { return }
        if let sps = packet.sps, let pps = packet.pps {
            try await sendMessage(type: 9, streamID: streamID, timestamp: packet.timestampMilliseconds, payload: FLVMuxer.avcSequenceHeader(sps: sps, pps: pps))
        }
        let payload = FLVMuxer.videoPayload(packet: packet)
        guard !payload.isEmpty else { return }
        try await sendMessage(type: 9, streamID: streamID, timestamp: packet.timestampMilliseconds, payload: payload)
    }

    func publishAudio(_ packet: WebRTCAACPacket, timestampMilliseconds: UInt32) async throws {
        guard connection != nil else { return }
        let payload = packet.includesSequenceHeader ? FLVMuxer.aacSequenceHeader(packet.data) : FLVMuxer.aacPayload(packet.data)
        guard !payload.isEmpty else { return }
        try await sendMessage(type: 8, streamID: streamID, timestamp: timestampMilliseconds, payload: payload)
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        let resumeGate = ContinuationResumeGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                try? await Task.sleep(for: .seconds(Self.operationTimeoutSeconds))
                guard resumeGate.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(throwing: BroadcastError.rtmp("RTMP connection timed out."))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeGate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    guard resumeGate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
        }
    }

    private func performHandshake(_ connection: NWConnection) async throws {
        var c1 = Data(count: 1536)
        c1.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 1536, base)
        }
        var c0c1 = Data([3])
        c0c1.append(c1)
        try await send(c0c1)
        let s0s1s2 = try await receiveExact(length: 3073)
        guard s0s1s2.first == 3, s0s1s2.count == 3073 else { throw BroadcastError.rtmp("RTMP handshake failed.") }
        try await send(s0s1s2.subdata(in: 1..<1537))
    }

    private func sendConnectCommand() async throws {
        let payload = AMF0.command("connect", transactionID: 1, objects: [["app": endpoint.app, "type": "nonprivate", "tcUrl": endpoint.tcURL, "flashVer": "FMLE/3.0", "fpad": false, "capabilities": 15, "audioCodecs": 0, "videoCodecs": 128, "videoFunction": 1]])
        try await sendMessage(type: 20, streamID: 0, timestamp: 0, payload: payload)
        _ = try await receiveCommandResult(transactionID: 1)
    }

    private func sendCreateStreamCommand() async throws -> UInt32 {
        let payload = AMF0.command("createStream", transactionID: 2, objects: [nil])
        try await sendMessage(type: 20, streamID: 0, timestamp: 0, payload: payload)
        return try await receiveCommandResult(transactionID: 2)
    }

    private func sendPublishCommand() async throws {
        let payload = AMF0.command("publish", transactionID: 3, objects: [nil, endpoint.playPath, "live"])
        try await sendMessage(type: 20, streamID: streamID, timestamp: 0, payload: payload)
    }

    private func sendMessage(type: UInt8, streamID: UInt32, timestamp: UInt32, payload: Data) async throws {
        var message = Data()
        message.append(0x03)
        message.appendUInt24(min(timestamp, 0x00FF_FFFF))
        message.appendUInt24(UInt32(payload.count))
        message.append(type)
        message.appendUInt32LittleEndian(streamID)
        var offset = 0
        let firstChunkSize = min(Self.outboundChunkSize, payload.count)
        message.append(payload.prefix(firstChunkSize))
        offset += firstChunkSize
        while offset < payload.count {
            message.append(0xC3)
            let chunkSize = min(Self.outboundChunkSize, payload.count - offset)
            message.append(payload[offset..<(offset + chunkSize)])
            offset += chunkSize
        }
        try await send(message)
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw BroadcastError.rtmp("RTMP connection is closed.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receiveExact(length: Int) async throws -> Data {
        guard let connection else { throw BroadcastError.rtmp("RTMP connection is closed.") }
        var output = Data()
        while output.count < length {
            let chunk = try await receiveOnce(connection: connection, minimumLength: 1, maximumLength: length - output.count)
            guard !chunk.isEmpty else { throw BroadcastError.rtmp("RTMP connection closed while receiving data.") }
            output.append(chunk)
        }
        return output
    }

    private func receiveOnce(connection: NWConnection, minimumLength: Int, maximumLength: Int) async throws -> Data {
        let resumeGate = ContinuationResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            Task {
                try? await Task.sleep(for: .seconds(Self.operationTimeoutSeconds))
                guard resumeGate.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: BroadcastError.rtmp("RTMP receive timed out."))
            }
            connection.receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { data, _, _, error in
                guard resumeGate.claim() else { return }
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    private func receiveCommandResult(transactionID: Double) async throws -> UInt32 {
        while true {
            let message = try await receiveMessage()
            guard message.type == 20 || message.type == 17 else { continue }
            if let error = AMF0.commandError(message.payload, transactionID: transactionID) {
                throw BroadcastError.rtmp(error)
            }
            if let streamID = AMF0.resultStreamID(message.payload, transactionID: transactionID) { return streamID }
        }
    }

    private func receiveMessage() async throws -> RTMPMessage {
        let parsedHeader = try await receiveChunkHeader()
        let length = parsedHeader.messageLength
        var payload = Data()
        while payload.count < length {
            let count = min(inboundChunkSize, length - payload.count)
            payload.append(try await receiveExact(length: count))
            if payload.count < length {
                let continuationHeader = try await receiveChunkHeader()
                guard continuationHeader.chunkStreamID == parsedHeader.chunkStreamID else { throw BroadcastError.rtmp("RTMP chunk stream changed mid-message.") }
            }
        }
        if parsedHeader.messageTypeID == 1, payload.count >= 4 {
            inboundChunkSize = max(1, Int(payload.uint32(at: 0)))
            return try await receiveMessage()
        }
        return RTMPMessage(type: parsedHeader.messageTypeID, payload: payload)
    }

    private func receiveChunkHeader() async throws -> RTMPChunkHeader {
        let basicHeader = try await receiveExact(length: 1)[0]
        let format = basicHeader >> 6
        let chunkStreamID = UInt32(basicHeader & 0x3F)
        guard chunkStreamID >= 2 else { throw BroadcastError.rtmp("Unsupported RTMP chunk stream ID.") }
        let previous = inboundHeaders[chunkStreamID]
        let header: RTMPChunkHeader
        switch format {
        case 0:
            let data = try await receiveExact(length: 11)
            header = RTMPChunkHeader(
                chunkStreamID: chunkStreamID,
                timestamp: data.uint24(at: 0),
                messageLength: Int(data.uint24(at: 3)),
                messageTypeID: data[6],
                messageStreamID: data.uint32LittleEndian(at: 7)
            )
        case 1:
            guard let previous else { throw BroadcastError.rtmp("RTMP chunk format 1 missing previous header.") }
            let data = try await receiveExact(length: 7)
            header = RTMPChunkHeader(
                chunkStreamID: chunkStreamID,
                timestamp: previous.timestamp + data.uint24(at: 0),
                messageLength: Int(data.uint24(at: 3)),
                messageTypeID: data[6],
                messageStreamID: previous.messageStreamID
            )
        case 2:
            guard let previous else { throw BroadcastError.rtmp("RTMP chunk format 2 missing previous header.") }
            let data = try await receiveExact(length: 3)
            header = RTMPChunkHeader(
                chunkStreamID: chunkStreamID,
                timestamp: previous.timestamp + data.uint24(at: 0),
                messageLength: previous.messageLength,
                messageTypeID: previous.messageTypeID,
                messageStreamID: previous.messageStreamID
            )
        case 3:
            guard let previous else { throw BroadcastError.rtmp("RTMP chunk format 3 missing previous header.") }
            header = previous
        default:
            throw BroadcastError.rtmp("Unsupported RTMP response chunk format.")
        }
        inboundHeaders[chunkStreamID] = header
        return header
    }
}

private struct RTMPMessage {
    let type: UInt8
    let payload: Data
}

private struct RTMPChunkHeader {
    let chunkStreamID: UInt32
    let timestamp: UInt32
    let messageLength: Int
    let messageTypeID: UInt8
    let messageStreamID: UInt32
}

private final class ContinuationResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private struct RTMPEndpoint: Sendable {
    let secure: Bool
    let host: String
    let port: UInt16
    let app: String
    let playPath: String
    let tcURL: String

    init(urlString: String, streamKey: String) throws {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host else { throw BroadcastError.rtmp("Invalid RTMP URL.") }
        secure = scheme == "rtmps"
        self.host = host
        port = UInt16(url.port ?? (secure ? 443 : 1935))
        let trimmedKey = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponents = url.path.split(separator: "/").map(String.init)
        if pathComponents.count >= 2 {
            app = pathComponents.dropLast().joined(separator: "/")
            let urlPlayPath = pathComponents.last ?? trimmedKey
            playPath = trimmedKey.isEmpty ? Self.playPath(urlPlayPath, query: url.query) : Self.playPath(trimmedKey, query: url.query)
        } else {
            app = pathComponents.first ?? "app"
            playPath = Self.playPath(trimmedKey, query: url.query)
        }
        tcURL = "\(scheme)://\(host)/\(app)"
    }

    private static func playPath(_ streamKey: String, query: String?) -> String {
        guard let query, !query.isEmpty, !streamKey.contains("?") else { return streamKey }
        return "\(streamKey)?\(query)"
    }
}

private enum FLVMuxer {
    private static let aacSoundHeader = UInt8(10 << 4 | 3 << 2 | 1 << 1 | 1)

    static func avcSequenceHeader(sps: Data, pps: Data) -> Data {
        var data = videoHeader(keyframe: true, avcPacketType: 0, compositionTime: 0)
        data.append(1)
        data.append(sps.dropFirst().prefix(3))
        data.append(0xFF)
        data.append(0xE1)
        data.appendUInt16(UInt16(sps.count))
        data.append(sps)
        data.append(1)
        data.appendUInt16(UInt16(pps.count))
        data.append(pps)
        return data
    }

    static func videoPayload(packet: WebRTCH264Packet) -> Data {
        var data = videoHeader(keyframe: packet.isKeyframe, avcPacketType: 1, compositionTime: 0)
        for nal in packet.nalUnits {
            data.appendUInt32(UInt32(nal.count))
            data.append(nal)
        }
        return data
    }

    static func aacSequenceHeader(_ audioSpecificConfig: Data) -> Data {
        var data = Data([aacSoundHeader, 0])
        data.append(audioSpecificConfig)
        return data
    }

    static func aacPayload(_ packet: Data) -> Data {
        var data = Data([aacSoundHeader, 1])
        data.append(packet)
        return data
    }

    private static func videoHeader(keyframe: Bool, avcPacketType: UInt8, compositionTime: UInt32) -> Data {
        var data = Data()
        data.append((keyframe ? 1 : 2) << 4 | 7)
        data.append(avcPacketType)
        data.appendUInt24(compositionTime)
        return data
    }
}

private enum AMF0 {
    static func command(_ name: String, transactionID: Double, objects: [Any?]) -> Data {
        var data = Data()
        data.appendString(name)
        data.appendNumber(transactionID)
        for object in objects { data.appendAMF0(object) }
        return data
    }

    static func resultStreamID(_ payload: Data, transactionID: Double) -> UInt32? {
        var offset = 0
        guard readString(payload, offset: &offset) == "_result" else { return nil }
        guard let responseTransactionID = readNumber(payload, offset: &offset), responseTransactionID == transactionID else { return nil }
        skipValue(payload, offset: &offset)
        guard let streamID = readNumber(payload, offset: &offset), streamID > 0 else { return transactionID == 1 ? 1 : nil }
        return UInt32(streamID.rounded())
    }

    static func commandError(_ payload: Data, transactionID: Double) -> String? {
        var offset = 0
        guard readString(payload, offset: &offset) == "_error" else { return nil }
        guard let responseTransactionID = readNumber(payload, offset: &offset), responseTransactionID == transactionID else { return nil }
        skipValue(payload, offset: &offset)
        return readObjectDescription(payload, offset: &offset) ?? "Twitch RTMP server rejected the command."
    }

    private static func readString(_ data: Data, offset: inout Int) -> String? {
        guard offset < data.count, data[offset] == 0x02 else { return nil }
        offset += 1
        guard offset + 2 <= data.count else { return nil }
        let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
        offset += 2
        guard offset + length <= data.count else { return nil }
        defer { offset += length }
        return String(data: data[offset..<(offset + length)], encoding: .utf8)
    }

    private static func readNumber(_ data: Data, offset: inout Int) -> Double? {
        guard offset < data.count, data[offset] == 0x00 else { return nil }
        offset += 1
        guard offset + 8 <= data.count else { return nil }
        var bits: UInt64 = 0
        for byte in data[offset..<(offset + 8)] { bits = (bits << 8) | UInt64(byte) }
        offset += 8
        return Double(bitPattern: bits)
    }

    private static func skipValue(_ data: Data, offset: inout Int) {
        guard offset < data.count else { return }
        switch data[offset] {
        case 0x00:
            offset = min(data.count, offset + 9)
        case 0x01:
            offset = min(data.count, offset + 2)
        case 0x02:
            _ = readString(data, offset: &offset)
        case 0x03:
            offset += 1
            while offset + 3 <= data.count {
                if data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 9 {
                    offset += 3
                    return
                }
                let keyLength = (Int(data[offset]) << 8) | Int(data[offset + 1])
                offset += 2 + keyLength
                skipValue(data, offset: &offset)
            }
        case 0x05, 0x06:
            offset += 1
        default:
            offset = data.count
        }
    }

    private static func readObjectDescription(_ data: Data, offset: inout Int) -> String? {
        guard offset < data.count, data[offset] == 0x03 else { return nil }
        offset += 1
        var values: [String: String] = [:]
        while offset + 3 <= data.count {
            if data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 9 {
                offset += 3
                break
            }
            let keyLength = (Int(data[offset]) << 8) | Int(data[offset + 1])
            offset += 2
            guard offset + keyLength <= data.count else { break }
            let key = String(data: data[offset..<(offset + keyLength)], encoding: .utf8) ?? ""
            offset += keyLength
            if let value = readAnyString(data, offset: &offset), !key.isEmpty {
                values[key] = value
            } else {
                skipValue(data, offset: &offset)
            }
        }
        return values["description"] ?? values["details"] ?? values["code"]
    }

    private static func readAnyString(_ data: Data, offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        if data[offset] == 0x02 { return readString(data, offset: &offset) }
        return nil
    }
}

private enum BroadcastError: LocalizedError {
    case audio(String)
    case capture(String)
    case encoder(String)
    case rtmp(String)

    var errorDescription: String? {
        switch self {
        case .audio(let message), .capture(let message), .encoder(let message), .rtmp(let message): return message
        }
    }
}

private extension Data {
    func uint24(at offset: Int) -> UInt32 {
        guard offset + 2 < count else { return 0 }
        return (UInt32(self[offset]) << 16) | (UInt32(self[offset + 1]) << 8) | UInt32(self[offset + 2])
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16) | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }

    func uint32LittleEndian(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt24(_ value: UInt32) {
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32LittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendNumber(_ value: Double) {
        append(0x00)
        var bits = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }

    mutating func appendString(_ value: String) {
        append(0x02)
        let bytes = Data(value.utf8)
        appendUInt16(UInt16(bytes.count))
        append(bytes)
    }

    mutating func appendAMF0(_ value: Any?) {
        switch value {
        case nil:
            append(0x05)
        case let value as String:
            appendString(value)
        case let value as Double:
            appendNumber(value)
        case let value as Int:
            appendNumber(Double(value))
        case let value as Bool:
            append(0x01)
            append(value ? 1 : 0)
        case let value as [String: Any]:
            append(0x03)
            for (key, element) in value {
                let keyData = Data(key.utf8)
                appendUInt16(UInt16(keyData.count))
                append(keyData)
                appendAMF0(element)
            }
            append(contentsOf: [0, 0, 9])
        default:
            append(0x05)
        }
    }
}

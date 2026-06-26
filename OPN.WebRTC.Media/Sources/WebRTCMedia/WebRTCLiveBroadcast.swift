@preconcurrency import Accelerate
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import Network
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

final class WebRTCLiveBroadcastSession: @unchecked Sendable {
    var onStatusChanged: (@MainActor @Sendable (WebRTCLiveBroadcastStatus) -> Void)?

    private let queue = DispatchQueue(label: "io.opencg.opennow.twitch.broadcast")
    private let conversionQueue = DispatchQueue(label: "io.opencg.opennow.twitch.broadcast.conversion", qos: .userInitiated)
    private let encoder = WebRTCH264LiveEncoder()
    private let audioEncoder = WebRTCAACLiveEncoder()
    private var publisher: RTMPPublisher?
    private var configuration: WebRTCLiveBroadcastConfiguration?
    private var startedAt: Date?
    private var firstFrameHostTime: CFTimeInterval?
    private var frameIndex: Int64 = 0
    private var audioSampleIndex: UInt64 = 0
    private var droppedFrames = 0
    private var lastStatusHostTime: CFTimeInterval = 0
    private var isStopping = false
    private var microphoneStereoSamples: [Int16] = []
    private var i420PixelBufferPool: CVPixelBufferPool?
    private var i420PixelBufferPoolWidth = 0
    private var i420PixelBufferPoolHeight = 0
    private var ypCbCrToARGBInfo = vImage_YpCbCrToARGB()
    private var ypCbCrConversionReady = false

    var wantsEnhancedVideo: Bool { configuration?.enhancedVideoEnabled == true && isActive }

    var isActive: Bool {
        configuration != nil && !isStopping
    }

    func start(configuration: WebRTCLiveBroadcastConfiguration) {
        queue.async {
            guard self.configuration == nil else { return }
            self.configuration = configuration
            self.startedAt = Date()
            self.firstFrameHostTime = nil
            self.frameIndex = 0
            self.audioSampleIndex = 0
            self.droppedFrames = 0
            self.lastStatusHostTime = 0
            self.isStopping = false
            self.microphoneStereoSamples.removeAll(keepingCapacity: true)
            self.audioEncoder.reset(bitrateKbps: configuration.audioBitrateKbps)
            self.emit(.connecting)
            Task { await self.openPublisher(configuration: configuration) }
        }
    }

    func stop() {
        queue.async {
            guard self.configuration != nil else { return }
            self.isStopping = true
            self.emit(.stopping)
            let publisher = self.publisher
            self.publisher = nil
            self.encoder.invalidate()
            self.audioEncoder.reset(bitrateKbps: 160)
            self.reset()
            self.emit(.idle)
            Task { await publisher?.close() }
        }
    }

    func appendVideoFrame(_ frame: RTCVideoFrame) {
        guard isActive else { return }
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            appendPixelBuffer(buffer.pixelBuffer)
            return
        }
        let retainedFrame = UInt(bitPattern: Unmanaged.passRetained(frame).toOpaque())
        conversionQueue.async {
            let frame = Unmanaged<RTCVideoFrame>.fromOpaque(UnsafeRawPointer(bitPattern: retainedFrame)!).takeRetainedValue()
            let i420Frame = frame.newI420()
            guard let i420 = i420Frame.buffer as? RTCI420Buffer,
                  let pixelBuffer = self.newBGRAFramebuffer(from: i420) else { return }
            self.appendPixelBuffer(pixelBuffer)
        }
    }

    func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        appendPixelBuffer(pixelBuffer)
    }

    func appendGameAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate _: Double, channels: UInt32) {
        guard let audioBufferList,
              let copied = Self.stereoPCM(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), frameCount: frameCount, channels: channels) else { return }
        queue.async {
            guard let publisher = self.publisher, !self.isStopping else { return }
            let mixed = self.mixWithMicrophone(gameStereoSamples: copied)
            self.publishAudio(stereoSamples: mixed, publisher: publisher)
        }
    }

    func appendMicrophoneAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate _: Double, channels: UInt32) {
        guard let audioBufferList,
              let copied = Self.stereoPCM(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), frameCount: frameCount, channels: channels) else { return }
        queue.async {
            guard self.configuration != nil, !self.isStopping else { return }
            self.microphoneStereoSamples.append(contentsOf: copied)
            let maximumBufferedSamples = 48_000 * 2
            if self.microphoneStereoSamples.count > maximumBufferedSamples {
                self.microphoneStereoSamples.removeFirst(self.microphoneStereoSamples.count - maximumBufferedSamples)
            }
        }
    }

    private func openPublisher(configuration: WebRTCLiveBroadcastConfiguration) async {
        do {
            let publisher = try RTMPPublisher(rtmpURL: configuration.rtmpURL, streamKey: configuration.streamKey)
            try await publisher.connect()
            queue.async {
                guard self.configuration == configuration, !self.isStopping else {
                    Task { await publisher.close() }
                    return
                }
                self.publisher = publisher
                self.emit(.publishing(startedAt: self.startedAt ?? Date(), elapsedSeconds: 0, droppedFrames: 0, videoBitrateKbps: configuration.videoBitrateKbps))
            }
        } catch {
            queue.async { self.fail(error) }
        }
    }

    private func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let pixelBufferBox = BroadcastPixelBuffer(pixelBuffer)
        queue.async {
            let pixelBuffer = pixelBufferBox.value
            guard let configuration = self.configuration, let publisher = self.publisher, !self.isStopping else { return }
            if self.firstFrameHostTime == nil { self.firstFrameHostTime = CACurrentMediaTime() }
            guard let firstFrameHostTime = self.firstFrameHostTime else { return }
            let timestamp = CMTime(seconds: max(0, CACurrentMediaTime() - firstFrameHostTime), preferredTimescale: 1_000)
            do {
                if !self.encoder.isConfigured {
                    try self.encoder.configure(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), fps: configuration.fps, bitrateKbps: configuration.videoBitrateKbps)
                }
                let frameIndex = self.frameIndex
                self.frameIndex += 1
                try self.encoder.encode(pixelBuffer: pixelBuffer, presentationTime: timestamp, forceKeyframe: frameIndex == 0) { packet in
                    Task {
                        do {
                            try await publisher.publishVideo(packet)
                        } catch {
                            self.queue.async {
                                guard self.publisher === publisher else { return }
                                self.fail(error)
                            }
                        }
                    }
                }
                self.emitElapsedIfNeeded(configuration: configuration)
            } catch {
                self.droppedFrames += 1
                self.fail(error)
            }
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
        self.publisher = nil
        encoder.invalidate()
        audioEncoder.reset(bitrateKbps: 160)
        reset()
        Task { await publisher?.close() }
        emit(.failed(Self.message(for: error)))
    }

    private func reset() {
        configuration = nil
        startedAt = nil
        firstFrameHostTime = nil
        frameIndex = 0
        audioSampleIndex = 0
        isStopping = false
        droppedFrames = 0
        microphoneStereoSamples.removeAll(keepingCapacity: true)
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
                Task {
                    do {
                        try await publisher.publishAudio(packet, timestampMilliseconds: timestamp)
                    } catch {
                        self.queue.async {
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

    private func emit(_ status: WebRTCLiveBroadcastStatus) {
        Task { @MainActor [onStatusChanged] in onStatusChanged?(status) }
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
        return copyI420Buffer(i420, toBGRAOutput: pixelBuffer) ? pixelBuffer : nil
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

    private func ensureYpCbCrConversionReady() -> Bool {
        if ypCbCrConversionReady { return true }
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 1)
        let status = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
            &pixelRange,
            &ypCbCrToARGBInfo,
            kvImage420Yp8_Cb8_Cr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        ypCbCrConversionReady = status == kvImageNoError
        return ypCbCrConversionReady
    }

    private func copyI420Buffer(_ i420: RTCI420Buffer, toBGRAOutput output: CVPixelBuffer) -> Bool {
        guard ensureYpCbCrConversionReady() else { return false }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else { return false }
        let width = min(CVPixelBufferGetWidth(output), Int(i420.width))
        let height = min(CVPixelBufferGetHeight(output), Int(i420.height))
        guard width > 0, height > 0 else { return false }
        var sourceY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataY), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: Int(i420.strideY))
        var sourceCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataU), height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount((width + 1) / 2), rowBytes: Int(i420.strideU))
        var sourceCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataV), height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount((width + 1) / 2), rowBytes: Int(i420.strideV))
        var destination = vImage_Buffer(data: baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(output))
        var argbMap: [UInt8] = [0, 1, 2, 3]
        let conversionStatus = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &sourceY,
            &sourceCb,
            &sourceCr,
            &destination,
            &ypCbCrToARGBInfo,
            &argbMap,
            255,
            vImage_Flags(kvImageNoFlags)
        )
        guard conversionStatus == kvImageNoError else { return false }
        var bgraMap: [UInt8] = [3, 2, 1, 0]
        return vImagePermuteChannels_ARGB8888(&destination, &destination, &bgraMap, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Twitch broadcast failed." : error.localizedDescription
    }
}

private final class BroadcastPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
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
        var samples = stereoSamples
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
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool, callback: @escaping @Sendable (WebRTCH264Packet) -> Void) throws {
        guard let session else { throw BroadcastError.encoder("H.264 encoder is not configured.") }
        currentCallback = callback
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid, frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else { throw BroadcastError.encoder("H.264 frame encode failed (\(status)).") }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        isConfigured = false
    }

    private var currentCallback: (@Sendable (WebRTCH264Packet) -> Void)?

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr, let refcon, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let encoder = Unmanaged<WebRTCH264LiveEncoder>.fromOpaque(refcon).takeUnretainedValue()
        guard let packet = WebRTCH264LiveEncoder.packet(from: sampleBuffer) else { return }
        encoder.currentCallback?(packet)
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
            let size = Data(bytes: pointer + offset, count: 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
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

private actor RTMPPublisher {
    private static let outboundChunkSize = 128

    private let endpoint: RTMPEndpoint
    private var connection: NWConnection?
    private var streamID: UInt32 = 1

    init(rtmpURL: String, streamKey: String) throws {
        endpoint = try RTMPEndpoint(urlString: rtmpURL, streamKey: streamKey)
    }

    func connect() async throws {
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: endpoint.secure ? .tls : .tcp)
        self.connection = connection
        connection.start(queue: .global(qos: .userInitiated))
        try await waitUntilReady(connection)
        try await performHandshake(connection)
        try await sendConnectCommand()
        try await sendCreateStreamCommand()
        try await sendPublishCommand()
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
        try await withCheckedThrowingContinuation { continuation in
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
        let s0s1s2 = try await receive(length: 3073)
        guard s0s1s2.first == 3, s0s1s2.count == 3073 else { throw BroadcastError.rtmp("RTMP handshake failed.") }
        try await send(s0s1s2.subdata(in: 1..<1537))
    }

    private func sendConnectCommand() async throws {
        let payload = AMF0.command("connect", transactionID: 1, objects: [["app": endpoint.app, "type": "nonprivate", "tcUrl": endpoint.tcURL, "flashVer": "FMLE/3.0", "fpad": false, "capabilities": 15, "audioCodecs": 0, "videoCodecs": 128, "videoFunction": 1]])
        try await sendMessage(type: 20, streamID: 0, timestamp: 0, payload: payload)
        _ = try await receive(length: 1)
    }

    private func sendCreateStreamCommand() async throws {
        let payload = AMF0.command("createStream", transactionID: 2, objects: [nil])
        try await sendMessage(type: 20, streamID: 0, timestamp: 0, payload: payload)
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

    private func receive(length: Int) async throws -> Data {
        guard let connection else { throw BroadcastError.rtmp("RTMP connection is closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: data ?? Data())
            }
        }
    }
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
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        app = path.isEmpty ? "app" : path
        playPath = streamKey
        tcURL = "\(scheme)://\(host)/\(app)"
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
}

private enum BroadcastError: LocalizedError {
    case audio(String)
    case encoder(String)
    case rtmp(String)

    var errorDescription: String? {
        switch self {
        case .audio(let message), .encoder(let message), .rtmp(let message): return message
        }
    }
}

private extension Data {
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

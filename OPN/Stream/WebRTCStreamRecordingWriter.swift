//  The writer half of a recording: appending sample buffers, finishing the file and the state that
//  decides which video source a frame is allowed to come from.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import WebRTC

extension WebRTCStreamRecorder {
    func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, recordingId: UUID, source: VideoFrameSource, captureHostTime: CFTimeInterval) {
        let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        queue.async {
            defer { self.finishVideoFrameAppend(recordingId: recordingId, source: source) }
            guard let pixelBufferPointer = UnsafeRawPointer(bitPattern: retainedPixelBuffer) else { return }
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBufferPointer).takeRetainedValue()
            guard self.isActiveRecording(recordingId) else { return }
            self.appendPixelBufferOnQueue(pixelBuffer, source: source, captureHostTime: captureHostTime)
        }
    }

    func appendPixelBufferOnQueue(_ pixelBuffer: CVPixelBuffer, source: VideoFrameSource, captureHostTime: CFTimeInterval) {
        guard isRecording, selectVideoFrameSourceIfNeeded(source) else { return }
        // The adaptor is declared from the first frame and the encoder takes NV12, P010 and BGRA.
        // A 4:4:4 or 4:2:2 surface is transferred to the 4:2:0 layout of its own depth here, so
        // the recording keeps 10 bits where the stream has them and the append never fails on
        // a format the writer was not declared for.
        guard let pixelBuffer = Self.encoderCompatiblePixelBuffer(pixelBuffer, using: pixelTransfer) else { return }
        // Recorded before the writer is consulted: the first-frame watchdog needs to tell "no
        // frames are arriving" from "the encoder has not taken one yet".
        offeredVideoFrame = true
        guard let configuration,
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

    var firstPresentationTime: CMTime { .zero }

    func presentationTime(hostTime: CFTimeInterval = CACurrentMediaTime()) -> CMTime? {
        if firstHostTime == nil {
            firstHostTime = hostTime
            startedAt = Date()
            emit(.recording(startedAt: startedAt ?? createdAt, elapsedSeconds: 0))
        }
        guard let firstHostTime else { return nil }
        return CMTime(seconds: max(0, hostTime - firstHostTime), preferredTimescale: 600)
    }

    func finish() {
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

    func finishCompletedRecording() {
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

    func completedRecordingDurationSeconds() -> Double {
        let presentationDuration = max(0, lastPresentationTime.seconds)
        guard presentationDuration == 0, capturedVideoFrame, let startedAt else { return presentationDuration }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    func fail(_ error: Error?) {
        failed = true
        writer?.cancelWriting()
        reset()
        emit(.failed(Self.message(for: error)))
    }

    func reset() {
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
        offeredVideoFrame = false
        firstFrameTimeoutExtensions = 0
        finishing = false
        failed = false
        setActiveRecordingId(nil, enhancedVideoPreferred: false)
    }

    func setActiveRecordingId(_ recordingId: UUID?, enhancedVideoPreferred: Bool) {
        frameLock.withLock {
            activeRecordingId = recordingId
            self.enhancedVideoPreferred = enhancedVideoPreferred
            selectedVideoFrameSource = nil
            pendingNativeVideoRecordingId = nil
            pendingEnhancedVideoFrameCount = 0
        }
    }

    func beginVideoFrameAppend(source: VideoFrameSource) -> UUID? {
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

    func finishVideoFrameAppend(recordingId: UUID, source: VideoFrameSource) {
        frameLock.withLock {
            switch source {
            case .native:
                if pendingNativeVideoRecordingId == recordingId { pendingNativeVideoRecordingId = nil }
            case .enhanced:
                if pendingEnhancedVideoFrameCount > 0 { pendingEnhancedVideoFrameCount -= 1 }
            }
        }
    }

    func isActiveRecording(_ recordingId: UUID) -> Bool {
        frameLock.withLock { activeRecordingId == recordingId }
    }

    func selectVideoFrameSourceIfNeeded(_ source: VideoFrameSource) -> Bool {
        frameLock.withLock {
            if let selectedVideoFrameSource {
                return selectedVideoFrameSource == source
            }
            selectedVideoFrameSource = source
            return true
        }
    }

    func emitElapsedIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastStatusHostTime >= 0.5, let startedAt else { return }
        lastStatusHostTime = now
        emit(.recording(startedAt: startedAt, elapsedSeconds: max(0, now - (firstHostTime ?? now))))
    }

    /// Delivers statuses to the main actor **in order**. One unstructured task per status carries
    /// no ordering guarantee, and a `.finishing` overtaking the terminal `.finished` left the UI
    /// on a non-terminal status that nothing would ever follow — the Record button stayed disabled
    /// for the rest of the session. Every `emit` runs on `queue`, so chaining each delivery onto
    /// the previous one is enough to serialise them.
    func emit(_ status: WebRTCStreamRecordingStatus) {
        let handler = statusHandler
        let previous = statusDeliveryTask
        statusDeliveryTask = Task { @MainActor in
            await previous?.value
            handler?(status)
        }
    }

    /// The codec that can actually encode this frame size in hardware. Apple's H.264 encoder tops
    /// out around 4K, so a 5120x2160 NVST stream has to be recorded as HEVC or the encoder falls
    /// back to software and the recording costs more than the stream does.
    static func videoCodec(width: Int, height: Int) -> AVVideoCodecType {
        width > 4096 || height > 2304 ? .hevc : .h264
    }

    /// Ceiling for the automatic bitrate. The `width * height * fps / 8` heuristic was written for
    /// WebRTC resolutions; at native NVST's 5120x2160@120 it asks for ~166 Mbps, which is what
    /// every user who never touched the setting would get, encoded in real time next to a 5K
    /// decode. 60 Mbps is past visually lossless for HEVC at that size. An explicit setting is
    /// still honoured as-is — this only bounds the guess.
    static let automaticVideoBitrateCeiling = 60_000_000

    func videoSettings(configuration: WebRTCStreamRecordingConfiguration, width: Int, height: Int) -> [String: Any] {
        let bitrate = configuration.videoBitrateMbps > 0
            ? configuration.videoBitrateMbps * 1_000_000
            : min(Self.automaticVideoBitrateCeiling, max(4_000_000, width * height * configuration.fps / 8))
        let codec = Self.videoCodec(width: width, height: height)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: configuration.fps,
            AVVideoMaxKeyFrameIntervalKey: configuration.fps * 2,
        ]
        // The H.264 profile constant is not a valid HEVC profile; passing it makes the input fail
        // to initialise rather than fall back.
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    func prepareWriterIfNeeded(pixelBuffer: CVPixelBuffer, configuration: WebRTCStreamRecordingConfiguration, outputURL: URL) -> Bool {
        if writer != nil { return true }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(configuration: configuration, width: width, height: height))
            videoInput.expectsMediaDataInRealTime = true
            // Take the format from the frame rather than forcing BGRA. The NVST decoder emits NV12,
            // which is the encoder's native input — declaring BGRA here would mean a full-frame
            // colour conversion per frame, which 5120x2160 does not survive.
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Self.adaptorPixelFormat(for: pixelBuffer),
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

    func audioSettings(configuration: WebRTCStreamRecordingConfiguration) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: configuration.audioBitrateKbps * 1_000,
        ]
    }

    func newBGRAFramebuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
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

    func scheduleFirstFrameTimeout(recordingId: UUID) {
        queue.asyncAfter(deadline: .now() + firstFrameTimeout) {
            guard self.configuration != nil,
                  self.id == recordingId,
                  !self.capturedVideoFrame,
                  !self.finishing,
                  !self.failed else { return }
            // Frames arriving but none accepted is a busy encoder, not a dead video path: an
            // `AVAssetWriterInput` can report not-ready for seconds while it spins up, and killing
            // the recording then loses one that was working. Only "nothing offered at all" is the
            // failure this watchdog exists for.
            if self.offeredVideoFrame, self.firstFrameTimeoutExtensions < Self.maxFirstFrameTimeoutExtensions {
                self.firstFrameTimeoutExtensions += 1
                self.offeredVideoFrame = false
                self.scheduleFirstFrameTimeout(recordingId: recordingId)
                return
            }
            self.fail(WebRTCStreamRecorderError.videoFramesUnavailable)
        }
    }

    static func encoderCompatiblePixelBuffer(_ pixelBuffer: CVPixelBuffer, using transfer: OPNPixelBufferTransfer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if isDirectlyEncodable(format) || format == kCVPixelFormatType_32BGRA { return pixelBuffer }
        let target = OPNVideoTextureSource.isTenBitBiPlanarFormat(format)
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return transfer.convert(pixelBuffer, to: target)
    }

    static func isDirectlyEncodable(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    static func isWritableBGRA(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
    }

    /// The pixel format to declare on the writer's adaptor, taken from the first frame so no
    /// conversion is inserted. Formats the encoder cannot take directly still go in as BGRA, which
    /// is what every frame arriving through `appendVideoFrame` has already been converted to.
    static func adaptorPixelFormat(for pixelBuffer: CVPixelBuffer) -> OSType {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_32BGRA:
            return format
        default:
            return kCVPixelFormatType_32BGRA
        }
    }

    func i420BGRAFramebufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
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

    static func audioData(from audioBufferList: UnsafePointer<AudioBufferList>, channels: Int) -> Data {
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

    static func makeAudioSampleBuffer(data: Data, frameCount: UInt32, sampleRate: Double, channels: UInt32, presentationTime: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { pointer in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer).flatMapStatus {
                guard let baseAddress = pointer.baseAddress, let blockBuffer else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
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

    static func message(for error: Error?) -> String {
        guard let error else { return "Recording failed." }
        return error.localizedDescription.isEmpty ? "Recording failed." : error.localizedDescription
    }
}

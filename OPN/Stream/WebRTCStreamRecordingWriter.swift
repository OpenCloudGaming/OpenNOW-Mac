//
//  WebRTCStreamRecordingWriter.swift
//  OpenNOW
//
//  The writer half of a recording: appending sample buffers, finishing the file and the state
//  that decides which video source a frame is allowed to come from.
//  Split out of WebRTCStreamRecording.swift.
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

    func emit(_ status: WebRTCStreamRecordingStatus) {
        Task { @MainActor [onStatusChanged] in onStatusChanged?(status) }
    }

    func videoSettings(configuration: WebRTCStreamRecordingConfiguration, width: Int, height: Int) -> [String: Any] {
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
            self.fail(WebRTCStreamRecorderError.videoFramesUnavailable)
        }
    }

    static func isWritableBGRA(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
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

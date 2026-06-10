@preconcurrency import AVFoundation
import AppKit
import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Darwin
import ObjectiveC
import QuartzCore

private enum OPNRecordingAudioKind {
    case system
    case microphone
}

private final class OPNSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

@objc(OPNStreamRecordingManager)
final class OPNStreamRecordingManager: NSObject {
    @objc private(set) dynamic var isRecording = false
    @objc private(set) dynamic var isStarting = false
    @objc private(set) dynamic var statusText: String? = "Ready"
    @objc private(set) dynamic var currentRecordingURL: URL?
    @objc private(set) dynamic var recentRecordingURLs: [URL] = []
    @objc var onStateChanged: (() -> Void)?

    private let writerQueue = DispatchQueue(label: "com.opennow.recording.writer")
    private let audioQueue = DispatchQueue(label: "com.opennow.recording.audio")
    private let ciContext = CIContext(options: nil)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoSize = CGSize.zero
    private var acceptingSamples = false
    private var finishRequested = false
    private var recordingStartHostTime: CFTimeInterval = 0
    private var lastVideoTime = CMTime.invalid
    private var systemAudioSourceStartTime = CMTime.invalid
    private var microphoneAudioSourceStartTime = CMTime.invalid
    private var systemAudioTimelineOffset = CMTime.invalid
    private var microphoneAudioTimelineOffset = CMTime.invalid
    private var videoFrameAppendInFlight = false
    private var prefersEnhancedVideoCapture = false
    private var enhancedVideoActive = false
    private var enhancedVideoFallbackDeadlineHostTime: CFTimeInterval = 0
    private var droppedVideoFrames: UInt64 = 0
    private var lastDroppedVideoFrameLogTime: CFTimeInterval = 0
    private var microphoneCaptureSession: AVCaptureSession?

    override init() {
        super.init()
        refreshRecentRecordings()
    }

    deinit {
        stopRecording()
    }

    @objc(toggleRecordingForGameTitle:window:)
    func toggleRecording(forGameTitle gameTitle: String, window: NSWindow?) {
        if isRecording || isStarting {
            stopRecording()
        } else {
            startRecording(forGameTitle: gameTitle, window: window)
        }
    }

    @objc(startRecordingForGameTitle:window:)
    func startRecording(forGameTitle gameTitle: String, window: NSWindow?) {
        guard !isRecording && !isStarting else { return }
        guard let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            updateStatus("Movies folder unavailable", starting: false, recording: false, notify: true)
            return
        }
        do {
            try FileManager.default.createDirectory(at: moviesURL, withIntermediateDirectories: true)
        } catch {
            updateStatus(error.localizedDescription, starting: false, recording: false, notify: true)
            return
        }

        let outputURL = moviesURL.appendingPathComponent(Self.recordingFilename(gameTitle))
        try? FileManager.default.removeItem(at: outputURL)
        currentRecordingURL = outputURL
        updateStatus("Starting recording", starting: true, recording: false, notify: true)

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.writer = nil
            self.videoInput = nil
            self.systemAudioInput = nil
            self.microphoneAudioInput = nil
            self.pixelBufferAdaptor = nil
            self.videoSize = .zero
            self.acceptingSamples = true
            self.finishRequested = false
            self.recordingStartHostTime = CACurrentMediaTime()
            self.lastVideoTime = .invalid
            self.systemAudioSourceStartTime = .invalid
            self.microphoneAudioSourceStartTime = .invalid
            self.systemAudioTimelineOffset = .invalid
            self.microphoneAudioTimelineOffset = .invalid
            self.videoFrameAppendInFlight = false
            self.enhancedVideoFallbackDeadlineHostTime = self.prefersEnhancedVideoCapture ? CACurrentMediaTime() + 1.25 : 0
            self.enhancedVideoActive = false
            self.droppedVideoFrames = 0
            self.lastDroppedVideoFrameLogTime = 0
        }

        startAudioCapture(for: window)
    }

    @objc func setPrefersEnhancedVideoCapture(_ prefersEnhancedVideoCapture: Bool) {
        synchronized {
            let changed = self.prefersEnhancedVideoCapture != prefersEnhancedVideoCapture
            self.prefersEnhancedVideoCapture = prefersEnhancedVideoCapture
            if !prefersEnhancedVideoCapture {
                self.enhancedVideoFallbackDeadlineHostTime = 0
                return
            }
            if changed || self.enhancedVideoFallbackDeadlineHostTime <= 0 {
                self.enhancedVideoFallbackDeadlineHostTime = CACurrentMediaTime() + 1.25
            }
        }
    }

    @objc func stopRecording() {
        guard isRecording || isStarting else { return }
        updateStatus("Finishing recording", starting: false, recording: false, notify: true)
        stopAudioCapture()
        stopAVMicrophoneCapture()

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.acceptingSamples = false
            self.finishRequested = true
            self.videoFrameAppendInFlight = false
            let writer = self.writer
            let outputURL = self.currentRecordingURL
            guard let writer else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                    self.currentRecordingURL = nil
                    self.updateStatus("Recording canceled", starting: false, recording: false, notify: true)
                }
                return
            }

            self.videoInput?.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.microphoneAudioInput?.markAsFinished()
            let writerBox = OPNSendableBox(writer)
            writer.finishWriting { [weak self, writerBox] in
                guard let self else { return }
                let writer = writerBox.value
                let error = writer.error
                self.writerQueue.async { [weak self] in
                    guard let self else { return }
                    self.writer = nil
                    self.videoInput = nil
                    self.systemAudioInput = nil
                    self.microphoneAudioInput = nil
                    self.pixelBufferAdaptor = nil
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if writer.status == .completed && error == nil {
                        self.refreshRecentRecordings()
                        self.updateStatus("Recording saved", starting: false, recording: false, notify: true)
                        OPNSentry.logInfoMessage("[Recording] Saved \(outputURL?.path ?? "")")
                    } else {
                        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                        self.updateStatus(error?.localizedDescription ?? "Recording failed", starting: false, recording: false, notify: true)
                        OPNSentry.logErrorMessage("[Recording] Finish failed status=\(writer.status.rawValue) error=\(String(describing: error))")
                    }
                }
            }
        }
    }

    @objc func appendWebRTCVideoFrame(_ frame: UnsafeMutableRawPointer?) {
        guard let frame, isRecording || isStarting else { return }
        let videoFrame = Unmanaged<AnyObject>.fromOpaque(frame).takeUnretainedValue()
        let shouldAppend = synchronized { () -> Bool in
            if enhancedVideoActive { return false }
            if prefersEnhancedVideoCapture && writer == nil && CACurrentMediaTime() < enhancedVideoFallbackDeadlineHostTime { return false }
            if videoFrameAppendInFlight {
                recordDroppedVideoFrame()
                return false
            }
            videoFrameAppendInFlight = true
            return true
        }
        guard shouldAppend else { return }

        let videoFrameBox = OPNSendableBox(videoFrame)
        writerQueue.async { [weak self, videoFrameBox] in
            guard let self else { return }
            autoreleasepool {
                let videoFrame = videoFrameBox.value
                guard self.acceptingSamples, self.currentRecordingURL != nil else {
                    self.finishVideoFrameAppend()
                    return
                }
                let size = Self.frameSize(videoFrame)
                guard size.width >= 2, size.height >= 2 else {
                    self.finishVideoFrameAppend()
                    return
                }
                if self.writer == nil && !self.createWriter(videoSize: size) {
                    self.finishVideoFrameAppend()
                    return
                }
                guard self.writer?.status == .writing, self.videoInput?.isReadyForMoreMediaData == true else {
                    self.finishVideoFrameAppend()
                    return
                }
                guard let pixelBuffer = self.copyPixelBuffer(from: videoFrame) else {
                    self.finishVideoFrameAppend()
                    return
                }
                let presentationTime = self.nextVideoPresentationTime()
                let appended = self.pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: presentationTime) ?? false
                if !appended {
                    OPNSentry.logErrorMessage("[Recording] Video append failed: \(String(describing: self.writer?.error))")
                } else if self.isStarting {
                    DispatchQueue.main.async { [weak self] in
                        self?.updateStatus("Recording", starting: false, recording: true, notify: true)
                    }
                }
                self.finishVideoFrameAppend()
            }
        }
    }

    @objc func appendEnhancedPixelBuffer(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer, isRecording || isStarting else { return }
        let shouldAppend = synchronized { () -> Bool in
            if videoFrameAppendInFlight {
                recordDroppedVideoFrame()
                return false
            }
            videoFrameAppendInFlight = true
            return true
        }
        guard shouldAppend else { return }
        let retainedPixelBufferAddress = Self.passRetainedPixelBuffer(pixelBuffer)

        writerQueue.async { [weak self, retainedPixelBufferAddress] in
            let pixelBuffer = Self.takeRetainedPixelBuffer(retainedPixelBufferAddress)
            guard let self else {
                return
            }
            autoreleasepool {
                guard self.acceptingSamples, self.currentRecordingURL != nil else {
                    self.finishVideoFrameAppend()
                    return
                }
                let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
                guard size.width >= 2, size.height >= 2 else {
                    self.finishVideoFrameAppend()
                    return
                }
                if let writer = self.writer {
                    let writerWidth = Int64(self.videoSize.width.rounded())
                    let writerHeight = Int64(self.videoSize.height.rounded())
                    let frameWidth = Int64(size.width.rounded())
                    let frameHeight = Int64(size.height.rounded())
                    if writerWidth != frameWidth || writerHeight != frameHeight || writer.status != .writing {
                        self.synchronized { self.enhancedVideoActive = false }
                        self.finishVideoFrameAppend()
                        return
                    }
                }
                if self.writer == nil && !self.createWriter(videoSize: size) {
                    self.finishVideoFrameAppend()
                    return
                }
                self.synchronized { self.enhancedVideoActive = true }
                guard self.videoInput?.isReadyForMoreMediaData == true else {
                    self.finishVideoFrameAppend()
                    return
                }
                let presentationTime = self.nextVideoPresentationTime()
                let appended = self.pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: presentationTime) ?? false
                if !appended {
                    OPNSentry.logErrorMessage("[Recording] Enhanced video append failed: \(String(describing: self.writer?.error))")
                } else if self.isStarting {
                    DispatchQueue.main.async { [weak self] in
                        self?.updateStatus("Recording", starting: false, recording: true, notify: true)
                    }
                }
                self.finishVideoFrameAppend()
            }
        }
    }

    @objc(appendWebRTCAudioBufferList:frameCount:sampleRate:channels:)
    func appendWebRTCAudioBufferList(_ audioBufferList: UnsafePointer<AudioBufferList>?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList, frameCount > 0, isRecording || isStarting else { return }
        let bufferList = audioBufferList.pointee
        guard bufferList.mNumberBuffers > 0 else { return }
        let buffer = bufferList.mBuffers
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }

        var format = AudioStreamBasicDescription()
        format.mSampleRate = sampleRate > 0 ? sampleRate : 48_000
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = 16
        format.mChannelsPerFrame = max(1, channels)
        format.mFramesPerPacket = 1
        format.mBytesPerFrame = format.mChannelsPerFrame * UInt32(MemoryLayout<Int16>.size)
        format.mBytesPerPacket = format.mBytesPerFrame

        let expectedBytes = frameCount * format.mBytesPerFrame
        let dataBytes = min(expectedBytes, buffer.mDataByteSize)
        guard dataBytes > 0 else { return }

        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else { return }

        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: Int(dataBytes), blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: Int(dataBytes), flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { return }
        status = CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: Int(dataBytes))
        guard status == noErr else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.mSampleRate)), presentationTimeStamp: CMTime(seconds: max(0, CACurrentMediaTime() - recordingStartHostTime), preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let sampleCount = max(1, CMItemCount(dataBytes / format.mBytesPerFrame))
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: sampleCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }
        appendPreparedAudioSampleBuffer(sampleBuffer, kind: .system)
    }

    @objc(thumbnailForRecordingURL:size:)
    func thumbnail(forRecordingURL url: URL?, size: NSSize) -> NSImage? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        var image = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        if image == nil { image = try? generator.copyCGImage(at: .zero, actualTime: nil) }
        guard let image else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    private func createWriter(videoSize size: CGSize) -> Bool {
        guard let outputURL = currentRecordingURL else { return false }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatus(error.localizedDescription, starting: false, recording: false, notify: true)
            }
            return false
        }

        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        let profile = OPNStreamPreferences.loadProfile()
        let automaticVideoBitrate = min(60_000_000, max(5_000_000, width * height * 8))
        let videoBitrate = profile.recordingVideoBitrateMbps > 0 ? profile.recordingVideoBitrateMbps * 1_000_000 : automaticVideoBitrate
        let systemAudioBitrate = max(64_000, profile.recordingAudioBitrateKbps * 1_000)
        let microphoneAudioBitrate = max(64_000, (systemAudioBitrate * 3) / 5)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelAttributes)
        let systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 2, bitrate: systemAudioBitrate))
        systemAudio.expectsMediaDataInRealTime = true
        let microphoneAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 1, bitrate: microphoneAudioBitrate))
        microphoneAudio.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else { return false }
        writer.add(videoInput)
        if writer.canAdd(systemAudio) { writer.add(systemAudio) }
        if writer.canAdd(microphoneAudio) { writer.add(microphoneAudio) }
        guard writer.startWriting() else {
            OPNSentry.logErrorMessage("[Recording] startWriting failed: \(String(describing: writer.error))")
            return false
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudio
        self.microphoneAudioInput = microphoneAudio
        self.pixelBufferAdaptor = adaptor
        self.videoSize = CGSize(width: width, height: height)
        OPNSentry.logInfoMessage("[Recording] Writer started \(outputURL.path) \(width)x\(height)")
        return true
    }

    private func nextVideoPresentationTime() -> CMTime {
        let elapsed = max(0, CACurrentMediaTime() - recordingStartHostTime)
        var time = CMTime(seconds: elapsed, preferredTimescale: 600)
        if lastVideoTime.isValid && time <= lastVideoTime {
            time = lastVideoTime + CMTime(value: 1, timescale: 600)
        }
        lastVideoTime = time
        return time
    }

    private func copyPixelBuffer(from frame: AnyObject) -> CVPixelBuffer? {
        guard let pool = pixelBufferAdaptor?.pixelBufferPool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess, let output else { return nil }

        if let buffer = Self.sendObject(frame, selector: #selector(getter: OPNDynamicRTCVideoFrame.buffer)), NSStringFromClass(type(of: buffer)).contains("RTCCVPixelBuffer"), let pixelBuffer = Self.sendPixelBuffer(buffer, selector: #selector(getter: OPNDynamicRTCCVPixelBuffer.pixelBuffer)) {
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            if Self.sendBool(buffer, selector: #selector(getter: OPNDynamicRTCCVPixelBuffer.requiresCropping)) {
                let crop = CGRect(x: CGFloat(Self.sendInt(buffer, selector: #selector(getter: OPNDynamicRTCCVPixelBuffer.cropX))), y: CGFloat(Self.sendInt(buffer, selector: #selector(getter: OPNDynamicRTCCVPixelBuffer.cropY))), width: CGFloat(Self.sendInt(buffer, selector: #selector(getter: OPNDynamicRTCCVPixelBuffer.cropWidth))), height: CGFloat(Self.sendInt(buffer, selector: #selector(getter: OPNDynamicRTCCVPixelBuffer.cropHeight))))
                image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
            }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            ciContext.render(image, to: output, bounds: CGRect(origin: .zero, size: videoSize), colorSpace: colorSpace)
            return output
        }

        guard let i420Frame = Self.sendObject(frame, selector: #selector(OPNDynamicRTCVideoFrame.newI420VideoFrame)), let i420 = Self.sendObject(i420Frame, selector: #selector(getter: OPNDynamicRTCVideoFrame.buffer)) else {
            return nil
        }
        copyI420Buffer(i420, toBGRAOutput: output)
        return output
    }

    private func copyI420Buffer(_ i420: AnyObject, toBGRAOutput output: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else { return }
        let dst = baseAddress.assumingMemoryBound(to: UInt8.self)
        let dstStride = CVPixelBufferGetBytesPerRow(output)
        let width = min(Int(videoSize.width), Int(Self.sendInt(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.width))))
        let height = min(Int(videoSize.height), Int(Self.sendInt(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.height))))
        guard let dataY = Self.sendPointer(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.dataY)), let dataU = Self.sendPointer(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.dataU)), let dataV = Self.sendPointer(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.dataV)) else { return }
        let strideY = Int(Self.sendInt(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.strideY)))
        let strideU = Int(Self.sendInt(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.strideU)))
        let strideV = Int(Self.sendInt(i420, selector: #selector(getter: OPNDynamicRTCI420Buffer.strideV)))
        for y in 0..<height {
            let row = dst.advanced(by: y * dstStride)
            let yRow = dataY.advanced(by: y * strideY)
            let uRow = dataU.advanced(by: (y / 2) * strideU)
            let vRow = dataV.advanced(by: (y / 2) * strideV)
            for x in 0..<width {
                let yy = Int(yRow[x])
                let uu = Int(uRow[x / 2]) - 128
                let vv = Int(vRow[x / 2]) - 128
                let r = yy + Int((1.402 * Double(vv)).rounded())
                let g = yy - Int((0.344136 * Double(uu) + 0.714136 * Double(vv)).rounded())
                let b = yy + Int((1.772 * Double(uu)).rounded())
                row[x * 4] = UInt8(max(0, min(255, b)))
                row[x * 4 + 1] = UInt8(max(0, min(255, g)))
                row[x * 4 + 2] = UInt8(max(0, min(255, r)))
                row[x * 4 + 3] = 255
            }
        }
    }

    private func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, kind: OPNRecordingAudioKind) {
        guard isRecording || isStarting else { return }
        let sampleBufferBox = OPNSendableBox(sampleBuffer)
        writerQueue.async { [weak self, sampleBufferBox] in
            guard let self else { return }
            let sampleBuffer = sampleBufferBox.value
            guard self.acceptingSamples, self.writer?.status == .writing else { return }
            let input = kind == .microphone ? self.microphoneAudioInput : self.systemAudioInput
            guard input?.isReadyForMoreMediaData == true else { return }
            guard let retimed = self.copyAudioSampleBuffer(sampleBuffer, kind: kind) else { return }
            if input?.append(retimed) != true {
                OPNSentry.logErrorMessage("[Recording] Audio append failed: \(String(describing: self.writer?.error))")
            }
        }
    }

    private func appendPreparedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, kind: OPNRecordingAudioKind) {
        guard isRecording || isStarting else { return }
        let sampleBufferBox = OPNSendableBox(sampleBuffer)
        writerQueue.async { [weak self, sampleBufferBox] in
            guard let self else { return }
            let sampleBuffer = sampleBufferBox.value
            guard self.acceptingSamples, self.writer?.status == .writing else { return }
            let input = kind == .microphone ? self.microphoneAudioInput : self.systemAudioInput
            guard input?.isReadyForMoreMediaData == true else { return }
            if input?.append(sampleBuffer) != true {
                OPNSentry.logErrorMessage("[Recording] Prepared audio append failed: \(String(describing: self.writer?.error))")
            }
        }
    }

    private func copyAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, kind: OPNRecordingAudioKind) -> CMSampleBuffer? {
        let sourceTime = sampleBuffer.presentationTimeStamp
        guard sourceTime.isValid else { return nil }
        if kind == .microphone {
            if !microphoneAudioSourceStartTime.isValid {
                microphoneAudioSourceStartTime = sourceTime
                microphoneAudioTimelineOffset = CMTime(seconds: max(0, CACurrentMediaTime() - recordingStartHostTime), preferredTimescale: 600)
            }
        } else if !systemAudioSourceStartTime.isValid {
            systemAudioSourceStartTime = sourceTime
            systemAudioTimelineOffset = CMTime(seconds: max(0, CACurrentMediaTime() - recordingStartHostTime), preferredTimescale: 600)
        }
        let sourceStart = kind == .microphone ? microphoneAudioSourceStartTime : systemAudioSourceStartTime
        let timelineOffset = kind == .microphone ? microphoneAudioTimelineOffset : systemAudioTimelineOffset
        let targetTime = timelineOffset + (sourceTime - sourceStart)
        let count = sampleBuffer.numSamples
        guard count > 0 else { return nil }

        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        var needed = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &needed) == noErr else { return nil }
        let shift = targetTime - sourceTime
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid { timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift }
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + shift }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    private func startAudioCapture(for window: NSWindow?) {
        _ = window
        startAVMicrophoneCapture()
        OPNSentry.logInfoMessage("[Recording] Direct WebRTC game audio enabled; system audio capture disabled")
    }

    private func stopAudioCapture() {
    }

    private func startAVMicrophoneCapture() {
        guard microphoneCaptureSession == nil else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            OPNSentry.logErrorMessage("[Recording] Microphone recording unavailable: permission denied")
            return
        }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.startAVMicrophoneCapture() }
            }
            return
        }
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            OPNSentry.logErrorMessage("[Recording] Microphone input failed: \(error.localizedDescription)")
            return
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        let session = AVCaptureSession()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        microphoneCaptureSession = session
        session.startRunning()
        OPNSentry.logInfoMessage("[Recording] AVFoundation microphone capture started")
    }

    private func stopAVMicrophoneCapture() {
        guard let session = microphoneCaptureSession else { return }
        microphoneCaptureSession = nil
        let sessionBox = OPNSendableBox(session)
        audioQueue.async { sessionBox.value.stopRunning() }
    }

    private func refreshRecentRecordings() {
        guard let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            recentRecordingURLs = []
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: moviesURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let recordings = files.filter { $0.lastPathComponent.hasPrefix("OpenNOW-") && $0.pathExtension.lowercased() == "mp4" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return rhsDate < lhsDate
            }
        recentRecordingURLs = Array(recordings.prefix(6))
    }

    private func updateStatus(_ status: String?, starting: Bool, recording: Bool, notify: Bool) {
        statusText = status ?? "Ready"
        isStarting = starting
        isRecording = recording
        if notify { onStateChanged?() }
    }

    private func finishVideoFrameAppend() {
        synchronized { videoFrameAppendInFlight = false }
    }

    private func recordDroppedVideoFrame() {
        droppedVideoFrames += 1
        let now = CACurrentMediaTime()
        if now - lastDroppedVideoFrameLogTime >= 5 {
            OPNSentry.logErrorMessage("[Recording] Dropping video frames while writer is busy (total=\(droppedVideoFrames))")
            lastDroppedVideoFrameLogTime = now
        }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return body()
    }

    private static func audioSettings(channels: Int, bitrate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ]
    }

    private static func recordingFilename(_ gameTitle: String) -> String {
        let title = gameTitle.isEmpty ? "Stream" : gameTitle
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var safe = ""
        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                safe.unicodeScalars.append(scalar)
            } else if safe.last != "-" {
                safe.append("-")
            }
        }
        while safe.last == "-" { safe.removeLast() }
        if safe.isEmpty { safe = "Stream" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "OpenNOW-\(safe)-\(formatter.string(from: Date())).mp4"
    }

    private static func frameSize(_ frame: AnyObject) -> CGSize {
        let rotation = Int(sendInt(frame, selector: #selector(getter: OPNDynamicRTCVideoFrame.rotation)))
        let width = Int(sendInt(frame, selector: #selector(getter: OPNDynamicRTCVideoFrame.width)))
        let height = Int(sendInt(frame, selector: #selector(getter: OPNDynamicRTCVideoFrame.height)))
        if rotation == 90 || rotation == 270 {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    private static func passRetainedPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> UInt {
        UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
    }

    private static func takeRetainedPixelBuffer(_ address: UInt) -> CVPixelBuffer {
        let pointer = UnsafeRawPointer(bitPattern: address)!
        return Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeRetainedValue()
    }

    private static func sendObject(_ receiver: AnyObject, selector: Selector) -> AnyObject? {
        typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return nil }
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(receiver, selector)?.takeUnretainedValue()
    }

    private static func sendPixelBuffer(_ receiver: AnyObject, selector: Selector) -> CVPixelBuffer? {
        typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<CVPixelBuffer>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return nil }
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(receiver, selector)?.takeUnretainedValue()
    }

    private static func sendInt(_ receiver: AnyObject, selector: Selector) -> Int32 {
        typealias Function = @convention(c) (AnyObject, Selector) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return 0 }
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(receiver, selector)
    }

    private static func sendBool(_ receiver: AnyObject, selector: Selector) -> Bool {
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return false }
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(receiver, selector)
    }

    private static func sendPointer(_ receiver: AnyObject, selector: Selector) -> UnsafePointer<UInt8>? {
        typealias Function = @convention(c) (AnyObject, Selector) -> UnsafePointer<UInt8>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return nil }
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(receiver, selector)
    }
}

@objc private protocol OPNDynamicRTCVideoFrame {
    var buffer: AnyObject { get }
    var rotation: Int32 { get }
    var width: Int32 { get }
    var height: Int32 { get }
    func newI420VideoFrame() -> AnyObject
}

@objc private protocol OPNDynamicRTCCVPixelBuffer {
    var pixelBuffer: CVPixelBuffer { get }
    var requiresCropping: Bool { get }
    var cropX: Int32 { get }
    var cropY: Int32 { get }
    var cropWidth: Int32 { get }
    var cropHeight: Int32 { get }
}

@objc private protocol OPNDynamicRTCI420Buffer {
    var width: Int32 { get }
    var height: Int32 { get }
    var strideY: Int32 { get }
    var strideU: Int32 { get }
    var strideV: Int32 { get }
    var dataY: UnsafePointer<UInt8> { get }
    var dataU: UnsafePointer<UInt8> { get }
    var dataV: UnsafePointer<UInt8> { get }
}

extension OPNStreamRecordingManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        _ = output
        _ = connection
        appendAudioSampleBuffer(sampleBuffer, kind: .microphone)
    }
}

extension OPNStreamRecordingManager: @unchecked Sendable {}

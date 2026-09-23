//  The replay buffer's realtime entry points: each takes the ingress gate's lock, stamps the
//  frame's arrival time and hands the work to the buffer's serial queue.
//

import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import WebRTC

extension StreamReplayBuffer {
    /// A decoded frame that is already a `CVPixelBuffer`, which is what the native NVST decoder
    /// hands over.
    public func appendNativePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let ingressToken = beginIngress() else { return }
        let hostTime = CACurrentMediaTime()
        let retainedPointer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        queue.async { [weak self] in
            defer { self?.finishIngress() }
            guard let self, self.isGenerationActive(ingressToken), let pointer = UnsafeRawPointer(bitPattern: retainedPointer) else { return }
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeRetainedValue()
            self.appendPixelBufferOnQueue(pixelBuffer, hostTime: hostTime)
        }
    }

    /// A libwebrtc frame. Formats the encoder cannot take directly are converted on the conversion
    /// queue, so the decode thread never pays for it.
    public func appendVideoFrame(_ frame: RTCVideoFrame) {
        guard let ingressToken = beginIngress() else { return }
        let hostTime = CACurrentMediaTime()
        guard let buffer = frame.buffer as? RTCCVPixelBuffer,
              WebRTCStreamRecorder.isDirectlyEncodable(CVPixelBufferGetPixelFormatType(buffer.pixelBuffer)) || WebRTCStreamRecorder.isWritableBGRA(buffer.pixelBuffer) else {
            appendConvertedVideoFrame(frame, ingressToken: ingressToken, hostTime: hostTime)
            return
        }
        let retainedPointer = UInt(bitPattern: Unmanaged.passRetained(buffer.pixelBuffer).toOpaque())
        queue.async { [weak self] in
            defer { self?.finishIngress() }
            guard let self, self.isGenerationActive(ingressToken), let pointer = UnsafeRawPointer(bitPattern: retainedPointer) else { return }
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeRetainedValue()
            self.appendPixelBufferOnQueue(pixelBuffer, hostTime: hostTime)
        }
    }

    /// Decoded PCM that never passed through an audio device. Converted here so both audio feeds
    /// land in the same Int16 path the segment writer uses.
    public func appendGameAudioSamples(_ samples: [Float], sampleRate: Double, channels: UInt32) {
        let channelCount = max(1, Int(channels))
        guard !samples.isEmpty, samples.count % channelCount == 0, let ingressToken = beginIngress() else { return }
        let hostTime = CACurrentMediaTime()
        // Mutable because `withUnsafeMutableBytes` requires it, matching the recorder's own path.
        var interleaved = [Int16](unsafeUninitializedCapacity: samples.count) { buffer, initializedCount in
            for index in 0..<samples.count {
                let clamped = min(max(samples[index], -1), 1)
                buffer[index] = Int16(clamped * 32767)
            }
            initializedCount = samples.count
        }
        let frameCount = UInt32(samples.count / channelCount)
        let data = interleaved.withUnsafeMutableBytes { Data($0) }
        queue.async { [weak self] in
            defer { self?.finishIngress() }
            guard let self, self.isGenerationActive(ingressToken) else { return }
            self.appendAudioOnQueue(data: data, frameCount: frameCount, sampleRate: sampleRate, channels: channels, hostTime: hostTime)
        }
    }

    public func appendGameAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList, let ingressToken = beginIngress() else { return }
        let hostTime = CACurrentMediaTime()
        let data = WebRTCStreamRecorder.audioData(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), channels: max(1, Int(channels)))
        guard !data.isEmpty else {
            finishIngress()
            return
        }
        queue.async { [weak self] in
            defer { self?.finishIngress() }
            guard let self, self.isGenerationActive(ingressToken) else { return }
            self.appendAudioOnQueue(data: data, frameCount: frameCount, sampleRate: sampleRate, channels: channels, hostTime: hostTime)
        }
    }

    /// The libwebrtc path for a frame whose pixel format the encoder cannot take as it arrived.
    private func appendConvertedVideoFrame(_ frame: RTCVideoFrame, ingressToken: UInt64, hostTime: CFTimeInterval) {
        let retainedFramePointer = UInt(bitPattern: Unmanaged.passRetained(frame).toOpaque())
        conversionQueue.async { [weak self] in
            guard let self, let pointer = UnsafeRawPointer(bitPattern: retainedFramePointer) else {
                self?.finishIngress()
                return
            }
            let frame = Unmanaged<RTCVideoFrame>.fromOpaque(pointer).takeRetainedValue()
            let i420Frame = frame.newI420()
            guard let i420 = i420Frame.buffer as? RTCI420Buffer,
                  let pixelBuffer = self.bgraFrameBuffer(from: i420) else {
                self.finishIngress()
                return
            }
            let retainedPixelBufferPointer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
            self.queue.async { [weak self] in
                defer { self?.finishIngress() }
                guard let self, self.isGenerationActive(ingressToken), let pointer = UnsafeRawPointer(bitPattern: retainedPixelBufferPointer) else { return }
                let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeRetainedValue()
                self.appendPixelBufferOnQueue(pixelBuffer, hostTime: hostTime)
            }
        }
    }

    func bgraFrameBuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0, let pool = bgraFramebufferPool(width: width, height: height) else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return nil }
        return i420BGRAConverter.copy(i420, toBGRAOutput: pixelBuffer) ? pixelBuffer : nil
    }

    private func bgraFramebufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let bgraPool, bgraPoolWidth == width, bgraPoolHeight == height { return bgraPool }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        bgraPool = pool
        bgraPoolWidth = width
        bgraPoolHeight = height
        return pool
    }
}

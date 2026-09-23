//  The replay buffer's realtime entry points: each takes the ingress gate's lock, stamps the
//  frame's arrival time and hands the work to the buffer's serial queue.
//

import AudioToolbox
import CoreVideo
import Foundation
import QuartzCore

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
        let data = StreamRecorder.audioData(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), channels: max(1, Int(channels)))
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

}

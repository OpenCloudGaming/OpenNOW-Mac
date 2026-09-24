import AudioToolbox
import Foundation

/// One 48 kHz stereo PCM frame taken off the host's game-audio tap, ready to packetize.
struct RemoteCoOpNativeAudioFrame: Sendable {
    static let sampleRate = 48_000.0
    static let channels: UInt32 = 2

    let samples: Data
    let frameCount: UInt32
    let sampleRate: Double
    let channels: UInt32

    init(samples: Data, frameCount: UInt32, sampleRate: Double = Self.sampleRate, channels: UInt32 = Self.channels) {
        self.samples = samples
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// The host's CoreAudio game-audio callback turned into interleaved 48 kHz stereo Int16, with no
/// WebRTC involved. It was lifted out of the deleted WebRTC audio relay; the native broadcaster feeds
/// from that same tap, so it uses this.
enum RemoteCoOpNativeAudioConversion {
    /// One buffer's worth of source samples, flattened, with each source buffer's length kept.
    ///
    /// The lengths matter: a deinterleaved source hands over one buffer per channel and they need not
    /// be the same length, so flattening without them would silently mix the channels together.
    struct RawInt16Buffers {
        var samples: [Int16]
        /// Sample count of each source buffer, in order. `count == 1` means an interleaved source.
        var lengths: [Int]
    }

    /// Flat copy of the source buffers, taken on the caller's thread because they are only valid for
    /// the duration of the callback. One `[Int16]` copy is the minimum that lets the caller's buffer
    /// be released on return.
    static func rawInt16Copy(from list: UnsafePointer<AudioBufferList>) -> RawInt16Buffers? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0 else { return nil }
        var lengths = [Int]()
        lengths.reserveCapacity(buffers.count)
        for buffer in buffers { lengths.append(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: total)
        samples.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            var offset = 0
            for (index, buffer) in buffers.enumerated() {
                let count = lengths[index]
                defer { offset += count }
                guard count > 0, let data = buffer.mData else { continue }
                base.advanced(by: offset).update(from: data.bindMemory(to: Int16.self, capacity: count), count: count)
            }
        }
        return RawInt16Buffers(samples: samples, lengths: lengths)
    }

    /// Both source layouts CoreAudio can hand over, reading the flat copy.
    static func audioFrame(from raw: RawInt16Buffers, frameCount: UInt32, sampleRate: Double, channels: UInt32) -> RemoteCoOpNativeAudioFrame? {
        let outputFrames = Int(frameCount)
        guard outputFrames > 0 else { return nil }
        let outputChannels = Int(RemoteCoOpNativeAudioFrame.channels)
        let sourceChannels = max(1, Int(channels))
        var stereo = [Int16](repeating: 0, count: outputFrames * outputChannels)

        if raw.lengths.count == 1 {
            // Interleaved: one buffer, samples laid out frame-major.
            let available = raw.lengths[0]
            guard available >= outputFrames * sourceChannels else { return nil }
            for frame in 0..<outputFrames {
                let sourceIndex = frame * sourceChannels
                let left = raw.samples[sourceIndex]
                stereo[frame * 2] = left
                stereo[frame * 2 + 1] = sourceChannels > 1 ? raw.samples[sourceIndex + 1] : left
            }
        } else {
            // Deinterleaved: buffer 0 is the left channel, buffer 1 the right when present.
            let leftCount = raw.lengths[0]
            let rightCount = raw.lengths.count > 1 ? raw.lengths[1] : 0
            let rightOffset = leftCount
            for frame in 0..<outputFrames {
                let left = frame < leftCount ? raw.samples[frame] : 0
                let right = frame < rightCount ? raw.samples[rightOffset + frame] : left
                stereo[frame * 2] = left
                stereo[frame * 2 + 1] = right
            }
        }

        let resampled = resampledStereoPCM(stereo, sourceSampleRate: sampleRate, targetSampleRate: RemoteCoOpNativeAudioFrame.sampleRate)
        let data = resampled.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Int16>.size)
        }
        guard !data.isEmpty else { return nil }
        return RemoteCoOpNativeAudioFrame(samples: data, frameCount: UInt32(resampled.count / outputChannels))
    }

    private static func resampledStereoPCM(_ samples: [Int16], sourceSampleRate: Double, targetSampleRate: Double) -> [Int16] {
        guard sourceSampleRate > 0, abs(sourceSampleRate - targetSampleRate) > 0.5 else { return samples }
        let sourceFrames = samples.count / Int(RemoteCoOpNativeAudioFrame.channels)
        guard sourceFrames > 1 else { return samples }
        let targetFrames = max(1, Int((Double(sourceFrames) * targetSampleRate / sourceSampleRate).rounded()))
        var output = [Int16](repeating: 0, count: targetFrames * Int(RemoteCoOpNativeAudioFrame.channels))
        for frame in 0..<targetFrames {
            let sourcePosition = Double(frame) * sourceSampleRate / targetSampleRate
            let lower = min(sourceFrames - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(sourceFrames - 1, lower + 1)
            let fraction = sourcePosition - Double(lower)
            for channel in 0..<Int(RemoteCoOpNativeAudioFrame.channels) {
                let a = Double(samples[lower * 2 + channel])
                let b = Double(samples[upper * 2 + channel])
                output[frame * 2 + channel] = Int16(max(Double(Int16.min), min(Double(Int16.max), a + ((b - a) * fraction))))
            }
        }
        return output
    }
}

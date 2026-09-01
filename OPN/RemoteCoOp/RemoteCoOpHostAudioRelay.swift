import AudioToolbox
import AudioUnit
import Darwin
import Foundation
@preconcurrency import WebRTC

public struct OPNRemoteCoOpHostAudioFrame: Sendable {
    public static let sampleRate = 48_000.0
    public static let channels: UInt32 = 2

    public let samples: Data
    public let frameCount: UInt32
    public let sampleRate: Double
    public let channels: UInt32

    public init(samples: Data, frameCount: UInt32, sampleRate: Double = Self.sampleRate, channels: UInt32 = Self.channels) {
        self.samples = samples
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public protocol OPNRemoteCoOpHostAudioSink: AnyObject, Sendable {
    var participantID: UUID { get }
    func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame)
}

public final class OPNRemoteCoOpHostAudioRelay: @unchecked Sendable {
    let lock = NSLock()
    private var sinks: [UUID: any OPNRemoteCoOpHostAudioSink] = [:]
    /// Mirrors `!sinks.isEmpty`, maintained under `lock` but read without it from the render thread.
    /// A plain `Bool` read is atomic on every architecture this ships to, and being one frame stale
    /// either way is harmless - what matters is that a solo session takes no lock at all.
    private var hasSinks = false
    /// Where a built frame is handed to the guests' encoders.
    ///
    /// The callers are the CoreAudio render thread and the NVST audio receive queue, and delivering
    /// inline runs libwebrtc's APM and Opus encode there once per guest - the priority inversion the
    /// recorder's "copies and returns" comment exists to avoid. Serial, because the audio device
    /// numbers its own sample clock and a reordered frame would rewind it.
    private let deliveryQueue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.audio-relay", qos: .userInteractive)

    public init() {}

    public func upsert(_ sink: any OPNRemoteCoOpHostAudioSink) {
        lock.withLock {
            sinks[sink.participantID] = sink
            hasSinks = !sinks.isEmpty
        }
    }

    public func remove(participantID: UUID) {
        lock.withLock {
            sinks[participantID] = nil
            hasSinks = !sinks.isEmpty
        }
    }

    public func removeAll() {
        lock.withLock {
            sinks.removeAll()
            hasSinks = false
        }
    }

    public func activeSinkCount() -> Int {
        lock.withLock { sinks.count }
    }

    /// Called on the CoreAudio render thread, so the only work done here is the copy that has to
    /// happen before the caller's buffer goes away.
    ///
    /// Conversion used to run inline: two heap allocations plus an O(frameCount) interleave, per 10ms
    /// callback, on a thread with a hard deadline - and `Array(sinks.values)` took a lock contended
    /// against the MainActor on every guest join and leave. Both are unbounded waits, and the audible
    /// result was host crackle that appeared only once a guest connected. `deliveryQueue.async` alone
    /// was not enough: it deferred the sink calls but left everything above it on the render thread.
    ///
    /// `hasSinks` is read without the lock on purpose: it is a plain `Bool`, a stale read costs one
    /// frame either way, and a solo session must not pay a lock at all.
    public func renderAudioFrame(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard hasSinks, let audioBufferList else { return }
        let list = audioBufferList.assumingMemoryBound(to: AudioBufferList.self)
        // Raw bytes out of the caller's buffers, still on this thread because they are only valid for
        // the duration of this callback. Interleaving, resampling and Int16 packing happen off-thread.
        guard let raw = Self.rawInt16Copy(from: list) else { return }
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            let currentSinks = lock.withLock { Array(sinks.values) }
            guard !currentSinks.isEmpty,
                  let frame = Self.audioFrame(from: raw, frameCount: frameCount, sampleRate: sampleRate, channels: channels) else { return }
            for sink in currentSinks { sink.renderAudioFrame(frame) }
        }
    }

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
    /// the duration of the callback.
    ///
    /// Deliberately allocation-light rather than allocation-free: one `[Int16]` copy is the minimum
    /// that lets the caller's buffer be released on return. The interleave, resample and `Data` pack
    /// that used to allocate twice more here now happen on `deliveryQueue`.
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

    /// Both source layouts CoreAudio can hand over, off the render thread, reading the flat copy.
    static func audioFrame(from raw: RawInt16Buffers, frameCount: UInt32, sampleRate: Double, channels: UInt32) -> OPNRemoteCoOpHostAudioFrame? {
        let outputFrames = Int(frameCount)
        guard outputFrames > 0 else { return nil }
        let outputChannels = Int(OPNRemoteCoOpHostAudioFrame.channels)
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

        let resampled = resampledStereoPCM(stereo, sourceSampleRate: sampleRate, targetSampleRate: OPNRemoteCoOpHostAudioFrame.sampleRate)
        let data = resampled.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Int16>.size)
        }
        guard !data.isEmpty else { return nil }
        return OPNRemoteCoOpHostAudioFrame(samples: data, frameCount: UInt32(resampled.count / outputChannels))
    }

    public func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        deliver(frame, to: lock.withLock { Array(sinks.values) })
    }

    /// Off the caller's thread: every caller is a real-time audio callback.
    private func deliver(_ frame: OPNRemoteCoOpHostAudioFrame, to sinks: [any OPNRemoteCoOpHostAudioSink]) {
        guard !sinks.isEmpty else { return }
        deliveryQueue.async {
            for sink in sinks { sink.renderAudioFrame(frame) }
        }
    }

    /// Interleaved float samples, for an audio source that decodes PCM itself rather than going
    /// through libwebrtc's audio device - where the `AudioBufferList` entry point above never fires
    /// and a guest would otherwise hear silence.
    ///
    /// No production caller today: the socket-owned NVST audio path this was written for never
    /// worked and was removed, and bundle audio arrives through the entry point above instead. Kept
    /// because owning the audio path is still the standing plan for fixing NVST audio quality, and
    /// this is the seam a second attempt would feed. Called on a receive queue, so it returns before
    /// converting anything when nobody is listening.
    public func renderAudioSamples(_ samples: [Float], sampleRate: Double, channels: UInt32) {
        let currentSinks = lock.withLock { Array(sinks.values) }
        guard !currentSinks.isEmpty, !samples.isEmpty else { return }
        guard let frame = Self.audioFrame(fromInterleavedFloat: samples, sampleRate: sampleRate, channels: channels) else { return }
        deliver(frame, to: currentSinks)
    }

    static func audioFrame(fromInterleavedFloat samples: [Float], sampleRate: Double, channels: UInt32) -> OPNRemoteCoOpHostAudioFrame? {
        let sourceChannels = max(1, Int(channels))
        let sourceFrames = samples.count / sourceChannels
        guard sourceFrames > 0 else { return nil }
        let outputChannels = Int(OPNRemoteCoOpHostAudioFrame.channels)
        var stereo = [Int16](repeating: 0, count: sourceFrames * outputChannels)
        for frame in 0..<sourceFrames {
            let sourceIndex = frame * sourceChannels
            let left = samples[sourceIndex]
            let right = sourceChannels > 1 ? samples[sourceIndex + 1] : left
            stereo[frame * 2] = int16Sample(left)
            stereo[frame * 2 + 1] = int16Sample(right)
        }
        let resampled = resampledStereoPCM(stereo, sourceSampleRate: sampleRate, targetSampleRate: OPNRemoteCoOpHostAudioFrame.sampleRate)
        let data = resampled.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Int16>.size)
        }
        guard !data.isEmpty else { return nil }
        return OPNRemoteCoOpHostAudioFrame(samples: data, frameCount: UInt32(resampled.count / outputChannels))
    }

    /// Clamped before scaling: Opus can decode slightly past full scale and the wrap that
    /// `Int16(...)` would produce there is an audible click, not a quiet distortion.
    private static func int16Sample(_ value: Float) -> Int16 {
        Int16(max(-32768, min(32767, (max(-1, min(1, value)) * 32767).rounded())))
    }

    private static func resampledStereoPCM(_ samples: [Int16], sourceSampleRate: Double, targetSampleRate: Double) -> [Int16] {
        guard sourceSampleRate > 0, abs(sourceSampleRate - targetSampleRate) > 0.5 else { return samples }
        let sourceFrames = samples.count / Int(OPNRemoteCoOpHostAudioFrame.channels)
        guard sourceFrames > 1 else { return samples }
        let targetFrames = max(1, Int((Double(sourceFrames) * targetSampleRate / sourceSampleRate).rounded()))
        var output = [Int16](repeating: 0, count: targetFrames * Int(OPNRemoteCoOpHostAudioFrame.channels))
        for frame in 0..<targetFrames {
            let sourcePosition = Double(frame) * sourceSampleRate / targetSampleRate
            let lower = min(sourceFrames - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(sourceFrames - 1, lower + 1)
            let fraction = sourcePosition - Double(lower)
            for channel in 0..<Int(OPNRemoteCoOpHostAudioFrame.channels) {
                let a = Double(samples[lower * 2 + channel])
                let b = Double(samples[upper * 2 + channel])
                output[frame * 2 + channel] = Int16(max(Double(Int16.min), min(Double(Int16.max), a + ((b - a) * fraction))))
            }
        }
        return output
    }
}

@objc(OPNRemoteCoOpHostAudioDevice)
final class OPNRemoteCoOpHostAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    let lock = NSLock()
    private weak var delegate: RTCAudioDeviceDelegate?
    private var sampleIndex: UInt64 = 0

    private(set) var deviceInputSampleRate = OPNRemoteCoOpHostAudioFrame.sampleRate
    private(set) var inputIOBufferDuration: TimeInterval = 0.01
    private(set) var inputNumberOfChannels = Int(OPNRemoteCoOpHostAudioFrame.channels)
    private(set) var inputLatency: TimeInterval = 0
    private(set) var deviceOutputSampleRate = OPNRemoteCoOpHostAudioFrame.sampleRate
    private(set) var outputIOBufferDuration: TimeInterval = 0.01
    private(set) var outputNumberOfChannels = Int(OPNRemoteCoOpHostAudioFrame.channels)
    private(set) var outputLatency: TimeInterval = 0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock {
            self.delegate = delegate
            isInitialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        lock.withLock {
            delegate = nil
            isInitialized = false
            isPlayoutInitialized = false
            isPlaying = false
            isRecordingInitialized = false
            isRecording = false
            sampleIndex = 0
        }
        return true
    }

    func initializePlayout() -> Bool {
        lock.withLock { isPlayoutInitialized = true }
        return true
    }

    func startPlayout() -> Bool {
        lock.withLock { isPlaying = true }
        return true
    }

    func stopPlayout() -> Bool {
        lock.withLock { isPlaying = false }
        return true
    }

    func initializeRecording() -> Bool {
        lock.withLock { isRecordingInitialized = true }
        return true
    }

    func startRecording() -> Bool {
        lock.withLock {
            isRecordingInitialized = true
            isRecording = true
        }
        return true
    }

    func stopRecording() -> Bool {
        lock.withLock { isRecording = false }
        return true
    }

    func shutdown() {
        _ = terminateDevice()
    }

    func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        guard frame.frameCount > 0, frame.channels == OPNRemoteCoOpHostAudioFrame.channels else { return }
        let state = lock.withLock { () -> (RTCAudioDeviceDelegate, UInt64)? in
            guard isRecording, let delegate else { return nil }
            let currentSampleIndex = sampleIndex
            sampleIndex &+= UInt64(frame.frameCount)
            return (delegate, currentSampleIndex)
        }
        guard let state else { return }
        // The `renderBlock` form, not the pre-filled `inputData` form, and this is not a style
        // choice: the framework's `inputData` branch passes `num_frames` as the *element* count of
        // the span it hands `FineAudioBuffer`, where it owes `num_frames * channels`. With stereo
        // that reads half of every buffer and feeds the Opus encoder at half rate - chopped audio
        // plus permanent receiver starvation, which is exactly how "junky" sounded. The `renderBlock`
        // branch sizes its own buffer as `num_frames * channels_count` and is correct. Verified in
        // this repo's vendored WebRTC.framework
        // (Headers/sdk/objc/native/src/objc_audio_device.mm, `io_data` vs `render_block` branches)
        // and present in every upstream branch checked, so a framework bump will not fix it.
        frame.samples.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var actionFlags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(state.1)
            timestamp.mHostTime = mach_absolute_time()
            let sourceByteCount = bytes.count
            _ = state.0.deliverRecordedData(&actionFlags, &timestamp, 0, frame.frameCount, nil, nil) { _, _, _, _, inputData, _ in
                // WebRTC hands over a buffer it has already sized for `frameCount * channels`
                // samples; fill it and never write past what it declares.
                let buffers = UnsafeMutableAudioBufferListPointer(inputData)
                guard let destination = buffers.first?.mData else { return noErr }
                let capacity = Int(buffers[0].mDataByteSize)
                let copied = min(capacity, sourceByteCount)
                destination.copyMemory(from: baseAddress, byteCount: copied)
                if copied < capacity {
                    // Short source: silence the tail rather than leaving whatever was there.
                    destination.advanced(by: copied).initializeMemory(as: UInt8.self, repeating: 0, count: capacity - copied)
                }
                return noErr
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

import AVFoundation
import Foundation

/// Plays the seat's decoded audio through a ring buffer whose depth is the jitter buffer.
///
/// This exists because libwebrtc's NetEq could not be made to accept the seat's stream: it arrives
/// clean — zero loss, sequence steps of 1, timestamp steps of 240 — and NetEq still discarded ~86%
/// of it and filled the gaps with concealment, which is what "choppy, and noise when it should be
/// silent" sounds like. Owning the buffer means the only thing that can drop audio is us.
public final class NvstAudioPlayer: @unchecked Sendable {
    public static let sampleRate: Double = 48000
    public static let channels = 2
    /// How much audio to hold before starting playout. The seat's own jitter buffer settings ask
    /// for `initialThreshold:80` ms with a `thresholdBase:25`, so 60 ms sits inside what it expects
    /// to be buffered while keeping the added latency modest.
    public static let targetMilliseconds = 60
    /// The ring holds far more than the target so a burst cannot overwrite unplayed audio.
    static let capacityMilliseconds = 500

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    let lock = NSLock()
    private var ring: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var filled = 0
    private var isPriming = true

    private var enqueuedFrameCount: UInt64 = 0
    private var renderedFrameCount: UInt64 = 0
    /// Frames the render callback had to invent because the ring was empty. This is our own
    /// concealment, and unlike NetEq's it is visible and attributable.
    private var silenceFrameCount: UInt64 = 0
    private var underrunCount: UInt64 = 0
    private var overflowFrameCount: UInt64 = 0
    public private(set) var startFailure: String?

    /// Written under `lock` by the enqueue and render threads, so the reads take it too.
    public var enqueuedFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return enqueuedFrameCount }
    public var renderedFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return renderedFrameCount }
    public var silenceFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return silenceFrameCount }
    public var underruns: UInt64 { lock.lock(); defer { lock.unlock() }; return underrunCount }
    public var overflowFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return overflowFrameCount }

    private static func frames(milliseconds: Int) -> Int {
        Int(sampleRate) * milliseconds / 1000
    }

    public init() {
        ring = [Float](repeating: 0, count: Self.frames(milliseconds: Self.capacityMilliseconds) * Self.channels)
    }

    public func start() {
        guard sourceNode == nil else { return }
        // Engine nodes take non-interleaved float — `standardFormatWithSampleRate` is exactly that.
        // An interleaved format makes `connect(_:to:format:)` raise an Objective-C exception, which
        // Swift cannot catch, so this has to be right rather than guarded.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                         channels: AVAudioChannelCount(Self.channels)) else {
            startFailure = "unsupported output format"
            return
        }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let self else { return noErr }
            self.render(into: buffers, frameCount: Int(frameCount))
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            startFailure = error.localizedDescription
        }
    }

    public func stop() {
        guard let sourceNode else { return }
        engine.stop()
        engine.detach(sourceNode)
        self.sourceNode = nil
    }

    /// Adds decoded interleaved stereo samples.
    public func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if filled + samples.count > ring.count {
            // Drop a whole frame, never a single sample: the render side reads
            // `ring[readIndex + channel]`, so `readIndex` has to stay on a frame boundary.
            // Advancing it by one sample would swap left and right for the rest of the session.
            let excess = filled + samples.count - ring.count
            let droppedFrames = (excess + Self.channels - 1) / Self.channels
            let droppedSamples = droppedFrames * Self.channels
            readIndex = (readIndex + droppedSamples) % ring.count
            filled -= droppedSamples
            overflowFrameCount += UInt64(droppedFrames)
        }
        // Copy in at most two chunks (one per side of the wrap) instead of a per-sample loop:
        // ~480 samples a packet at ~200 packets a second made the loop the hot side of the lock.
        ring.withUnsafeMutableBufferPointer { destination in
            samples.withUnsafeBufferPointer { source in
                var copied = 0
                while copied < samples.count {
                    let chunk = min(ring.count - writeIndex, samples.count - copied)
                    destination.baseAddress!.advanced(by: writeIndex)
                        .update(from: source.baseAddress!.advanced(by: copied), count: chunk)
                    writeIndex = (writeIndex + chunk) % ring.count
                    copied += chunk
                }
            }
        }
        filled += samples.count
        enqueuedFrameCount += UInt64(samples.count / Self.channels)
        if isPriming, filled >= Self.frames(milliseconds: Self.targetMilliseconds) * Self.channels {
            isPriming = false
        }
    }

    /// Writes one render quantum, deinterleaving the ring into the engine's per-channel buffers.
    private func render(into buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let channels = (0..<buffers.count).compactMap { index -> UnsafeMutablePointer<Float>? in
            buffers[index].mData?.assumingMemoryBound(to: Float.self)
        }
        guard !channels.isEmpty else { return }
        func silence(from frame: Int) {
            for channel in channels where frame < frameCount {
                channel.advanced(by: frame).update(repeating: 0, count: frameCount - frame)
            }
        }

        // Never block the render thread. `enqueue` holds this lock only briefly, but a realtime
        // audio callback that waits on a producer's lock is a priority inversion, and the audible
        // result is worse than the silence a skipped quantum costs.
        guard lock.try() else {
            silence(from: 0)
            silenceFrameCount += UInt64(frameCount)
            return
        }
        defer { lock.unlock() }
        // While priming, output silence rather than starting on a nearly empty buffer and
        // immediately under-running.
        guard !isPriming else {
            silence(from: 0)
            silenceFrameCount += UInt64(frameCount)
            return
        }
        var frame = 0
        while frame < frameCount, filled >= Self.channels {
            for channel in 0..<min(channels.count, Self.channels) {
                channels[channel].advanced(by: frame).pointee = ring[(readIndex + channel) % ring.count]
            }
            readIndex = (readIndex + Self.channels) % ring.count
            filled -= Self.channels
            frame += 1
        }
        renderedFrameCount += UInt64(frame)
        if frame < frameCount {
            silence(from: frame)
            silenceFrameCount += UInt64(frameCount - frame)
            underrunCount += 1
            // Re-prime so playout resumes from a healthy depth instead of stuttering per callback.
            isPriming = true
        }
    }

    public var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let buffered = filled / Self.channels * 1000 / Int(Self.sampleRate)
        return "enq=\(enqueuedFrameCount) rendered=\(renderedFrameCount) silence=\(silenceFrameCount)"
            + " underruns=\(underrunCount) overflow=\(overflowFrameCount) buffered=\(buffered)ms"
            + (startFailure.map { " startErr=\($0)" } ?? "")
    }
}

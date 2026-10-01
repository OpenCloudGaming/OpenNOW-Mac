import Foundation

/// The game-audio receive path: SRTP in, interleaved PCM out.
///
/// Each stage already exists and is tested on its own — decryption, reordering, concealment
/// signalling, Opus decode — so this type's job is the ordering and the accounting between them.
/// The sequence it enforces is the one that matters: decrypt before reorder (a packet cannot be
/// ordered until its tag has been verified), and reorder before decode (Opus has no idea what order
/// frames arrived in).
public final class NvstAudioReceivePipeline: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var datagrams: UInt64 = 0
        public var authenticated: UInt64 = 0
        public var authenticationFailures: UInt64 = 0
        public var replayDrops: UInt64 = 0
        public var packetsDecoded: UInt64 = 0
        public var packetsLost: UInt64 = 0
        public var decodeFailures: UInt64 = 0
        public var concealedFrames: UInt64 = 0
        /// Frames that arrived as a repeat inside a later RED packet and were slotted back into
        /// their original position, so a loss never reached the decoder.
        public var recoveredPackets: UInt64 = 0
        public var malformedRedPackets: UInt64 = 0
        /// Everything that arrived on the socket, before any of it was judged.
        public var datagramBytes: UInt64 = 0
        /// Interleaved samples the decoder actually produced.
        public var decodedSamples: UInt64 = 0
        /// Decoded frames dropped to hold playout within `maximumBacklogFrames` of the seat.
        public var trimmedFrames: UInt64 = 0
        public var ssrc: UInt32?
    }

    /// The payload type the seat's redundant audio is wrapped in. The primary inside it is the
    /// codec's own type.
    public static let redundantPayloadType: UInt8 = 63

    /// Decoded audio kept beyond what the device just asked for: 40 ms. Arrival and playout run at
    /// the same rate, so anything above it is delay that would stay for the rest of the session —
    /// audio that piled up while the device was starting, or a late burst after an underrun.
    public static let maximumBacklogFrames = 1_920

    /// How far past `maximumBacklogFrames` the backlog may drift before it is trimmed: 10 ms. A hard
    /// ceiling trims on every pull, turning a steady clock drift into thousands of tiny drops.
    public static let backlogTrimHysteresisFrames = 480

    /// Packets a surround decoder may consume without producing a single frame before the layout is
    /// judged undecodable here. Opus's priming delay legitimately produces nothing for the first few.
    public static let packetsWithoutFramesLimit = 20

    public let framesPerPacket: Int

    /// Called once, on the thread that pulled, when the decoder has rejected the negotiated layout
    /// and the pipeline has rebuilt itself as stereo. `layout` already reads the new value.
    public var onLayoutFallback: (@Sendable (NvstOpusMultistreamLayout) -> Void)?

    private let srtp: NvstAudioSrtp
    private let lock = NSLock()
    private var decoder: any NvstOpusDecoding
    private var storedLayout: NvstOpusMultistreamLayout
    private var isStereoFallbackPending = false
    /// The decoder's own failure tally as it was last read, so the pipeline's total survives the
    /// decoder the fallback replaces — that tally restarts at zero with the new decoder.
    private var decoderFailuresAtLastRead: UInt64 = 0
    private var jitter: NvstAudioJitterBuffer
    private var counters = Counters()
    private var replayWindows: [UInt32: SrtpReplayWindow] = [:]
    private var bufferedSamples: [Float] = []
    private var sampleOffset = 0

    public init(srtp: NvstAudioSrtp,
                framesPerPacket: Int = NvstOpusDecoder.seatFramesPerPacket,
                layout: NvstOpusMultistreamLayout = .stereo,
                targetDepth: Int = 3) throws {
        self.srtp = srtp
        self.framesPerPacket = framesPerPacket
        self.storedLayout = layout
        self.jitter = NvstAudioJitterBuffer(targetDepth: targetDepth)
        self.decoder = try NvstOpusDecoder(framesPerPacket: framesPerPacket, layout: layout)
    }

    /// Test seam: builds the pipeline around a decoder supplied by the caller, so the fallback is
    /// testable where a surround decoder cannot be built. The rebuilt one is a real `NvstOpusDecoder`.
    init(srtp: NvstAudioSrtp,
         framesPerPacket: Int,
         layout: NvstOpusMultistreamLayout,
         targetDepth: Int,
         decoder: any NvstOpusDecoding) {
        self.srtp = srtp
        self.framesPerPacket = framesPerPacket
        self.storedLayout = layout
        self.jitter = NvstAudioJitterBuffer(targetDepth: targetDepth)
        self.decoder = decoder
    }

    public var snapshot: Counters { lock.withLock { counters } }

    /// The layout the pipeline is decoding right now: the negotiated one until the decoder proves it
    /// cannot decode it, then stereo.
    public var layout: NvstOpusMultistreamLayout { lock.withLock { storedLayout } }
    public var channels: Int { layout.channels }
    /// How long the emitted packets waited in the jitter buffer, and how many were emitted. The HUD
    /// divides one by the other for its A/V reading, exactly as it did over libwebrtc's counters.
    public var jitterBufferDwellSeconds: TimeInterval { lock.withLock { jitter.jitterBufferDelaySeconds } }
    public var jitterBufferEmittedCount: UInt64 { lock.withLock { jitter.jitterBufferEmittedCount } }

    /// Verifies and queues one datagram. A packet that fails its tag is counted and discarded: it is
    /// indistinguishable from an attacker's, and either way it is not audio.
    ///
    /// A RED packet carries repeats of earlier frames ahead of the frame it was sent for, so the
    /// repeats are slotted back at the sequences they belong to. If one of those was lost, this is
    /// where it is recovered — the seat sent it twice precisely so that a single loss would not
    /// reach the decoder.
    public func ingest(_ datagram: Data) {
        lock.lock()
        defer { lock.unlock() }
        counters.datagrams += 1
        counters.datagramBytes &+= UInt64(datagram.count)
        guard let header = NvstAudioRtpPacket.parse(datagram, tagLength: srtp.authenticationTagLength) else {
            counters.authenticationFailures += 1
            return
        }
        var replayWindow = replayWindows[header.ssrc] ?? SrtpReplayWindow()
        let index = replayWindow.estimatedIndex(for: header.sequenceNumber)
        guard replayWindow.wouldAccept(index) else {
            counters.replayDrops += 1
            return
        }
        do {
            let (packet, payload) = try srtp.unprotect(datagram, rolloverCounter: UInt32(truncatingIfNeeded: index >> 16))
            guard replayWindow.accept(index) else { return }
            replayWindows[packet.ssrc] = replayWindow
            counters.ssrc = packet.ssrc
            counters.authenticated += 1
            guard packet.payloadType == Self.redundantPayloadType else {
                jitter.insert(sequenceNumber: packet.sequenceNumber, payload: payload)
                return
            }
            guard let blocks = NvstRedAudio.split(payload), let primary = blocks.last else {
                counters.malformedRedPackets += 1
                return
            }
            for repeatBlock in blocks.dropLast() {
                let framesBack = Int(repeatBlock.timestampOffset) / max(1, framesPerPacket)
                let sequence = packet.sequenceNumber &- UInt16(truncatingIfNeeded: framesBack)
                jitter.insert(sequenceNumber: sequence, payload: repeatBlock.payload)
                counters.recoveredPackets += 1
            }
            jitter.insert(sequenceNumber: packet.sequenceNumber, payload: primary.payload)
        } catch {
            counters.authenticationFailures += 1
        }
    }

    /// Emits the frames that are ready, in order, with a silent frame standing in for each packet
    /// that never arrived.
    ///
    /// Timing is what concealment has to preserve here: the caller is feeding a device that expects
    /// a fixed rate, so a gap must still consume its 5 ms. Opus's own packet-loss concealment would
    /// fill that gap with extrapolated audio rather than silence, but `AudioConverter` does not
    /// expose it, so silence is used and counted.
    public func pull() -> [Float] {
        withPullLock {
            defer { bufferedSamples.removeAll(keepingCapacity: true); sampleOffset = 0 }
            return Array(bufferedSamples.dropFirst(sampleOffset)) + drain(jitter.advance())
        }
    }

    public func pull(sampleCount: Int) -> [Float] {
        withPullLock { pullLocked(sampleCount: sampleCount) }
    }

    /// Runs a pull under the lock and delivers any stereo fallback it produced afterwards: the owner
    /// swaps the matrix its render thread uses, so calling it from under this lock would deadlock it.
    private func withPullLock(_ pullUnderLock: () -> [Float]) -> [Float] {
        let (samples, fallback) = lock.withLock { (pullUnderLock(), applyStereoFallbackLocked()) }
        if let fallback { onLayoutFallback?(fallback) }
        return samples
    }

    private func pullLocked(sampleCount: Int) -> [Float] {
        guard sampleCount > 0 else { return [] }
        if sampleOffset > 0 {
            bufferedSamples.removeFirst(sampleOffset)
            sampleOffset = 0
        }
        bufferedSamples.append(contentsOf: drain(jitter.advance()))
        let channels = storedLayout.channels
        let excessFrames = (bufferedSamples.count - sampleCount) / max(1, channels) - Self.maximumBacklogFrames
        if excessFrames > Self.backlogTrimHysteresisFrames {
            bufferedSamples.removeFirst(excessFrames * channels)
            counters.trimmedFrames &+= UInt64(excessFrames)
        }
        let count = min(sampleCount, bufferedSamples.count)
        sampleOffset = count
        return Array(bufferedSamples.prefix(count))
    }

    /// Whether the decoder is failing to decode `layout`: a surround decoder that has consumed
    /// `packetsWithoutFramesLimit` packets without one frame is not decoding what it was built for.
    private func isFailingToDecode(_ layout: NvstOpusMultistreamLayout) -> Bool {
        layout.isSurround
            && decoder.decodedFrames == 0
            && decoder.decodedPackets >= Self.packetsWithoutFramesLimit
    }

    /// Rebuilds the decoder as stereo once the negotiated layout has proved undecodable, so a
    /// mis-describing seat degrades to working stereo instead of playing silence all session.
    private func applyStereoFallbackLocked() -> NvstOpusMultistreamLayout? {
        guard isStereoFallbackPending, storedLayout.isSurround else { return nil }
        isStereoFallbackPending = false
        guard let stereo = try? NvstOpusDecoder(framesPerPacket: framesPerPacket, layout: .stereo) else { return nil }
        decoder = stereo
        storedLayout = .stereo
        decoderFailuresAtLastRead = 0
        // Everything buffered is in the old width, and nothing that decoded so far was usable.
        bufferedSamples.removeAll(keepingCapacity: true)
        sampleOffset = 0
        return .stereo
    }

    /// Emits everything still held; the stream is ending, so nothing should be left behind.
    public func flush() -> [Float] {
        lock.withLock {
            defer { bufferedSamples.removeAll(keepingCapacity: true); sampleOffset = 0 }
            return Array(bufferedSamples.dropFirst(sampleOffset)) + drain(jitter.flush())
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        jitter.reset()
        replayWindows.removeAll()
        bufferedSamples.removeAll(keepingCapacity: true)
        sampleOffset = 0
    }

    private func drain(_ emissions: [NvstAudioJitterBuffer.Emission]) -> [Float] {
        var output: [Float] = []
        for emission in emissions {
            switch emission {
            case .payload(let payload):
                do {
                    if let decoded = try decoder.decode(payload) {
                        output.append(contentsOf: decoded)
                        counters.packetsDecoded += 1
                        counters.decodedSamples &+= UInt64(decoded.count)
                    }
                } catch {
                    output.append(contentsOf: silence())
                }
            case .lost:
                counters.packetsLost += 1
                counters.concealedFrames += UInt64(framesPerPacket)
                output.append(contentsOf: silence())
            }
        }
        // A rejected packet shows up in the decoder's counters rather than as a thrown error, so its
        // tally is the only honest record of one — and the pipeline's health is read from the same place.
        let failures = decoder.failedPackets
        if failures > decoderFailuresAtLastRead {
            counters.decodeFailures &+= failures - decoderFailuresAtLastRead
        }
        decoderFailuresAtLastRead = failures
        if isFailingToDecode(storedLayout) { isStereoFallbackPending = true }
        return output
    }

    private func silence() -> [Float] {
        [Float](repeating: 0, count: framesPerPacket * storedLayout.channels)
    }

}

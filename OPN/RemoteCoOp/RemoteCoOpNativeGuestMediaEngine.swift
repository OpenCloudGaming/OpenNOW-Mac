import CoreMedia
import CoreVideo
import Foundation

/// The guest's media engine: reassemble the host's forwarded access units, decode them with the
/// stream's own codec, play the forwarded PCM, and report. It is the part the listener (the CLI and
/// the in-app spike window) and the session connection both drive, so decoding cannot drift between
/// the two ways a guest can receive.
final class RemoteCoOpNativeGuestMediaEngine: @unchecked Sendable {
    struct Stats: Equatable, Sendable {
        var datagrams: UInt64 = 0
        var reassembled: UInt64 = 0
        var decoded: UInt64 = 0
        var failures: UInt64 = 0
        var audioChunks: UInt64 = 0
        var width = 0
        var height = 0
        var framesPerSecond = 0.0
        var megabitsPerSecond = 0.0
        var codecName = "—"

        var resolutionText: String { width > 0 ? "\(width)x\(height)" : "—" }

        /// The guest's own measurements, as the stats overlay shows them.
        var overlayText: String {
            var parts: [String] = []
            if width > 0, height > 0 { parts.append("\(width)x\(height)") }
            parts.append(framesPerSecond > 0 ? String(format: "%.0f fps", framesPerSecond) : "— fps")
            parts.append(String(format: "%.1f Mbps", megabitsPerSecond))
            parts.append("decoded \(decoded)")
            if failures > 0 { parts.append("missed \(failures)") }
            return parts.joined(separator: "  ·  ")
        }
    }

    /// Called on the engine's queue with each decoded frame. Rendering is thread-safe, so it is handed
    /// straight over rather than hopped to the main actor at stream cadence.
    var onFrame: (@Sendable (OPNVideoFrame) -> Void)?
    /// Called once a second with the window's measurements.
    var onStats: (@Sendable (Stats) -> Void)?
    /// Connection-state text for the UI.
    var onState: (@Sendable (String) -> Void)?

    private let queue: DispatchQueue
    private let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
    private var decoder: NvstVideoToolboxDecoder?
    private var decoderCodec: NVSTVideoCodec?
    private var reporter: DispatchSourceTimer?
    private let audioBuffer = RemoteCoOpNativeAudioPlayoutBuffer()
    private var audioDevice: NvstCoreAudioDevice?
    private var didAnnounceAudio = false

    private let counterLock = NSLock()
    private var counters = Stats()
    private var windowDatagrams: UInt64 = 0
    private var windowBytes: UInt64 = 0
    private var windowDecoded: UInt64 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
        startReporter()
    }

    /// Feeds one datagram. Safe to call from any thread; the engine serializes on its own queue.
    func ingest(_ datagram: Data) {
        counterLock.lock()
        windowDatagrams &+= 1
        windowBytes &+= UInt64(datagram.count)
        counters.datagrams &+= 1
        counterLock.unlock()
        if OPNRemoteCoOpAudioPacket.isAudioDatagram(datagram) {
            queue.async { self.receiveAudio(datagram) }
        } else {
            queue.async { self.decode(datagram) }
        }
    }

    func reset() {
        counterLock.lock()
        counters = Stats()
        windowDatagrams = 0
        windowBytes = 0
        windowDecoded = 0
        counterLock.unlock()
        queue.async {
            self.audioDevice?.stop()
            self.audioDevice = nil
            self.audioBuffer.reset()
            self.didAnnounceAudio = false
            self.decoder = nil
            self.decoderCodec = nil
        }
    }

    func stop() {
        reporter?.cancel()
        reporter = nil
        queue.sync {
            self.audioDevice?.stop()
            self.audioDevice = nil
            self.audioBuffer.reset()
        }
    }

    private func receiveAudio(_ data: Data) {
        guard let (header, payload) = OPNRemoteCoOpAudioPacket.decode(data), !payload.isEmpty else { return }
        let samples = payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard !samples.isEmpty else { return }
        startAudioIfNeeded(sampleRate: Int(header.sampleRate), channels: Int(header.channels))
        _ = audioBuffer.append(samples)
        counterLock.lock(); counters.audioChunks &+= 1; counterLock.unlock()
    }

    private func startAudioIfNeeded(sampleRate: Int, channels: Int) {
        guard audioDevice == nil else { return }
        let device = NvstCoreAudioDevice(playoutChannelCount: max(1, min(2, channels)), capturesMicrophone: false)
        device.fillPlayout = { [weak self] destination, sampleCount in
            self?.audioBuffer.fill(destination, count: sampleCount)
        }
        device.start()
        audioDevice = device
        guard !didAnnounceAudio else { return }
        didAnnounceAudio = true
        onState?("Playing game audio.")
    }

    private func decode(_ data: Data) {
        guard let frame = reassembler.ingest(data) else { return }
        counterLock.lock(); counters.reassembled &+= 1; counterLock.unlock()

        guard let codec = Self.videoCodec(for: frame.codec) else { return }
        if decoder == nil || decoderCodec != codec {
            let created = NvstVideoToolboxDecoder(codec: codec)
            created.onPixelBuffer = { [weak self] pixelBuffer, presentationTime, isKeyframe in
                self?.deliver(pixelBuffer, presentationTime: presentationTime, isKeyframe: isKeyframe)
            }
            decoder = created
            decoderCodec = codec
            onState?("Decoding \(codec.rawValue).")
        }
        guard let decoder else { return }
        let unit = NvstAccessUnit(frameIndex: 0,
                                  firstStreamPacketIndex: 0,
                                  rtpTimestamp: UInt32(truncatingIfNeeded: frame.timestamp.nanoseconds / 100_000 * 9),
                                  isKeyframe: frame.isKeyFrame,
                                  bytes: frame.payload)
        do {
            try decoder.decode(unit)
        } catch {
            counterLock.lock(); counters.failures &+= 1; counterLock.unlock()
        }
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool) {
        counterLock.lock()
        counters.decoded &+= 1
        windowDecoded &+= 1
        counters.width = CVPixelBufferGetWidth(pixelBuffer)
        counters.height = CVPixelBufferGetHeight(pixelBuffer)
        counterLock.unlock()
        onFrame?(OPNVideoFrame(pixelBuffer: pixelBuffer,
                               presentationTime: presentationTime,
                               rotation: .none,
                               isKeyframe: isKeyframe))
    }

    private func startReporter() {
        reporter?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reportWindow() }
        timer.resume()
        reporter = timer
    }

    private func reportWindow() {
        counterLock.lock()
        let decodedDelta = windowDecoded
        let byteDelta = windowBytes
        windowDatagrams = 0
        windowBytes = 0
        windowDecoded = 0
        var snapshot = counters
        snapshot.framesPerSecond = Double(decodedDelta)
        snapshot.megabitsPerSecond = Double(byteDelta) * 8 / 1_000_000
        counterLock.unlock()
        onStats?(snapshot)
    }

    static func videoCodec(for codec: NativeNVSTVideoCodec) -> NVSTVideoCodec? {
        switch codec {
        case .h264: .h264
        case .h265: .hevc
        case .av1: .av1
        case .unknown: nil
        }
    }
}

enum RemoteCoOpNativeGuestError: LocalizedError, Equatable {
    case invalidPort(UInt16)
    case invalidConnection

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "UDP \(port) is not a usable port."
        case .invalidConnection: "The host's connection details are incomplete."
        }
    }
}

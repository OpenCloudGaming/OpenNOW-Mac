import AudioToolbox
import Foundation
import Network

/// M0 spike: forwards the host's *source* compressed video to one native guest over UDP, so a guest
/// can decode what the seat encoded instead of a re-encode of the decoded picture.
///
/// Deliberately narrow and env-gated: it exists to answer "does a native guest decode the source
/// stream, and how good/fast is it?" before any of the session, adaptation or traversal work. It is
/// one-way (host → guest), unencrypted and LAN-only, and it must not be mistaken for the real
/// transport. `OPENNOW_COOP_SPIKE_FORWARD=host:port` enables it for a run.
public final class OPNRemoteCoOpSpikeForwarder: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var framesForwarded: UInt64 = 0
        public var framesDropped: UInt64 = 0
        public var datagramsSent: UInt64 = 0
        public var bytesSent: UInt64 = 0
    }

    public static let environmentKey = "OPENNOW_COOP_SPIKE_FORWARD"
    public static let defaultsKey = "OpenNOW.CoOpSpikeForward"

    public let destination: String

    /// Frames allowed to wait for the socket before the newest is dropped. A stalled link must cost
    /// the spike frames, never the live decode it is tapped off.
    private static let maximumPendingFrames = 8

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.spike-forward")
    private let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
    private let lock = NSLock()
    private var pendingFrames = 0
    private var nextAudioSequence: UInt64 = 0
    private var counters = Counters()
    private let logger: (@Sendable (String) -> Void)?

    /// Builds a forwarder only when a destination is explicitly configured, from the environment or
    /// `defaults`. Off by default: the session path is the broadcaster, and a forwarder pointed at a
    /// port nobody listens on makes macOS answer every datagram with `ECONNREFUSED`.
    public static func configured(logger: (@Sendable (String) -> Void)? = nil) -> OPNRemoteCoOpSpikeForwarder? {
        let configuredDestination = ProcessInfo.processInfo.environment[environmentKey]
            ?? UserDefaults.standard.string(forKey: defaultsKey)
        guard let destination = configuredDestination, !destination.isEmpty else { return nil }
        guard let forwarder = OPNRemoteCoOpSpikeForwarder(destination: destination, logger: logger) else {
            logger?("Co-Op spike: could not parse destination \"\(destination)\" (expected host:port)")
            return nil
        }
        return forwarder
    }

    /// `destination` is `host:port`. Fails when either part is missing or out of range.
    public init?(destination: String, logger: (@Sendable (String) -> Void)? = nil) {
        let parts = destination.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let host = String(parts[0])
        guard !host.isEmpty else { return nil }
        self.destination = destination
        self.logger = logger
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        connection.stateUpdateHandler = { state in
            logger?("Co-Op spike forwarder \(host):\(port) \(String(describing: state))")
        }
        connection.start(queue: queue)
    }

    /// Enqueues a frame. Called from the decode path, so it returns immediately.
    public func forward(_ frame: NativeNVSTVideoFrame) {
        lock.lock()
        guard pendingFrames < Self.maximumPendingFrames else {
            counters.framesDropped &+= 1
            lock.unlock()
            return
        }
        pendingFrames += 1
        lock.unlock()

        let datagrams = fragmenter.fragments(for: frame)
        queue.async { [weak self] in
            guard let self else { return }
            for datagram in datagrams {
                connection.send(content: datagram, contentContext: .defaultMessage, isComplete: true, completion: .idempotent)
            }
            lock.lock()
            pendingFrames = max(0, pendingFrames - 1)
            counters.framesForwarded &+= 1
            counters.datagramsSent &+= UInt64(datagrams.count)
            counters.bytesSent &+= UInt64(datagrams.reduce(0) { $0 + $1.count })
            lock.unlock()
        }
    }

    public var snapshot: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Forwards one game-audio callback as PCM, chunked to stay under a path MTU. Video and audio
    /// share the socket; the guest tells them apart by the packet's magic.
    public func forwardAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList else { return }
        let list = audioBufferList.assumingMemoryBound(to: AudioBufferList.self)
        guard let raw = RemoteCoOpNativeAudioConversion.rawInt16Copy(from: list),
              let frame = RemoteCoOpNativeAudioConversion.audioFrame(from: raw, frameCount: frameCount, sampleRate: sampleRate, channels: channels) else { return }
        sendAudio(frame)
    }

    private func sendAudio(_ frame: RemoteCoOpNativeAudioFrame) {
        lock.lock()
        let startSequence = nextAudioSequence
        lock.unlock()
        let result = RemoteCoOpNativeAudioChunker.datagrams(from: frame,
                                                            startingSequence: startSequence,
                                                            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds)
        guard !result.datagrams.isEmpty else { return }
        lock.lock()
        nextAudioSequence = result.nextSequence
        lock.unlock()
        for datagram in result.datagrams {
            queue.async { [weak self] in
                self?.connection.send(content: datagram, contentContext: .defaultMessage, isComplete: true, completion: .idempotent)
            }
        }
    }

    public func stop() {
        connection.cancel()
    }
}

import Darwin
import Foundation

/// Receives the seat's Opus audio on a socket we own, decodes it and plays it out.
///
/// Audio was previously left to libwebrtc on the ICE/DTLS bundle. That works as far as delivery —
/// the packets arrive, decrypt and decode — but NetEq discarded about 86% of a stream measured to
/// be clean and filled the gaps with concealment. Taking the stream onto its own socket puts the
/// jitter buffer under our control, the same way video already owns its Mjolnir socket.
///
/// `runtime.audioSrtp:0` in both our ANNOUNCE and the captured official one says this leg is not
/// SRTP-protected, so there is no crypto here — unlike video, which is keyed from
/// `runtime.encryptionKey`.
public final class NvstAudioReceiver: @unchecked Sendable {
    public struct Counters: Sendable {
        public var datagrams: UInt64 = 0
        public var rtpPackets: UInt64 = 0
        public var bytes: UInt64 = 0
        public var nonRtp: UInt64 = 0
        public var duplicates: UInt64 = 0
        public var reordered: UInt64 = 0
        public var gaps: UInt64 = 0
        public var payloadTypes: [UInt8: UInt64] = [:]
        public var timestampSteps: [UInt32: UInt64] = [:]

        public var summary: String {
            "in=\(datagrams) rtp=\(rtpPackets) bytes=\(bytes) nonRtp=\(nonRtp)"
                + " dup=\(duplicates) reordered=\(reordered) gaps=\(gaps)"
                + " pt=\(payloadTypes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
                + " tsStep=\(timestampSteps.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)x\($0.value)" }.joined(separator: ","))"
        }
    }

    private let descriptor: Int32
    private var peer = sockaddr_in()
    private let queue = DispatchQueue(label: "com.macforcenow.nvst.audio")
    private var readSource: DispatchSourceRead?
    private var punchTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var counters = Counters()
    private var lastSequence: UInt16?
    private var lastTimestamp: UInt32?
    private var handoff: NVSTVideoHandoff?
    /// Checked by the punch timer: cancellation is asynchronous, so a handler already in flight
    /// could otherwise `sendto` a descriptor the read source's cancel handler has closed — and a
    /// closed descriptor number can be reused by something else.
    private var isStopped = false
    private let decoder: NvstOpusDecoder
    private let player: NvstAudioPlayer

    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// The port the seat is told to send audio to.
    public let localPort: UInt16

    /// - Parameter existingDescriptor: the socket reserved before ANNOUNCE, so the port the seat
    ///   was told about is the port that stays bound and NAT-mapped. A negative value binds a fresh
    ///   ephemeral socket instead.
    public init(existingDescriptor: Int32 = -1, framesPerPacket: Int = 240) throws {
        decoder = try NvstOpusDecoder(framesPerPacket: framesPerPacket)
        player = NvstAudioPlayer()

        if existingDescriptor >= 0 {
            descriptor = existingDescriptor
        } else {
            descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            guard descriptor >= 0 else { throw NvstAudioReceiverError.socketUnavailable(errno) }
        }
        let handle = descriptor
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        _ = NvstMjolnirReceiver.growReceiveBuffer(handle, first: 1024 * 1024, last: 128 * 1024)

        if existingDescriptor < 0 {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = INADDR_ANY
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                close(handle)
                throw NvstAudioReceiverError.bindFailed(errno)
            }
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        localPort = UInt16(bigEndian: assigned.sin_port)
    }

    /// Once a dispatch source owns the descriptor, only its cancel handler may close it: closing
    /// underneath a source that is still cancelling risks EBADF, or worse, acting on a descriptor
    /// number the kernel has already handed to something else.
    private var closesDescriptorOnDeinit = true

    deinit {
        if closesDescriptorOnDeinit { close(descriptor) }
    }

    /// - Parameters:
    ///   - peerPort: the port the audio stream's own SETUP named, not the video one.
    ///   - handoff: supplies the ping payload and ICE credentials. The seat's media relay arms only
    ///     for a STUN Binding Request whose USERNAME is `<ping payload>:<local ufrag>` — the same
    ///     punch the video socket uses. A literal "PING" leaves the relay silent, which is exactly
    ///     what happened before this.
    public func start(peerIP: String, peerPort: UInt16, handoff: NVSTVideoHandoff) {
        self.handoff = handoff
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = peerPort.bigEndian
        target.sin_addr.s_addr = inet_addr(peerIP)
        peer = target
        player.start()
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        let handle = descriptor
        source.setCancelHandler { close(handle) }
        closesDescriptorOnDeinit = false
        source.resume()
        readSource = source

        // The seat has to be able to reach a port behind NAT, and it never sends here first, so the
        // mapping has to be opened from this side and kept alive.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.punch() }
        timer.resume()
        punchTimer = timer
        onDiagnostic?("NVST audio receiver listening on port \(localPort)")
    }

    public func stop() {
        isStopped = true
        punchTimer?.cancel()
        punchTimer = nil
        readSource?.cancel()
        readSource = nil
        player.stop()
    }

    private func punch() {
        guard !isStopped else { return }
        var target = peer
        guard let handoff, let credentials = handoff.iceCredentials,
              let payload = NvstStunHolePunch.buildNattHolePunchRequest(
                  localUfrag: credentials.localUsernameFragment,
                  pingPayload: handoff.pingPayload,
                  remotePassword: Data(credentials.remotePassword.utf8),
                  transactionID: NvstBundleIceProbe.transactionID()
              ) else { return }
        _ = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, sockaddrPointer,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<64 {
            let received = recv(descriptor, &buffer, buffer.count, 0)
            if received <= 0 { return }
            handle(Data(buffer[0..<received]))
        }
    }

    private func handle(_ datagram: Data) {
        lock.lock()
        counters.datagrams += 1
        counters.bytes += UInt64(datagram.count)
        lock.unlock()

        // RTP: version 2, and enough room for a header.
        guard datagram.count > 12, datagram[0] >> 6 == 2 else {
            lock.lock(); counters.nonRtp += 1; lock.unlock()
            return
        }
        let csrcCount = Int(datagram[0] & 0x0f)
        var offset = 12 + csrcCount * 4
        if datagram[0] & 0x10 != 0 {
            guard datagram.count >= offset + 4 else { return }
            let words = Int(datagram[offset + 2]) << 8 | Int(datagram[offset + 3])
            offset += 4 + words * 4
        }
        guard datagram.count > offset else { return }

        let payloadType = datagram[1] & 0x7f
        let sequence = UInt16(datagram[2]) << 8 | UInt16(datagram[3])
        let timestamp = (UInt32(datagram[4]) << 24) | (UInt32(datagram[5]) << 16)
            | (UInt32(datagram[6]) << 8) | UInt32(datagram[7])

        lock.lock()
        counters.rtpPackets += 1
        counters.payloadTypes[payloadType, default: 0] += 1
        if let previous = lastTimestamp {
            counters.timestampSteps[timestamp &- previous, default: 0] += 1
        }
        var accept = true
        if let previous = lastSequence {
            let delta = Int16(bitPattern: sequence &- previous)
            if delta == 0 { counters.duplicates += 1; accept = false }
            else if delta < 0 { counters.reordered += 1; accept = false }
            else if delta > 1 { counters.gaps += 1 }
        }
        if accept {
            lastSequence = sequence
            lastTimestamp = timestamp
        }
        lock.unlock()
        guard accept else { return }

        let payload = Data(datagram[offset...])
        do {
            if let pcm = try decoder.decode(payload) { player.enqueue(pcm) }
        } catch {
            onDiagnostic?("NVST audio decode error: \(error.localizedDescription)")
        }
    }

    public var snapshot: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    public var diagnosticSummary: String {
        "\(snapshot.summary) decoded=\(decoder.decodedPackets) decodeFailed=\(decoder.failedPackets)"
            + " frames=\(decoder.framesPerPacketSummary) \(player.summary)"
    }
}

public enum NvstAudioReceiverError: LocalizedError, Equatable, Sendable {
    case socketUnavailable(Int32)
    case bindFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable(let code): "Could not open the NVST audio socket (errno \(code))."
        case .bindFailed(let code): "Could not bind the NVST audio socket (errno \(code))."
        }
    }
}

import AudioToolbox
import Foundation
import Network

/// Host side of the native Co-Op media transport. One UDP port serves every guest: a guest sends a
/// `hello` carrying its token, the broadcaster binds that token to the datagram's source endpoint and
/// starts sending the game's compressed video and PCM audio there. Input arrives on the same port and
/// is routed by token, so one socket carries both directions and neither side has to learn the other's
/// address out of band.
public final class RemoteCoOpNativeMediaBroadcaster: @unchecked Sendable {
    public var onState: (@Sendable (String) -> Void)?
    /// Called when a guest's flow binds, so the host can pull a keyframe for it promptly.
    public var onGuestBound: (@Sendable () -> Void)?

    /// True while any guest's flow is bound; the host only needs to request keyframes then.
    public var hasBoundGuests: Bool {
        lock.lock(); defer { lock.unlock() }
        return !connectionByParticipant.isEmpty
    }

    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.native-broadcaster")
    private let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var startTask: Task<UInt16, Error>?
    private var tokenByParticipant: [UUID: String] = [:]
    private var participantByToken: [String: UUID] = [:]
    private var connectionByParticipant: [UUID: NWConnection] = [:]
    private var inputByParticipant: [UUID: @Sendable (OPNRemoteCoOpInputPacket) -> Void] = [:]
    private var audioSequence: UInt64 = 0

    public init() {}

    /// Idempotent: the first caller binds, later callers share that port. Host peers call it when they
    /// start, so several guests joining at once do not race to bind or get different ports.
    public func start() async throws -> UInt16 {
        switch startDecision() {
        case .ready(let port):
            return port
        case .join(let task):
            return try await task.value
        case .create(let task):
            do {
                let port = try await task.value
                storeBoundPort(port)
                return port
            } catch {
                clearStartTask()
                throw error
            }
        }
    }

    private enum StartDecision {
        case ready(UInt16)
        case join(Task<UInt16, Error>)
        case create(Task<UInt16, Error>)
    }

    private func startDecision() -> StartDecision {
        lock.lock()
        defer { lock.unlock() }
        if let boundPort { return .ready(boundPort) }
        if let startTask { return .join(startTask) }
        let task = Task<UInt16, Error> { [weak self] in
            guard let self else { throw RemoteCoOpNativeMediaError.stopped }
            return try await self.bindListener()
        }
        startTask = task
        return .create(task)
    }

    private func storeBoundPort(_ port: UInt16) {
        lock.lock(); boundPort = port; startTask = nil; lock.unlock()
    }

    private func clearStartTask() {
        lock.lock(); startTask = nil; lock.unlock()
    }

    private func bindListener() async throws -> UInt16 {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let once = OnceFlag()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let bound = listener.port?.rawValue, once.claim() else { return }
                    lock.lock(); self.listener = listener; lock.unlock()
                    continuation.resume(returning: bound)
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: queue)
                receiveNext(on: connection)
            }
            listener.start(queue: queue)
        }
        onState?("Media on UDP \(port).")
        return port
    }

    public func register(participantID: UUID, token: String, onInput: @escaping @Sendable (OPNRemoteCoOpInputPacket) -> Void) {        lock.lock()
        tokenByParticipant[participantID] = token
        participantByToken[token] = participantID
        inputByParticipant[participantID] = onInput
        lock.unlock()
    }

    public func unregister(participantID: UUID) {
        lock.lock()
        if let token = tokenByParticipant.removeValue(forKey: participantID) { participantByToken[token] = nil }
        let connection = connectionByParticipant.removeValue(forKey: participantID)
        inputByParticipant[participantID] = nil
        lock.unlock()
        connection?.cancel()
    }

    public func removeAll() {
        lock.lock()
        let connections = Array(connectionByParticipant.values)
        connectionByParticipant.removeAll()
        tokenByParticipant.removeAll()
        participantByToken.removeAll()
        inputByParticipant.removeAll()
        lock.unlock()
        for connection in connections { connection.cancel() }
    }

    public func forward(video: NativeNVSTVideoFrame) {
        sendToReady(fragmenter.fragments(for: video))
    }

    public func forwardAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList else { return }
        let list = audioBufferList.assumingMemoryBound(to: AudioBufferList.self)
        guard let raw = RemoteCoOpNativeAudioConversion.rawInt16Copy(from: list),
              let frame = RemoteCoOpNativeAudioConversion.audioFrame(from: raw, frameCount: frameCount, sampleRate: sampleRate, channels: channels) else { return }
        lock.lock()
        let startSequence = audioSequence
        lock.unlock()
        let result = RemoteCoOpNativeAudioChunker.datagrams(from: frame,
                                                            startingSequence: startSequence,
                                                            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds)
        guard !result.datagrams.isEmpty else { return }
        lock.lock()
        audioSequence = result.nextSequence
        lock.unlock()
        sendToReady(result.datagrams)
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        let connections = Array(connectionByParticipant.values)
        self.listener = nil
        boundPort = nil
        startTask = nil
        connectionByParticipant.removeAll()
        tokenByParticipant.removeAll()
        participantByToken.removeAll()
        inputByParticipant.removeAll()
        lock.unlock()
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private func sendToReady(_ datagrams: [Data]) {
        guard !datagrams.isEmpty else { return }
        lock.lock()
        let connections = Array(connectionByParticipant.values)
        lock.unlock()
        guard !connections.isEmpty else { return }
        let batch = datagrams
        queue.async { [weak self] in
            for connection in connections {
                for datagram in batch {
                    connection.send(content: datagram, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                        if error != nil { self?.drop(connection: connection) }
                    })
                }
            }
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                queue.async { self.handleControl(data, from: connection) }
            }
            if error == nil { receiveNext(on: connection) }
        }
    }

    private func handleControl(_ data: Data, from connection: NWConnection) {
        guard let packet = OPNRemoteCoOpNativeControlPacket.decode(data) else { return }
        switch packet.kind {
        case .hello:
            bind(token: packet.token, connection: connection)
        case .input:
            routeInput(token: packet.token, payload: packet.payload)
        }
    }

    private func bind(token: String, connection: NWConnection) {
        lock.lock()
        let participantID = participantByToken[token]
        if let participantID { connectionByParticipant[participantID] = connection }
        lock.unlock()
        guard participantID != nil else { return }
        onState?("A guest's media flow is bound.")
        onGuestBound?()
        // A guest that vanishes without signalling leaves a dead UDP endpoint; sending to it makes
        // macOS answer every datagram with ECONNREFUSED. Drop the binding as soon as the socket says so.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(connection: connection)
            default: break
            }
        }
    }

    /// Removes every participant bound to `connection` and closes it.
    private func drop(connection: NWConnection) {
        lock.lock()
        let participants = connectionByParticipant.filter { $0.value === connection }.map(\.key)
        for participantID in participants { connectionByParticipant[participantID] = nil }
        lock.unlock()
        connection.cancel()
    }

    private func routeInput(token: String, payload: Data) {
        lock.lock()
        let participantID = participantByToken[token]
        let handler = participantID.flatMap { inputByParticipant[$0] }
        lock.unlock()
        guard let handler, let packet = OPNRemoteCoOpInputBinaryCodec.decode(payload) else { return }
        handler(packet)
    }
}

/// Resumes a continuation exactly once, whichever listener state arrives first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isUsed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isUsed else { return false }
        isUsed = true
        return true
    }
}

enum RemoteCoOpNativeMediaError: LocalizedError, Equatable {
    case stopped

    var errorDescription: String? {
        switch self {
        case .stopped: "The native Co-Op media broadcaster is not running."
        }
    }
}

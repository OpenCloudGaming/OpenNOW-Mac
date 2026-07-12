import Foundation

public enum OPNRemoteCoOpHostPeerError: LocalizedError, Equatable, Sendable {
    case peerNotFound
    case invalidSignal
    case negotiationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .peerNotFound: "Remote Co-Op peer was not found."
        case .invalidSignal: "Remote Co-Op peer signal is invalid."
        case .negotiationFailed(let message): message.isEmpty ? "Remote Co-Op WebRTC negotiation failed." : message
        }
    }
}

public struct OPNRemoteCoOpHostPeerCallbacks: Sendable {
    public var sendSignal: @Sendable (OPNRemoteCoOpWirePeerSignal) async -> Void
    public var receiveInput: @Sendable (OPNRemoteCoOpInputPacket) async -> Void

    public init(sendSignal: @escaping @Sendable (OPNRemoteCoOpWirePeerSignal) async -> Void,
                receiveInput: @escaping @Sendable (OPNRemoteCoOpInputPacket) async -> Void) {
        self.sendSignal = sendSignal
        self.receiveInput = receiveInput
    }
}

public protocol OPNRemoteCoOpHostPeer: Sendable {
    var participantID: UUID { get }
    func start() async throws
    func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws
    func close() async
}

public protocol OPNRemoteCoOpHostPeerFactory: Sendable {
    func makePeer(participantID: UUID,
                  networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                  qualityPreset: OPNRemoteCoOpQualityPreset,
                  callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer
}

public enum OPNRemoteCoOpHostPeerInputDecoder {
    public static func decode(_ text: String, expectedParticipantID: UUID? = nil) -> OPNRemoteCoOpInputPacket? {
        decode(Data(text.utf8), expectedParticipantID: expectedParticipantID)
    }

    public static func decode(_ data: Data, expectedParticipantID: UUID? = nil) -> OPNRemoteCoOpInputPacket? {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(data),
              message.kind == .guestInput,
              let packet = message.input else { return nil }
        if let expectedParticipantID, packet.participantID != expectedParticipantID { return nil }
        if let participantID = message.participantID, participantID != packet.participantID { return nil }
        return packet
    }
}

public actor OPNRemoteCoOpHostPeerController {
    private let signaling: any OPNRemoteCoOpSignalingSession
    private let coordinator: OPNRemoteCoOpHostCoordinator
    private let peerFactory: any OPNRemoteCoOpHostPeerFactory
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private let videoRelay: OPNRemoteCoOpHostVideoRelay?
    private let audioRelay: OPNRemoteCoOpHostAudioRelay?
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private var qualityPreset: OPNRemoteCoOpQualityPreset
    private var peers: [UUID: any OPNRemoteCoOpHostPeer] = [:]

    public init(signaling: any OPNRemoteCoOpSignalingSession,
                coordinator: OPNRemoteCoOpHostCoordinator,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                qualityPreset: OPNRemoteCoOpQualityPreset = .p720f60,
                videoRelay: OPNRemoteCoOpHostVideoRelay? = nil,
                audioRelay: OPNRemoteCoOpHostAudioRelay? = nil,
                peerFactory: any OPNRemoteCoOpHostPeerFactory = OPNRemoteCoOpWebRTCHostPeerFactory(),
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.signaling = signaling
        self.coordinator = coordinator
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.videoRelay = videoRelay
        self.audioRelay = audioRelay
        self.peerFactory = peerFactory
        self.forwardInput = forwardInput
    }

    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        networkConfiguration = configuration
    }

    public func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) {
        qualityPreset = preset
    }

    public func sync(participants: [OPNRemoteCoOpParticipant]) async throws {
        let eligibleParticipants = participants.filter { $0.connectionState == .connected && $0.inputEnabled }
        let eligibleIDs = Set(eligibleParticipants.map(\.id))
        for (participantID, peer) in peers where !eligibleIDs.contains(participantID) {
            peers[participantID] = nil
            videoRelay?.remove(participantID: participantID)
            audioRelay?.remove(participantID: participantID)
            await peer.close()
        }
        for participant in eligibleParticipants where peers[participant.id] == nil {
            try await startPeer(for: participant)
        }
    }

    public func startPeer(for participant: OPNRemoteCoOpParticipant) async throws {
        guard participant.connectionState == .connected, participant.inputEnabled else { return }
        guard peers[participant.id] == nil else { return }
        let participantID = participant.id
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.start", level: .info, message: "Starting Remote Co-Op host peer.", attributes: ["participantID": participantID.uuidString])
        let callbacks = OPNRemoteCoOpHostPeerCallbacks(
            sendSignal: { [signaling] signal in
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.signal.send", level: .info, message: "Sending Remote Co-Op peer signal.", attributes: ["participantID": participantID.uuidString, "kind": signal.kind.rawValue])
                await signaling.send(.peerSignal(participantID: participantID, signal: signal))
            },
            receiveInput: { [coordinator, forwardInput] packet in
                guard packet.participantID == participantID else { return }
                let routedEvents = await coordinator.handle(.guestInput(packet))
                for routedEvent in routedEvents { await forwardInput(routedEvent) }
            }
        )
        let peer = peerFactory.makePeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: qualityPreset, callbacks: callbacks)
        peers[participantID] = peer
        do {
            try await peer.start()
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.started", level: .info, message: "Remote Co-Op host peer started.", attributes: ["participantID": participantID.uuidString])
            if let sink = peer as? any OPNRemoteCoOpHostVideoSink { videoRelay?.upsert(sink) }
            if let sink = peer as? any OPNRemoteCoOpHostAudioSink { audioRelay?.upsert(sink) }
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.start.failed", level: .warning, message: error.localizedDescription, attributes: ["participantID": participantID.uuidString])
            peers[participantID] = nil
            videoRelay?.remove(participantID: participantID)
            audioRelay?.remove(participantID: participantID)
            await peer.close()
            throw error
        }
    }

    public func receiveSignal(participantID: UUID, signal: OPNRemoteCoOpWirePeerSignal) async throws {
        guard let peer = peers[participantID] else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        try await peer.apply(signal)
    }

    public func removePeer(participantID: UUID) async {
        guard let peer = peers.removeValue(forKey: participantID) else { return }
        videoRelay?.remove(participantID: participantID)
        audioRelay?.remove(participantID: participantID)
        await peer.close()
    }

    public func removeAll() async {
        let currentPeers = Array(peers.values)
        peers.removeAll()
        videoRelay?.removeAll()
        audioRelay?.removeAll()
        for peer in currentPeers { await peer.close() }
    }
}

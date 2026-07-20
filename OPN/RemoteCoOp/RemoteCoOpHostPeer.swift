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
                  latencyMode: OPNRemoteCoOpLatencyMode,
                  callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer
}

public enum OPNRemoteCoOpHostPeerInputDecoder {
    public static func decode(_ text: String, expectedParticipantID: UUID? = nil) -> OPNRemoteCoOpInputPacket? {
        decodePackets(Data(text.utf8), expectedParticipantID: expectedParticipantID).last
    }

    public static func decode(_ data: Data, expectedParticipantID: UUID? = nil) -> OPNRemoteCoOpInputPacket? {
        decodePackets(data, expectedParticipantID: expectedParticipantID).last
    }

    public static func decodePackets(_ text: String, expectedParticipantID: UUID? = nil) -> [OPNRemoteCoOpInputPacket] {
        decodePackets(Data(text.utf8), expectedParticipantID: expectedParticipantID)
    }

    public static func decodePackets(_ data: Data, expectedParticipantID: UUID? = nil) -> [OPNRemoteCoOpInputPacket] {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(data), message.kind == .guestInput else { return [] }
        let packets = Self.packets(from: message)
        return packets.filter { packet in
            if let expectedParticipantID, packet.participantID != expectedParticipantID { return false }
            if let participantID = message.participantID, participantID != packet.participantID { return false }
            return true
        }.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    private static func packets(from message: OPNRemoteCoOpWireMessage) -> [OPNRemoteCoOpInputPacket] {
        var packets = message.inputs ?? []
        if let input = message.input, !packets.contains(where: { $0.sequenceNumber == input.sequenceNumber && $0.participantID == input.participantID }) {
            packets.append(input)
        }
        return packets
    }
}

public actor OPNRemoteCoOpHostPeerController {
    private let signaling: any OPNRemoteCoOpSignalingSession
    private let coordinator: OPNRemoteCoOpHostCoordinator
    private let peerFactory: any OPNRemoteCoOpHostPeerFactory
    private let inputScheduler: OPNRemoteCoOpHostInputScheduler
    private let videoRelay: OPNRemoteCoOpHostVideoRelay?
    private let audioRelay: OPNRemoteCoOpHostAudioRelay?
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private var qualityPreset: OPNRemoteCoOpQualityPreset
    private var latencyMode: OPNRemoteCoOpLatencyMode
    private var peers: [UUID: any OPNRemoteCoOpHostPeer] = [:]

    public init(signaling: any OPNRemoteCoOpSignalingSession,
                coordinator: OPNRemoteCoOpHostCoordinator,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                qualityPreset: OPNRemoteCoOpQualityPreset = .p720f60,
                latencyMode: OPNRemoteCoOpLatencyMode = .quality,
                videoRelay: OPNRemoteCoOpHostVideoRelay? = nil,
                audioRelay: OPNRemoteCoOpHostAudioRelay? = nil,
                peerFactory: any OPNRemoteCoOpHostPeerFactory = OPNRemoteCoOpWebRTCHostPeerFactory(),
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.signaling = signaling
        self.coordinator = coordinator
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.videoRelay = videoRelay
        self.audioRelay = audioRelay
        self.peerFactory = peerFactory
        self.inputScheduler = OPNRemoteCoOpHostInputScheduler(coordinator: coordinator, latencyMode: latencyMode, forwardInput: forwardInput)
    }

    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        networkConfiguration = configuration
    }

    public func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) {
        qualityPreset = preset
    }

    public func updateLatencyMode(_ mode: OPNRemoteCoOpLatencyMode) async {
        latencyMode = mode
        await inputScheduler.updateLatencyMode(mode)
    }

    public func sync(participants: [OPNRemoteCoOpParticipant]) async throws {
        let eligibleParticipants = participants.filter { $0.connectionState == .connected && $0.inputEnabled }
        let eligibleIDs = Set(eligibleParticipants.map(\.id))
        for (participantID, peer) in peers where !eligibleIDs.contains(participantID) {
            peers[participantID] = nil
            await inputScheduler.remove(participantID: participantID)
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
            receiveInput: { [inputScheduler] packet in
                await inputScheduler.receive(packet, expectedParticipantID: participantID)
            }
        )
        let peer = peerFactory.makePeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: qualityPreset, latencyMode: latencyMode, callbacks: callbacks)
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
        await inputScheduler.remove(participantID: participantID)
        videoRelay?.remove(participantID: participantID)
        audioRelay?.remove(participantID: participantID)
        await peer.close()
    }

    public func removeAll() async {
        let currentPeers = Array(peers.values)
        peers.removeAll()
        await inputScheduler.removeAll()
        videoRelay?.removeAll()
        audioRelay?.removeAll()
        for peer in currentPeers { await peer.close() }
    }
}

private actor OPNRemoteCoOpHostInputScheduler {
    private struct PendingInput: Sendable {
        var packet: OPNRemoteCoOpInputPacket
        var receivedAtNanoseconds: UInt64
    }

    private static let lowLatencyDrainDelayNanoseconds: UInt64 = 4_000_000
    private static let telemetryInterval: UInt64 = 240

    private let coordinator: OPNRemoteCoOpHostCoordinator
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private var latencyMode: OPNRemoteCoOpLatencyMode
    private var pendingInputs: [UUID: [PendingInput]] = [:]
    private var latestRoutedInputs: [UUID: OPNRemoteCoOpInputPacket] = [:]
    private var drainTask: Task<Void, Never>?
    private var routedInputCount: UInt64 = 0
    private var supersededInputCount: UInt64 = 0

    init(coordinator: OPNRemoteCoOpHostCoordinator,
         latencyMode: OPNRemoteCoOpLatencyMode,
         forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.coordinator = coordinator
        self.latencyMode = latencyMode
        self.forwardInput = forwardInput
    }

    func updateLatencyMode(_ mode: OPNRemoteCoOpLatencyMode) async {
        latencyMode = mode
        guard mode == .quality else { return }
        await drainPendingInputs(shouldCancelScheduledDrain: true)
    }

    func receive(_ packet: OPNRemoteCoOpInputPacket, expectedParticipantID: UUID) async {
        guard packet.participantID == expectedParticipantID else { return }
        let receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard latencyMode == .lowLatency else {
            await route(packet, receivedAtNanoseconds: receivedAtNanoseconds)
            return
        }

        let participantID = packet.participantID
        if let newest = newestKnownInput(participantID: participantID), newest.sequenceNumber >= packet.sequenceNumber {
            supersededInputCount &+= 1
            return
        }
        let previous = newestKnownInput(participantID: participantID)
        pendingInputs[participantID, default: []].append(PendingInput(packet: packet, receivedAtNanoseconds: receivedAtNanoseconds))
        if previous == nil || previous?.buttons != packet.buttons {
            await drainPendingInputs(shouldCancelScheduledDrain: true)
        } else {
            scheduleDrainIfNeeded()
        }
    }

    func remove(participantID: UUID) {
        pendingInputs[participantID] = nil
        latestRoutedInputs[participantID] = nil
        if pendingInputs.isEmpty { cancelScheduledDrain() }
    }

    func removeAll() {
        pendingInputs.removeAll()
        latestRoutedInputs.removeAll()
        cancelScheduledDrain()
    }

    private func scheduleDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.lowLatencyDrainDelayNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.drainPendingInputs(shouldCancelScheduledDrain: false)
            } catch {}
        }
    }

    private func drainPendingInputs(shouldCancelScheduledDrain: Bool) async {
        if shouldCancelScheduledDrain { cancelScheduledDrain() }
        drainTask = nil
        let inputs = pendingInputs
            .flatMap { participantID, inputs in condensedInputs(for: participantID, inputs: inputs) }
            .sorted { $0.receivedAtNanoseconds < $1.receivedAtNanoseconds }
        pendingInputs.removeAll()
        for input in inputs {
            await route(input.packet, receivedAtNanoseconds: input.receivedAtNanoseconds)
        }
        if !pendingInputs.isEmpty { scheduleDrainIfNeeded() }
    }

    private func route(_ packet: OPNRemoteCoOpInputPacket, receivedAtNanoseconds: UInt64) async {
        let routedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let routedEvents = await coordinator.handle(.guestInput(packet))
        for routedEvent in routedEvents { await forwardInput(routedEvent) }
        if !routedEvents.isEmpty { latestRoutedInputs[packet.participantID] = packet }
        routedInputCount &+= 1
        guard latencyMode == .lowLatency, routedInputCount.isMultiple(of: Self.telemetryInterval) else { return }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.input.coalesced", level: .debug, message: "Remote Co-Op low latency input coalescing active.", attributes: [
            "coalescingDelayMilliseconds": String(Self.millisecondsBetween(receivedAtNanoseconds, routedAtNanoseconds)),
            "participantID": packet.participantID.uuidString,
            "routedInputs": String(routedInputCount),
            "sequenceNumber": String(packet.sequenceNumber),
            "supersededInputs": String(supersededInputCount)
        ])
    }

    private func newestKnownInput(participantID: UUID) -> OPNRemoteCoOpInputPacket? {
        let pendingNewest = pendingInputs[participantID]?.max { $0.packet.sequenceNumber < $1.packet.sequenceNumber }?.packet
        guard let routed = latestRoutedInputs[participantID] else { return pendingNewest }
        guard let pendingNewest else { return routed }
        return pendingNewest.sequenceNumber > routed.sequenceNumber ? pendingNewest : routed
    }

    private func condensedInputs(for participantID: UUID, inputs: [PendingInput]) -> [PendingInput] {
        let sortedInputs = inputs.sorted { $0.packet.sequenceNumber < $1.packet.sequenceNumber }
        var reference = latestRoutedInputs[participantID]
        var latestAnalogInput: PendingInput?
        var condensed: [PendingInput] = []

        for input in sortedInputs {
            if let reference, reference.buttons == input.packet.buttons {
                latestAnalogInput = input
                continue
            }
            if let analogInput = latestAnalogInput {
                condensed.append(analogInput)
                latestAnalogInput = nil
            }
            condensed.append(input)
            reference = input.packet
        }
        if let analogInput = latestAnalogInput { condensed.append(analogInput) }
        return condensed
    }

    private func cancelScheduledDrain() {
        drainTask?.cancel()
        drainTask = nil
    }

    private static func millisecondsBetween(_ startNanoseconds: UInt64, _ endNanoseconds: UInt64) -> Int {
        guard endNanoseconds >= startNanoseconds else { return 0 }
        return Int((endNanoseconds - startNanoseconds) / 1_000_000)
    }
}

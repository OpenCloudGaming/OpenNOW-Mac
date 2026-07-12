import Foundation
@preconcurrency import WebRTC

public struct OPNRemoteCoOpWebRTCHostPeerFactory: OPNRemoteCoOpHostPeerFactory {
    public init() {}

    public func makePeer(participantID: UUID,
                         networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                         callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer {
        OPNRemoteCoOpWebRTCHostPeer(participantID: participantID, networkConfiguration: networkConfiguration, callbacks: callbacks)
    }
}

public final class OPNRemoteCoOpWebRTCHostPeer: NSObject, OPNRemoteCoOpHostPeer, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    public let participantID: UUID
    private static let inputChannelLabel = "remote-coop-input"
    private let networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private let callbacks: OPNRemoteCoOpHostPeerCallbacks
    private let stateLock = NSLock()
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var inputChannels: [RTCDataChannel] = []
    private var isClosed = false

    public init(participantID: UUID,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                callbacks: OPNRemoteCoOpHostPeerCallbacks) {
        self.participantID = participantID
        self.networkConfiguration = networkConfiguration
        self.callbacks = callbacks
        super.init()
    }

    public func start() async throws {
        let peerConnection = try makePeerConnection()
        createInputChannel(peerConnection: peerConnection)
        try await createAndSendOffer(peerConnection: peerConnection)
    }

    public func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {
        switch signal.kind {
        case .answer:
            guard let sdp = signal.sdp, !sdp.isEmpty else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        case .iceCandidate:
            guard let candidate = signal.candidate, !candidate.isEmpty else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            try await addIceCandidate(RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(signal.sdpMLineIndex ?? 0), sdpMid: signal.sdpMid))
        case .offer:
            throw OPNRemoteCoOpHostPeerError.invalidSignal
        }
    }

    public func close() async {
        let state = stateLock.withLock { () -> (RTCPeerConnection?, [RTCDataChannel]) in
            guard !isClosed else { return (nil, []) }
            isClosed = true
            let peerConnection = peerConnection
            let inputChannels = inputChannels
            self.peerConnection = nil
            self.inputChannels = []
            factory = nil
            return (peerConnection, inputChannels)
        }
        for inputChannel in state.1 {
            inputChannel.delegate = nil
            inputChannel.close()
        }
        state.0?.delegate = nil
        state.0?.close()
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !closed else { return }
        Task {
            await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .iceCandidate, candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex)))
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        bindInputChannel(dataChannel)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !closed,
              let packet = OPNRemoteCoOpHostPeerInputDecoder.decode(buffer.data as Data, expectedParticipantID: participantID) else { return }
        Task { await callbacks.receiveInput(packet) }
    }

    private var closed: Bool {
        stateLock.withLock { isClosed }
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let existing = stateLock.withLock { peerConnection }
        if let existing { return existing }

        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers()
        configuration.iceTransportPolicy = networkConfiguration.iceTransportPolicy == .relay ? .relay : .all
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .enabled
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.iceConnectionReceivingTimeout = 30_000
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw OPNRemoteCoOpHostPeerError.negotiationFailed("Unable to create Remote Co-Op WebRTC peer connection.")
        }
        stateLock.withLock {
            self.factory = factory
            self.peerConnection = peerConnection
        }
        return peerConnection
    }

    private func createInputChannel(peerConnection: RTCPeerConnection) {
        guard networkConfiguration.dataChannelInputEnabled else { return }
        let hasHostChannel = stateLock.withLock { inputChannels.contains { $0.label == Self.inputChannelLabel } }
        guard !hasHostChannel else { return }
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = false
        configuration.maxRetransmits = 0
        guard let channel = peerConnection.dataChannel(forLabel: Self.inputChannelLabel, configuration: configuration) else { return }
        bindInputChannel(channel)
    }

    private func bindInputChannel(_ channel: RTCDataChannel) {
        let shouldBind = stateLock.withLock { () -> Bool in
            guard !inputChannels.contains(where: { $0 === channel }) else { return false }
            inputChannels.append(channel)
            return true
        }
        if shouldBind { channel.delegate = self }
    }

    private func createAndSendOffer(peerConnection: RTCPeerConnection) async throws {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await createOffer(peerConnection: peerConnection, constraints: constraints)
        try await setLocalDescription(offer, peerConnection: peerConnection)
        await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .offer, sdp: offer.sdp))
    }

    private func createOffer(peerConnection: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { offer, error in
                if let offer {
                    continuation.resume(returning: offer)
                } else {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error?.localizedDescription ?? "Unable to create Remote Co-Op WebRTC offer."))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func iceServers() -> [RTCIceServer] {
        networkConfiguration.iceServers.compactMap { server in
            guard !server.urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: server.urls, username: emptyNil(server.username), credential: emptyNil(server.credential))
        }
    }

    private func emptyNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

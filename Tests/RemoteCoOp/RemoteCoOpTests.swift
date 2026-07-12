import Testing
import Foundation
import CoreVideo
@preconcurrency import WebRTC
@testable import OpenNOW

@Suite("Remote Co-Op")
struct RemoteCoOpTests {
    @Test("preferences clamp guest slots")
    func preferencesClampGuestSlots() {
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: -2).reservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 7).reservedGuestSlots == 3)
        #expect(OPNRemoteCoOpPreferences(isEnabled: false, reservedGuestSlots: 2).effectiveReservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2).effectiveReservedGuestSlots == 2)
        #expect(OPNRemoteCoOpPreferences().transportMode == .automatic)
        #expect(!OPNRemoteCoOpPreferences().hideGuestInviteDetails)
    }

    @Test("preferences round-trip through stream launch metadata")
    func preferencesRoundTripThroughStreamLaunchMetadata() {
        let preferences = OPNRemoteCoOpPreferences(
            isEnabled: true,
            reservedGuestSlots: 2,
            transportMode: .relayOnly,
            qualityPreset: .p1080f60,
            requireHostApproval: false,
            signalingServerURL: "wss://coop.example.test/remote-coop",
            guestJoinBaseURL: "https://coop.example.test/",
            hideGuestInviteDetails: true
        )

        #expect(OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences()) == preferences)
    }

    @Test("transport modes map to ICE policies for router traversal")
    func transportModesMapToICEPoliciesForRouterTraversal() {
        #expect(OPNRemoteCoOpTransportMode.automatic.iceTransportPolicy == .all)
        #expect(OPNRemoteCoOpTransportMode.automatic.allowsRelayFallback)
        #expect(OPNRemoteCoOpTransportMode.directOnly.iceTransportPolicy == .all)
        #expect(!OPNRemoteCoOpTransportMode.directOnly.allowsRelayFallback)
        #expect(OPNRemoteCoOpTransportMode.relayOnly.iceTransportPolicy == .relay)
        #expect(OPNRemoteCoOpTransportMode.relayOnly.hidesDirectPeerCandidates)
    }

    @Test("wire codec maps browser messages into signaling events")
    func wireCodecMapsBrowserMessagesIntoSignalingEvents() throws {
        let participantID = UUID()
        let packet = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 42, buttons: [.south, .dpadRight], leftTrigger: 0.75, rightStickX: -0.5)
        let join = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, roomID: UUID(), participantID: participantID, inviteToken: "token", displayName: "Mia")
        let input = OPNRemoteCoOpWireMessage(kind: .guestInput, roomID: UUID(), participantID: participantID, input: packet)

        let decodedJoin = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(join))
        let decodedInput = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(input))

        #expect(decodedJoin.signalingEvent() == .guestJoinRequested(participantID: participantID, inviteToken: "token", displayName: "Mia"))
        #expect(decodedInput.signalingEvent() == .guestInput(packet))
    }

    @Test("wire codec decodes browser numeric gamepad button masks")
    func wireCodecDecodesBrowserNumericGamepadButtonMasks() throws {
        let participantID = UUID()
        let json = """
        {
          "kind": "guestInput",
          "participantID": "\(participantID.uuidString)",
          "input": {
            "participantID": "\(participantID.uuidString)",
            "sequenceNumber": 7,
            "buttons": \(GamepadButtons([.south, .dpadRight]).rawValue),
            "leftTrigger": 1,
            "rightTrigger": 0,
            "leftStickX": 0,
            "leftStickY": 0,
            "rightStickX": 0,
            "rightStickY": 0,
            "sentAtNanoseconds": 100
          }
        }
        """

        let message = try OPNRemoteCoOpWireCodec.decode(json)

        guard case .guestInput(let packet)? = message.signalingEvent() else {
            Issue.record("Expected guest input event")
            return
        }
        #expect(packet.buttons == [.south, .dpadRight])
    }

    @Test("wire codec maps host commands into broker messages")
    func wireCodecMapsHostCommandsIntoBrokerMessages() throws {
        let roomID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: UUID(), displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)

        let participantMessage = try #require(OPNRemoteCoOpWireMessage.message(for: .participantUpdated(participant), roomID: roomID))
        let rejectionMessage = try #require(OPNRemoteCoOpWireMessage.message(for: .inputRejected(participantID: participant.id, result: .stalePacket), roomID: roomID))

        #expect(participantMessage.kind == .participantUpdated)
        #expect(participantMessage.roomID == roomID)
        #expect(participantMessage.participant == participant)
        #expect(rejectionMessage.kind == .inputRejected)
        #expect(rejectionMessage.inputRejection == .stalePacket)
    }

    @Test("wire codec carries ICE network configuration")
    func wireCodecCarriesICENetworkConfiguration() throws {
        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .relayOnly,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: UUID(), networkConfiguration: configuration)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.networkConfiguration == configuration)
        #expect(decoded.networkConfiguration?.iceTransportPolicy == .relay)
    }

    @Test("wire codec maps broker network config into signaling event")
    func wireCodecMapsBrokerNetworkConfigIntoSignalingEvent() throws {
        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .relayOnly,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: UUID(), networkConfiguration: configuration)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.signalingEvent() == .networkConfiguration(configuration))
    }

    @Test("invite token signs and verifies launch metadata")
    func inviteTokenSignsAndVerifiesLaunchMetadata() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 7, count: 32))
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2, transportMode: .relayOnly, qualityPreset: .p1080f60, requireHostApproval: false)
        let host = OPNRemoteCoOpHostSession(preferences: preferences, inviteSigner: signer)

        let invite = try await host.startInvite(applicationID: "123", title: "Portal", lifetimeSeconds: 120)
        let payload = try signer.verify(invite.token)

        #expect(payload.inviteID == invite.id)
        #expect(payload.code == invite.code)
        #expect(payload.applicationID == "123")
        #expect(payload.title == "Portal")
        #expect(payload.reservedGuestSlots == 2)
        #expect(payload.transportMode == .relayOnly)
        #expect(payload.qualityPreset == .p1080f60)
        #expect(!payload.requireHostApproval)
        #expect(!payload.hideGuestInviteDetails)
    }

    @Test("private invites hide guest visible title and app id")
    func privateInvitesHideGuestVisibleTitleAndAppID() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 9, count: 32))
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, hideGuestInviteDetails: true)
        let host = OPNRemoteCoOpHostSession(preferences: preferences, inviteSigner: signer)

        let invite = try await host.startInvite(applicationID: "secret-app", title: "Secret Game", joinBaseURL: URL(string: "https://join.example.test/")!, signalingServerURL: "wss://signal.example.test/remote-coop", lifetimeSeconds: 120)
        let payload = try signer.verify(invite.token)
        let joinURL = try #require(invite.joinURL)
        let components = try #require(URLComponents(url: joinURL, resolvingAgainstBaseURL: false))

        #expect(payload.applicationID.isEmpty)
        #expect(payload.title.isEmpty)
        #expect(payload.hideGuestInviteDetails)
        #expect(invite.applicationID == "secret-app")
        #expect(invite.title == "Secret Game")
        #expect(invite.hideGuestInviteDetails)
        #expect(components.queryItems?.contains(URLQueryItem(name: "server", value: "wss://signal.example.test/remote-coop")) == true)
    }

    @Test("stream settings advertise reserved controller bitmap")
    func streamSettingsAdvertiseReservedControllerBitmap() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(),
            capabilities: WebRTCMediaDeviceCapabilities(connectedGamepadCount: 4)
        )

        #expect(settings.remoteControllersBitmap == 0x0f)
    }

    @Test("host creates invite and approves guest into player two slot")
    func hostCreatesInviteAndApprovesGuestIntoPlayerTwoSlot() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)

        let invite = try await host.startInvite(lifetimeSeconds: 120)
        let pending = try await host.registerGuest(displayName: "Mia", inviteToken: invite.token)
        let approved = try await host.approveParticipant(pending.id)
        let snapshot = await host.snapshot()

        #expect(invite.code.count == 8)
        #expect(pending.connectionState == .waitingForApproval)
        #expect(approved.connectionState == .connected)
        #expect(approved.inputEnabled)
        #expect(approved.playerIndex == 1)
        #expect(snapshot.participants == [approved])
    }

    @Test("host rejects guest with invalid invite token")
    func hostRejectsGuestWithInvalidInviteToken() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)

        _ = try await host.startInvite(lifetimeSeconds: 120)

        await #expect(throws: OPNRemoteCoOpHostSessionError.invalidInviteToken) {
            try await host.registerGuest(displayName: "Mia", inviteToken: "bad-token")
        }
    }

    @Test("host treats duplicate guest join as idempotent retry")
    func hostTreatsDuplicateGuestJoinAsIdempotentRetry() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)
        let participantID = UUID()

        let invite = try await host.startInvite(lifetimeSeconds: 120)
        let first = try await host.registerGuest(displayName: "Mia", inviteToken: invite.token, participantID: participantID)
        let retry = try await host.registerGuest(displayName: "Mia", inviteToken: invite.token, participantID: participantID)
        let snapshot = await host.snapshot()

        #expect(first == retry)
        #expect(snapshot.participants == [first])
    }

    @Test("host rejects invite when no guest controller slot was reserved")
    func hostRejectsInviteWhenNoGuestControllerSlotWasReserved() async {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 0)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)

        await #expect(throws: OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots) {
            try await host.startInvite(lifetimeSeconds: 120)
        }
    }

    @Test("input router emits validated remote gamepad event and rejects stale packets")
    func inputRouterEmitsValidatedGamepadEventAndRejectsStalePackets() async throws {
        let participantID = UUID()
        let participant = OPNRemoteCoOpParticipant(
            id: participantID,
            displayName: "Guest",
            role: .guest,
            connectionState: .connected,
            inputEnabled: true,
            playerIndex: 1
        )
        let router = OPNRemoteCoOpInputRouter(participants: [participant])
        let packet = OPNRemoteCoOpInputPacket(
            participantID: participantID,
            sequenceNumber: 3,
            buttons: [.south, .rightShoulder],
            leftTrigger: 2,
            rightTrigger: -1,
            leftStickX: -3,
            leftStickY: 0.5,
            rightStickX: 0.25,
            rightStickY: 4
        )

        let result = await router.route(packet, receivedAtNanoseconds: 123)
        let stale = await router.route(packet, receivedAtNanoseconds: 124)

        guard case .routed(.gamepad(let state)) = result else {
            Issue.record("Expected routed gamepad event, got \(result)")
            return
        }
        #expect(state.playerIndex == 1)
        #expect(state.buttons == GamepadButtons([.south, .rightShoulder]))
        #expect(state.leftTrigger == 1)
        #expect(state.rightTrigger == 0)
        #expect(state.leftStickX == -1)
        #expect(state.leftStickY == 0.5)
        #expect(state.rightStickX == 0.25)
        #expect(state.rightStickY == 1)
        #expect(state.timestamp.nanoseconds == 123)
        #expect(stale == .stalePacket)
    }

    @Test("host invite teardown emits neutral gamepad state")
    func hostInviteTeardownEmitsNeutralGamepadState() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: false)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)

        let invite = try await host.startInvite(lifetimeSeconds: 120)
        let guest = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token)
        let events = await host.stopInvite()
        let snapshot = await host.snapshot()

        #expect(guest.playerIndex == 1)
        #expect(events.count == 1)
        guard case .gamepad(let state) = events.first else {
            Issue.record("Expected neutral gamepad state")
            return
        }
        #expect(state.playerIndex == 1)
        #expect(state.buttons.isEmpty)
        #expect(snapshot.invite == nil)
        #expect(snapshot.participants.isEmpty)
    }

    @Test("coordinator joins approves routes input and rejects stale packet")
    func coordinatorJoinsApprovesRoutesInputAndRejectsStalePacket() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: preferences), signaling: signaling)

        let participantID = UUID()
        let invite = try await coordinator.startInvite(applicationID: "123", title: "Portal", lifetimeSeconds: 120)
        let joinEvents = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Mia"))
        let pendingCommand = signaling.commandHistory().last
        let approved = try await coordinator.approveParticipant(participantID)
        let approvedCommand = signaling.commandHistory().last
        let packet = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 1, buttons: [.south], leftTrigger: 1)
        let routedEvents = await coordinator.handle(.guestInput(packet))
        let staleEvents = await coordinator.handle(.guestInput(packet))
        let commands = signaling.commandHistory()
        let staleCommand = commands.last

        #expect(commands.first == .inviteCreated(invite))
        #expect(joinEvents.isEmpty)
        guard case .participantUpdated(let pending)? = pendingCommand else {
            Issue.record("Expected pending participant command")
            return
        }
        #expect(pending.id == participantID)
        #expect(pending.connectionState == .waitingForApproval)
        #expect(approved.id == participantID)
        #expect(approved.playerIndex == 1)
        #expect(approvedCommand == .participantUpdated(approved))
        #expect(routedEvents.count == 1)
        guard case .gamepad(let state) = routedEvents.first else {
            Issue.record("Expected routed gamepad event")
            return
        }
        #expect(state.playerIndex == 1)
        #expect(state.buttons == GamepadButtons.south)
        #expect(state.leftTrigger == 1)
        #expect(staleEvents.isEmpty)
        #expect(staleCommand == .inputRejected(participantID: participantID, result: .stalePacket))
    }

    @Test("coordinator disconnect removes guest and emits neutral input")
    func coordinatorDisconnectRemovesGuestAndEmitsNeutralInput() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: false)
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: preferences), signaling: signaling)

        let participantID = UUID()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Mia"))
        let neutralEvents = await coordinator.handle(.guestDisconnected(participantID))
        let removedCommand = signaling.commandHistory().last
        let snapshot = await coordinator.snapshot()

        #expect(neutralEvents.count == 1)
        guard case .gamepad(let state) = neutralEvents.first else {
            Issue.record("Expected neutral gamepad event")
            return
        }
        #expect(state.playerIndex == 1)
        #expect(state.buttons.isEmpty)
        #expect(removedCommand == .participantRemoved(participantID))
        #expect(snapshot.participants.isEmpty)
    }

    @Test("host peer controller emits offer after approval")
    func hostPeerControllerEmitsOfferAfterApproval() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)), signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let participantID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let networkConfiguration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .relayOnly,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: networkConfiguration, peerFactory: factory, forwardInput: { _ in })

        try await controller.startPeer(for: participant)

        let peer = try #require(factory.peer(for: participantID))
        guard case .peerSignal(let commandParticipantID, let signal)? = signaling.commandHistory().last else {
            Issue.record("Expected peer signal command")
            return
        }
        #expect(commandParticipantID == participantID)
        #expect(signal.kind == .offer)
        #expect(signal.sdp == "offer-\(participantID.uuidString)")
        #expect(peer.networkConfiguration == networkConfiguration)
        #expect(peer.startCount() == 1)
    }

    @Test("host peer controller applies browser answer and ICE")
    func hostPeerControllerAppliesBrowserAnswerAndICE() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)), signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let participantID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic), peerFactory: factory, forwardInput: { _ in })

        try await controller.startPeer(for: participant)
        try await controller.receiveSignal(participantID: participantID, signal: OPNRemoteCoOpWirePeerSignal(kind: .answer, sdp: "answer-sdp"))
        try await controller.receiveSignal(participantID: participantID, signal: OPNRemoteCoOpWirePeerSignal(kind: .iceCandidate, candidate: "candidate:1 1 udp 1 127.0.0.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0))

        let peer = try #require(factory.peer(for: participantID))
        #expect(peer.appliedSignals() == [
            OPNRemoteCoOpWirePeerSignal(kind: .answer, sdp: "answer-sdp"),
            OPNRemoteCoOpWirePeerSignal(kind: .iceCandidate, candidate: "candidate:1 1 udp 1 127.0.0.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0),
        ])
    }

    @Test("host peer data channel input routes through coordinator")
    func hostPeerDataChannelInputRoutesThroughCoordinator() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let hostSession = OPNRemoteCoOpHostSession(preferences: preferences)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let inputRecorder = RemoteCoOpInputRecorder()
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic), peerFactory: factory) { event in
            await inputRecorder.append(event)
        }
        let participantID = UUID()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Mia"))
        let approved = try await coordinator.approveParticipant(participantID)
        await controller.sync(participants: [approved])
        let peer = try #require(factory.peer(for: participantID))
        let packet = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 1, buttons: [.south, .rightShoulder], leftTrigger: 1, rightStickX: -0.5)
        let message = OPNRemoteCoOpWireMessage(kind: .guestInput, roomID: invite.id, participantID: participantID, input: packet)
        let text = try OPNRemoteCoOpWireCodec.encode(message)

        await peer.receiveDataChannelText(text)
        await peer.receiveDataChannelText(text)

        let events = await inputRecorder.events()
        #expect(events.count == 1)
        guard case .gamepad(let state) = events.first else {
            Issue.record("Expected routed gamepad event")
            return
        }
        #expect(state.playerIndex == 1)
        #expect(state.buttons == [.south, .rightShoulder])
        #expect(state.leftTrigger == 1)
        #expect(state.rightStickX == -0.5)
        #expect(signaling.commandHistory().last == .inputRejected(participantID: participantID, result: .stalePacket))
    }

    @Test("host peer controller registers approved peers as video sinks")
    func hostPeerControllerRegistersApprovedPeersAsVideoSinks() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)), signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let relay = OPNRemoteCoOpHostVideoRelay()
        let participantID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic), videoRelay: relay, peerFactory: factory, forwardInput: { _ in })

        try await controller.startPeer(for: participant)
        let peer = try #require(factory.peer(for: participantID))
        relay.renderVideoFrame(try Self.makeVideoFrame())
        await controller.removePeer(participantID: participantID)
        relay.renderVideoFrame(try Self.makeVideoFrame())

        #expect(relay.activeSinkCount() == 0)
        #expect(peer.renderedVideoFrameCount() == 1)
    }

    @Test("host peer input decoder rejects mismatched participants")
    func hostPeerInputDecoderRejectsMismatchedParticipants() throws {
        let expectedParticipantID = UUID()
        let spoofedParticipantID = UUID()
        let packet = OPNRemoteCoOpInputPacket(participantID: spoofedParticipantID, sequenceNumber: 1, buttons: [.south])
        let message = OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: expectedParticipantID, input: packet)
        let text = try OPNRemoteCoOpWireCodec.encode(message)

        #expect(OPNRemoteCoOpHostPeerInputDecoder.decode(text, expectedParticipantID: expectedParticipantID) == nil)
    }

    private static func makeVideoFrame() throws -> RTCVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        #expect(status == kCVReturnSuccess)
        let buffer = RTCCVPixelBuffer(pixelBuffer: try #require(pixelBuffer))
        return RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1)
    }
}

private actor RemoteCoOpInputRecorder {
    private var recordedEvents: [UserInputEvent] = []

    func append(_ event: UserInputEvent) {
        recordedEvents.append(event)
    }

    func events() -> [UserInputEvent] {
        recordedEvents
    }
}

private final class RecordingRemoteCoOpHostPeerFactory: OPNRemoteCoOpHostPeerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: RecordingRemoteCoOpHostPeer] = [:]

    func makePeer(participantID: UUID,
                  networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                  qualityPreset: OPNRemoteCoOpQualityPreset,
                  callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer {
        let peer = RecordingRemoteCoOpHostPeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: qualityPreset, callbacks: callbacks)
        lock.withLock { peers[participantID] = peer }
        return peer
    }

    func peer(for participantID: UUID) -> RecordingRemoteCoOpHostPeer? {
        lock.withLock { peers[participantID] }
    }
}

private final class RecordingRemoteCoOpHostPeer: OPNRemoteCoOpHostPeer, OPNRemoteCoOpHostVideoSink, @unchecked Sendable {
    let participantID: UUID
    let networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    let qualityPreset: OPNRemoteCoOpQualityPreset
    private let callbacks: OPNRemoteCoOpHostPeerCallbacks
    private let lock = NSLock()
    private var started = 0
    private var closed = 0
    private var renderedFrames = 0
    private var signals: [OPNRemoteCoOpWirePeerSignal] = []

    init(participantID: UUID, networkConfiguration: OPNRemoteCoOpNetworkConfiguration, qualityPreset: OPNRemoteCoOpQualityPreset, callbacks: OPNRemoteCoOpHostPeerCallbacks) {
        self.participantID = participantID
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.callbacks = callbacks
    }

    func start() async throws {
        lock.withLock { started += 1 }
        await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .offer, sdp: "offer-\(participantID.uuidString)"))
    }

    func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {
        lock.withLock { signals.append(signal) }
    }

    func close() async {
        lock.withLock { closed += 1 }
    }

    func receiveDataChannelText(_ text: String) async {
        guard let packet = OPNRemoteCoOpHostPeerInputDecoder.decode(text, expectedParticipantID: participantID) else { return }
        await callbacks.receiveInput(packet)
    }

    func renderVideoFrame(_ frame: RTCVideoFrame) {
        lock.withLock { renderedFrames += 1 }
    }

    func startCount() -> Int {
        lock.withLock { started }
    }

    func closeCount() -> Int {
        lock.withLock { closed }
    }

    func appliedSignals() -> [OPNRemoteCoOpWirePeerSignal] {
        lock.withLock { signals }
    }

    func renderedVideoFrameCount() -> Int {
        lock.withLock { renderedFrames }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

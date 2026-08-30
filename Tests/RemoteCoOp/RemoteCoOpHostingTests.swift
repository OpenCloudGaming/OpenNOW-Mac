//
//  RemoteCoOpHostingTests.swift
//  OpenNOW
//
//  Hosting a Remote Co-Op session: invites, guest approval, the input router and the peer
//  controller behind them. Split out of RemoteCoOpTests.swift.
//

import Testing
import AudioUnit
import Foundation
import CoreVideo
@preconcurrency import WebRTC
@testable import OpenNOW

@Suite("Remote Co-Op hosting", .serialized)
struct RemoteCoOpHostingTests {
    @Test("host creates invite and approves guest into player two slot")
    func hostCreatesInviteAndApprovesGuestIntoPlayerTwoSlot() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)

        let invite = try await host.startInvite(lifetimeSeconds: 120)
        let pending = try await host.registerGuest(displayName: "Mia", inviteToken: invite.code)
        let approved = try await host.approveParticipant(pending.id)
        let snapshot = await host.snapshot()

        #expect(invite.code.count == 6)
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
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: networkConfiguration, latencyMode: .lowLatency, peerFactory: factory, forwardInput: { _ in })

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
        #expect(peer.latencyMode == .lowLatency)
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
        try await controller.sync(participants: [approved])
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

    @Test("low latency host peer input coalesces bursts to newest packet")
    func lowLatencyHostPeerInputCoalescesBurstsToNewestPacket() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let hostSession = OPNRemoteCoOpHostSession(preferences: preferences)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let inputRecorder = RemoteCoOpInputRecorder()
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic), latencyMode: .lowLatency, peerFactory: factory) { event in
            await inputRecorder.append(event)
        }
        let participantID = UUID()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Mia"))
        let approved = try await coordinator.approveParticipant(participantID)
        try await controller.sync(participants: [approved])
        let peer = try #require(factory.peer(for: participantID))
        let first = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 1, buttons: [.south], leftStickX: -1)
        let second = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 2, buttons: [.south], leftStickX: 0)
        let newest = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 3, buttons: [.south], leftStickX: 1)

        for packet in [first, second, newest] {
            let message = OPNRemoteCoOpWireMessage(kind: .guestInput, roomID: invite.id, participantID: participantID, input: packet)
            await peer.receiveDataChannelText(try OPNRemoteCoOpWireCodec.encode(message))
        }
        let events = await inputRecorder.waitForEvents(count: 2)
        #expect(events.count == 2)
        guard case .gamepad(let state) = events.last else {
            Issue.record("Expected routed gamepad event")
            return
        }
        #expect(state.buttons == [.south])
        #expect(state.leftStickX == 1)
        #expect(!signaling.commandHistory().contains(.inputRejected(participantID: participantID, result: .stalePacket)))
    }

    @Test("low latency host peer preserves button edges from input history")
    func lowLatencyHostPeerPreservesButtonEdgesFromInputHistory() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let hostSession = OPNRemoteCoOpHostSession(preferences: preferences)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let inputRecorder = RemoteCoOpInputRecorder()
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic), latencyMode: .lowLatency, peerFactory: factory) { event in
            await inputRecorder.append(event)
        }
        let participantID = UUID()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Mia"))
        let approved = try await coordinator.approveParticipant(participantID)
        try await controller.sync(participants: [approved])
        let peer = try #require(factory.peer(for: participantID))
        let press = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 1, buttons: [.south])
        let release = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 2, buttons: [])
        let nextPress = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 3, buttons: [.east])
        let message = OPNRemoteCoOpWireMessage(kind: .guestInput, roomID: invite.id, participantID: participantID, input: nextPress, inputs: [press, release, nextPress])

        await peer.receiveDataChannelText(try OPNRemoteCoOpWireCodec.encode(message))
        let events = await inputRecorder.waitForEvents(count: 3)
        #expect(events.count == 3)
        let buttons = events.compactMap { event -> GamepadButtons? in
            guard case .gamepad(let state) = event else { return nil }
            return state.buttons
        }
        #expect(buttons == [[.south], [], [.east]])
        #expect(!signaling.commandHistory().contains(.inputRejected(participantID: participantID, result: .stalePacket)))
    }

    @Test("host peer controller registers approved peers as media sinks")
    func hostPeerControllerRegistersApprovedPeersAsMediaSinks() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)), signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let videoRelay = OPNRemoteCoOpHostVideoRelay()
        let audioRelay = OPNRemoteCoOpHostAudioRelay()
        let participantID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let controller = OPNRemoteCoOpHostPeerController(signaling: signaling, coordinator: coordinator, networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic), videoRelay: videoRelay, audioRelay: audioRelay, peerFactory: factory, forwardInput: { _ in })

        try await controller.startPeer(for: participant)
        let peer = try #require(factory.peer(for: participantID))
        videoRelay.renderVideoFrame(try RemoteCoOpFixtures.makeVideoFrame())
        audioRelay.renderAudioFrame(RemoteCoOpFixtures.makeAudioFrame())
        await controller.removePeer(participantID: participantID)
        videoRelay.renderVideoFrame(try RemoteCoOpFixtures.makeVideoFrame())
        audioRelay.renderAudioFrame(RemoteCoOpFixtures.makeAudioFrame())

        #expect(videoRelay.activeSinkCount() == 0)
        #expect(audioRelay.activeSinkCount() == 0)
        #expect(peer.renderedVideoFrameCount() == 1)
        #expect(peer.renderedAudioFrameCount() == 1)
    }

    @Test("audio relay copies game audio frames before fanout")
    func audioRelayCopiesGameAudioFramesBeforeFanout() throws {
        let relay = OPNRemoteCoOpHostAudioRelay()
        let sink = RecordingRemoteCoOpAudioSink(participantID: UUID())
        var samples: [Int16] = [10, -10, 20, -20]
        relay.upsert(sink)

        samples.withUnsafeMutableBytes { sampleBytes in
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(sampleBytes.count), mData: sampleBytes.baseAddress)
            )
            withUnsafePointer(to: &audioBufferList) { pointer in
                relay.renderAudioFrame(audioBufferList: UnsafeRawPointer(pointer), frameCount: 2, sampleRate: 48_000, channels: 2)
            }
        }
        samples = [0, 0, 0, 0]

        let frames = sink.renderedAudioFrames()
        #expect(frames.count == 1)
        #expect(frames.first?.frameCount == 2)
        #expect(frames.first?.sampleRate == 48_000)
        #expect(frames.first?.channels == 2)
        #expect(frames.first?.samples == RemoteCoOpFixtures.audioData([10, -10, 20, -20]))
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
}

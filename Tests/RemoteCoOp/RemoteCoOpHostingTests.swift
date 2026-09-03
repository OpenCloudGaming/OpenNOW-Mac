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
        let pending = try await host.registerGuest(displayName: "Mia", inviteToken: invite.token)
        let approved = try await host.approveParticipant(pending.id)
        let snapshot = await host.snapshot()

        #expect(invite.code.count == 6)
        #expect(pending.connectionState == .waitingForApproval)
        #expect(approved.connectionState == .connected)
        #expect(approved.inputEnabled)
        #expect(approved.playerIndex == 1)
        #expect(snapshot.participants == [approved])
    }

    /// The six-character code is a human-readable label, not a credential. `validate` used to accept
    /// it in place of a signed token, which meant anything that saw the code on screen could join.
    @Test("host rejects a bare invite code in place of a signed token")
    func hostRejectsABareInviteCode() async throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)
        let host = OPNRemoteCoOpHostSession(preferences: preferences)
        let invite = try await host.startInvite(lifetimeSeconds: 120)

        await #expect(throws: OPNRemoteCoOpHostSessionError.invalidInviteToken) {
            _ = try await host.registerGuest(displayName: "Mia", inviteToken: invite.code)
        }
        // The signed token from the same invite still works.
        _ = try await host.registerGuest(displayName: "Mia", inviteToken: invite.token)
        #expect(await host.snapshot().participants.count == 1)
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

    /// A dropped socket holds the guest's slot instead of releasing it, so a Wi-Fi roam does not cost
    /// them their approval and their player slot. Neutral pad state still goes out immediately, or
    /// whatever they were holding stays pressed in the game for the whole grace period. The slot is
    /// released by `expireDisconnectedParticipants`; see `RemoteCoOpReconnectTests`.
    @Test("coordinator disconnect holds the slot and emits neutral input")
    func coordinatorDisconnectHoldsTheSlotAndEmitsNeutralInput() async throws {
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
        // No `participantRemoved`: that tells the guest page it was ejected and stops it
        // reconnecting. The last command is still the join's own participant update.
        #expect(removedCommand != .participantRemoved(participantID))
        let held = try #require(snapshot.participants.first { $0.id == participantID })
        #expect(held.connectionState == .disconnected)
        #expect(held.playerIndex == 1)
        #expect(!held.inputEnabled)
    }

    @Test("host peer controller emits offer after approval")
    func hostPeerControllerEmitsOfferAfterApproval() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)), signaling: signaling)
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let participantID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let networkConfiguration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .directOnly,
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
        // The repeat is dropped by the scheduler's own sequence check before it reaches the router,
        // so no rejection is signalled back. That is deliberate: the input channel is unordered with
        // no retransmits, so a repeated or reordered sequence number is normal traffic rather than a
        // fault worth telling the guest about, and reporting each one would put a signaling round
        // trip on the busiest message the session carries.
        #expect(!signaling.commandHistory().contains(.inputRejected(participantID: participantID, result: .stalePacket)))
    }

    @Test("host peer input is routed on arrival, never held")
    func hostPeerInputIsRoutedOnArrival() async throws {
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
        // All three, in order. The scheduler used to hold analog-only packets on a 4 ms timer and
        // release the newest, which collapsed this burst to two events - and put that delay on stick
        // movement, the input least able to afford it. Coalescing a burst is still the right thing to
        // do, but it belongs in `NativeNVSTInputDispatcher`, which does it without making a packet
        // that arrives on an empty queue wait for a timer.
        let events = await inputRecorder.waitForEvents(count: 3)
        #expect(events.count == 3)
        let stickPositions = events.compactMap { event -> Float? in
            guard case .gamepad(let state) = event else { return nil }
            return state.leftStickX
        }
        #expect(stickPositions == [-1, 0, 1])
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

        // Audio delivery is queued off the CoreAudio render thread, so the first frame arrives
        // asynchronously. The second must never arrive: the sink was removed before it was rendered.
        let deadline = Date().addingTimeInterval(2)
        while peer.renderedAudioFrameCount() == 0, Date() < deadline { usleep(1_000) }

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

        // Fan-out is queued now, not inline: the relay must not run libwebrtc's encode on the
        // CoreAudio render thread. The copy this test is about still happens synchronously; only the
        // delivery is deferred.
        let deadline = Date().addingTimeInterval(2)
        while sink.renderedAudioFrames().isEmpty, Date() < deadline { usleep(1_000) }
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

/// Guest slots and local controller slots come from the same 4-pad space, and were assigned into it
/// independently. One local pad on index 0 with a guest on 1 never collided; a *second* local
/// controller also lands on 1 - the first free index `NativeWebRTCGamepadMonitor.update` hands out -
/// and approving a guest at that point silently doubled up a real player's controller and the
/// guest's, on both the NVST and WebRTC input paths, which each key a pad purely by index.
@Suite struct RemoteCoOpLocalControllerSlotTests {
    private func approvedHost(reservedGuestSlots: Int = 3) async throws -> OPNRemoteCoOpHostSession {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 6, count: 32))
        return OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: reservedGuestSlots),
            inviteSigner: signer
        )
    }

    private func addGuest(_ host: OPNRemoteCoOpHostSession, invite: OPNRemoteCoOpInvite) async throws -> OPNRemoteCoOpParticipant {
        let participantID = UUID()
        _ = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token, participantID: participantID)
        return try await host.approveParticipant(participantID)
    }

    /// A second local controller must not be handed to a guest.
    @Test func aGuestNeverTakesAnIndexALocalControllerHolds() async throws {
        let host = try await approvedHost()
        let invite = try await host.startInvite(lifetimeSeconds: 120)
        // Two controllers plugged into the host: indices 0 and 1.
        await host.updateReservedLocalPlayerIndices([0, 1])

        let guest = try await addGuest(host, invite: invite)
        #expect(guest.playerIndex == 2)
    }

    /// Reserving an index already given to a connected guest does not evict them - only the *next*
    /// assignment is affected, never one already handed out.
    @Test func reservingAnIndexAlreadyGivenToAGuestDoesNotEvictThem() async throws {
        let host = try await approvedHost()
        let invite = try await host.startInvite(lifetimeSeconds: 120)
        let first = try await addGuest(host, invite: invite)
        #expect(first.playerIndex == 1)

        // A local controller reconnects on the index the guest already holds - possible if the
        // guest was approved first and a controller was plugged in afterwards.
        await host.updateReservedLocalPlayerIndices([0, 1])

        let snapshot = await host.snapshot()
        #expect(snapshot.participants.first?.playerIndex == 1)

        // But the next guest must not collide with either the local pad or the first guest.
        let second = try await addGuest(host, invite: invite)
        #expect(second.playerIndex == 2)
    }

    /// Three local controllers leave nothing for a guest: reserved slots exist, but every index in
    /// range is spoken for.
    @Test func noSlotsRemainWhenLocalControllersFillTheRange() async throws {
        let host = try await approvedHost()
        let invite = try await host.startInvite(lifetimeSeconds: 120)
        await host.updateReservedLocalPlayerIndices([0, 1, 2, 3])

        let participantID = UUID()
        _ = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token, participantID: participantID)
        await #expect(throws: OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots) {
            _ = try await host.approveParticipant(participantID)
        }
    }

    /// Unplugging frees the index back up for the next guest.
    @Test func freeingALocalIndexMakesItAvailableAgain() async throws {
        let host = try await approvedHost()
        let invite = try await host.startInvite(lifetimeSeconds: 120)
        await host.updateReservedLocalPlayerIndices([0, 1])

        let first = try await addGuest(host, invite: invite)
        #expect(first.playerIndex == 2)

        // The second local controller unplugs.
        await host.updateReservedLocalPlayerIndices([0])
        let second = try await addGuest(host, invite: invite)
        #expect(second.playerIndex == 1)
    }

    /// A solo host - the common case - is unaffected: reserving only index 0 behaves exactly as
    /// reserving nothing did before this existed.
    @Test func aSoloHostAssignsFromOne() async throws {
        let host = try await approvedHost()
        let invite = try await host.startInvite(lifetimeSeconds: 120)
        await host.updateReservedLocalPlayerIndices([0])

        let guest = try await addGuest(host, invite: invite)
        #expect(guest.playerIndex == 1)
    }
}

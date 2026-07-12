import Testing
import Foundation
@testable import OpenNOW

@Suite("Remote Co-Op")
struct RemoteCoOpTests {
    @Test("preferences clamp guest slots")
    func preferencesClampGuestSlots() {
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: -2).reservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 7).reservedGuestSlots == 3)
        #expect(OPNRemoteCoOpPreferences(isEnabled: false, reservedGuestSlots: 2).effectiveReservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2).effectiveReservedGuestSlots == 2)
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
            guestJoinBaseURL: "https://coop.example.test/"
        )

        #expect(OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences()) == preferences)
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
}

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
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2, transportMode: .relayOnly, qualityPreset: .p1080f60, requireHostApproval: false)

        #expect(OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences()) == preferences)
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
        let pending = try await host.registerGuest(displayName: "Mia")
        let approved = try await host.approveParticipant(pending.id)
        let snapshot = await host.snapshot()

        #expect(invite.code.count == 8)
        #expect(pending.connectionState == .waitingForApproval)
        #expect(approved.connectionState == .connected)
        #expect(approved.inputEnabled)
        #expect(approved.playerIndex == 1)
        #expect(snapshot.participants == [approved])
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

        _ = try await host.startInvite(lifetimeSeconds: 120)
        let guest = try await host.registerGuest(displayName: "Guest")
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
}

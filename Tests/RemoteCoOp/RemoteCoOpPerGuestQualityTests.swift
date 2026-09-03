//  Per-guest stream quality: each guest streams at their own preset, and changing one retargets that
//  peer in place rather than rebuilding it.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("Remote Co-Op per-guest quality", .serialized)
struct RemoteCoOpPerGuestQualityTests {
    private func makeSession() -> (OPNRemoteCoOpHostSession, OPNInProcessRemoteCoOpSignalingSession, OPNRemoteCoOpHostCoordinator) {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 3, requireHostApproval: true))
        return (hostSession, signaling, OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling))
    }

    private func join(_ coordinator: OPNRemoteCoOpHostCoordinator, invite: OPNRemoteCoOpInvite, name: String) async throws -> OPNRemoteCoOpParticipant {
        let participantID = UUID()
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: name))
        return try await coordinator.approveParticipant(participantID)
    }

    // MARK: - Model

    @Test("a guest with no preset of their own follows the session, and keeps following it")
    func effectivePresetFollowsSessionDefault() {
        let participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        #expect(participant.qualityPreset == nil)
        // The distinction that matters: "follow the session" is not the same as "happens to equal the
        // session right now". A guest left on the default tracks a later change to it.
        #expect(participant.effectiveQualityPreset(sessionDefault: .p720f60) == .p720f60)
        #expect(participant.effectiveQualityPreset(sessionDefault: .p1440f120) == .p1440f120)
    }

    @Test("a guest with their own preset ignores the session default")
    func effectivePresetOverridesSessionDefault() {
        var participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        participant.qualityPreset = .p720f30
        #expect(participant.effectiveQualityPreset(sessionDefault: .p1440f120) == .p720f30)
    }

    @Test("a participant encoded before per-guest quality existed decodes as following the session")
    func participantDecodesWithoutQualityPresetField() throws {
        // The browser guest and any stored session predate this field, so its absence has to mean
        // "session default" rather than failing the decode.
        let json = """
        {"id":"\(UUID().uuidString)","displayName":"Mia","role":"guest","connectionState":"connected",\
        "inputEnabled":true,"playerIndex":1,"joinedAt":0,"lastActivityAt":0}
        """
        let participant = try JSONDecoder().decode(OPNRemoteCoOpParticipant.self, from: Data(json.utf8))
        #expect(participant.qualityPreset == nil)
        #expect(participant.effectiveQualityPreset(sessionDefault: .p1080f60) == .p1080f60)
    }

    // MARK: - Session

    @Test("setting a guest's preset leaves the other guests alone")
    func settingOneGuestPresetIsIsolated() async throws {
        let (hostSession, _, coordinator) = makeSession()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let first = try await join(coordinator, invite: invite, name: "Mia")
        let second = try await join(coordinator, invite: invite, name: "Sam")

        let updated = try await coordinator.setQualityPreset(.p1440f120, for: first.id)
        #expect(updated.qualityPreset == .p1440f120)

        let participants = await hostSession.snapshot().participants
        #expect(participants.first { $0.id == first.id }?.qualityPreset == .p1440f120)
        #expect(participants.first { $0.id == second.id }?.qualityPreset == nil)
    }

    @Test("clearing a guest's preset puts them back on the session default")
    func clearingGuestPresetRestoresDefault() async throws {
        let (hostSession, _, coordinator) = makeSession()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let participant = try await join(coordinator, invite: invite, name: "Mia")

        _ = try await coordinator.setQualityPreset(.p720f30, for: participant.id)
        let cleared = try await coordinator.setQualityPreset(nil, for: participant.id)
        #expect(cleared.qualityPreset == nil)
        #expect(await hostSession.snapshot().participants.first?.qualityPreset == nil)
    }

    @Test("setting a preset for a guest who is not in the session fails")
    func settingPresetForUnknownGuestThrows() async throws {
        let (_, _, coordinator) = makeSession()
        _ = try await coordinator.startInvite(lifetimeSeconds: 120)
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.setQualityPreset(.p1080f60, for: UUID())
        }
    }

    // MARK: - Peers

    @Test("each guest's peer is built at that guest's own preset")
    func peersAreBuiltAtTheirOwnPreset() async throws {
        let (_, signaling, coordinator) = makeSession()
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly),
            qualityPreset: .p1080f60,
            peerFactory: factory,
            forwardInput: { _ in }
        )
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let onDefault = try await join(coordinator, invite: invite, name: "Mia")
        let downgraded = try await join(coordinator, invite: invite, name: "Sam")
        let updated = try await coordinator.setQualityPreset(.p720f30, for: downgraded.id)

        try await controller.sync(participants: [onDefault, updated])

        #expect(factory.peer(for: onDefault.id)?.qualityPreset == .p1080f60)
        #expect(factory.peer(for: downgraded.id)?.qualityPreset == .p720f30)
    }

    @Test("changing a guest's preset retargets their peer instead of rebuilding it")
    func changingPresetRetargetsWithoutRebuilding() async throws {
        let (_, signaling, coordinator) = makeSession()
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly),
            qualityPreset: .p1080f60,
            peerFactory: factory,
            forwardInput: { _ in }
        )
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let participant = try await join(coordinator, invite: invite, name: "Mia")
        try await controller.sync(participants: [participant])
        let peer = try #require(factory.peer(for: participant.id))
        #expect(peer.startCount() == 1)

        let upgraded = try await coordinator.setQualityPreset(.p1440f60, for: participant.id)
        try await controller.sync(participants: [upgraded])

        // Retargeted in place: resolution and bitrate are sender-side, so rebuilding would black the
        // guest out for a renegotiation they do not need.
        #expect(peer.retargetHistory() == [.p1440f60])
        #expect(peer.startCount() == 1)
        #expect(peer.closeCount() == 0)
    }

    @Test("a sync that changes nothing does not retarget")
    func repeatedSyncDoesNotRetarget() async throws {
        let (_, signaling, coordinator) = makeSession()
        let factory = RecordingRemoteCoOpHostPeerFactory()
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly),
            qualityPreset: .p1080f60,
            peerFactory: factory,
            forwardInput: { _ in }
        )
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let participant = try await join(coordinator, invite: invite, name: "Mia")
        // `sync` runs on every signaling message, including each guest input packet on the WebSocket
        // fallback, so a no-op sync reconfiguring the encoder would be a per-packet cost.
        for _ in 0..<5 { try await controller.sync(participants: [participant]) }
        #expect(factory.peer(for: participant.id)?.retargetHistory().isEmpty == true)
    }

    // MARK: - Guest requests

    @Test("a guest may lower themselves below the host's allowance")
    func guestMayLower() {
        var participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        participant.qualityPreset = .p1440f60
        participant.guestRequestedQualityPreset = .p720f30
        #expect(participant.effectiveQualityPreset(sessionDefault: .p1080f60) == .p720f30)
        // The host's allowance is untouched, so they can still be put back up.
        #expect(participant.allowedQualityPreset(sessionDefault: .p1080f60) == .p1440f60)
    }

    @Test("a guest may not raise themselves past the host's allowance")
    func guestMayNotRaise() {
        var participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        participant.qualityPreset = .p720f60
        // The guest's stream is spent from the host's uplink and one of the host's encoders, so an
        // over-ask is ignored rather than honoured.
        participant.guestRequestedQualityPreset = .p2160f60
        #expect(participant.effectiveQualityPreset(sessionDefault: .p1080f60) == .p720f60)
    }

    @Test("a guest cannot raise demand sideways by trading pixels for frames")
    func guestMayNotRaiseDemandSideways() {
        var participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        participant.qualityPreset = .p1440f60
        // 1080p120 is fewer pixels but more of them per second, so comparing on resolution alone would
        // let it through. Demand is pixels times frame rate, which is what the host actually pays.
        #expect(OPNRemoteCoOpQualityPreset.p1080f120.demand > OPNRemoteCoOpQualityPreset.p1440f60.demand)
        participant.guestRequestedQualityPreset = .p1080f120
        #expect(participant.effectiveQualityPreset(sessionDefault: .p720f60) == .p1440f60)
    }

    @Test("clearing the guest request returns them to the host's allowance")
    func clearingGuestRequestRestoresAllowance() async throws {
        let (hostSession, _, coordinator) = makeSession()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let participant = try await join(coordinator, invite: invite, name: "Mia")
        _ = try await coordinator.setQualityPreset(.p1440f60, for: participant.id)
        _ = try await coordinator.setGuestRequestedQualityPreset(.p720f30, for: participant.id)
        let lowered = try #require(await hostSession.snapshot().participants.first)
        #expect(lowered.effectiveQualityPreset(sessionDefault: .p1080f60) == .p720f30)

        _ = try await coordinator.setGuestRequestedQualityPreset(nil, for: participant.id)
        let restored = try #require(await hostSession.snapshot().participants.first)
        #expect(restored.effectiveQualityPreset(sessionDefault: .p1080f60) == .p1440f60)
    }

    @Test("a guest quality request arriving as a signaling event is applied")
    func guestQualityRequestEventIsApplied() async throws {
        let (hostSession, _, coordinator) = makeSession()
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let participant = try await join(coordinator, invite: invite, name: "Mia")
        _ = try await coordinator.setQualityPreset(.p1440f120, for: participant.id)

        _ = await coordinator.handle(.guestQualityRequested(participantID: participant.id, preset: .p720f60))

        let updated = try #require(await hostSession.snapshot().participants.first)
        #expect(updated.guestRequestedQualityPreset == .p720f60)
        #expect(updated.qualityPreset == .p1440f120)
        #expect(updated.effectiveQualityPreset(sessionDefault: .p1080f60) == .p720f60)
    }

    @Test("a request naming a guest who left is ignored rather than crashing")
    func guestQualityRequestForUnknownParticipantIsIgnored() async throws {
        let (hostSession, _, coordinator) = makeSession()
        _ = try await coordinator.startInvite(lifetimeSeconds: 120)
        _ = await coordinator.handle(.guestQualityRequested(participantID: UUID(), preset: .p720f30))
        #expect(await hostSession.snapshot().participants.isEmpty)
    }

    @Test("the guest request survives a wire round trip")
    func guestQualityRequestRoundTripsOnTheWire() throws {
        let participantID = UUID()
        let message = OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: participantID, qualityPreset: .p1080f60)
        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))
        #expect(decoded.kind == .guestQualityRequested)
        #expect(decoded.qualityPreset == .p1080f60)
        #expect(decoded.signalingEvent() == .guestQualityRequested(participantID: participantID, preset: .p1080f60))
        // A request with no preset clears the guest's own choice, so nil has to survive too.
        let clearing = OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: participantID)
        let decodedClearing = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(clearing))
        #expect(decodedClearing.signalingEvent() == .guestQualityRequested(participantID: participantID, preset: nil))
    }

    // MARK: - Arrival detection

    /// The host is told about a guest once, when they arrive. Recomputed from a set difference rather
    /// than a flag, because the signaling loop runs this on every message.
    private func arrivals(previouslyWaiting: Set<UUID>, participants: [OPNRemoteCoOpParticipant]) -> [OPNRemoteCoOpParticipant] {
        participants.filter { $0.connectionState == .waitingForApproval && !previouslyWaiting.contains($0.id) }
    }

    @Test("a newly waiting guest is announced exactly once")
    func arrivalAnnouncedOnce() {
        let waiting = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .waitingForApproval)
        #expect(arrivals(previouslyWaiting: [], participants: [waiting]).map(\.displayName) == ["Mia"])
        // The loop runs on every signaling message, including each input packet on the WebSocket
        // fallback, so a guest already known must not be announced again.
        #expect(arrivals(previouslyWaiting: [waiting.id], participants: [waiting]).isEmpty)
    }

    @Test("guests who are not waiting are never announced")
    func onlyWaitingGuestsAreAnnounced() {
        let connected = OPNRemoteCoOpParticipant(displayName: "Sam", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let disconnected = OPNRemoteCoOpParticipant(displayName: "Ana", role: .guest, connectionState: .disconnected)
        #expect(arrivals(previouslyWaiting: [], participants: [connected, disconnected]).isEmpty)
    }

    @Test("a guest who leaves and comes back is announced again")
    func returningGuestIsAnnouncedAgain() {
        let guest = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .waitingForApproval)
        // Their ID drops out of the waiting set while they are away, so the next arrival is new again.
        #expect(arrivals(previouslyWaiting: [], participants: [guest]).count == 1)
        #expect(arrivals(previouslyWaiting: [UUID()], participants: [guest]).count == 1)
    }

    // MARK: - Relay ceiling

    @Test("the relay pre-scale follows the most demanding guest, not the least")
    func relayCeilingIsTheLargestActiveGuest() async throws {
        let (_, signaling, coordinator) = makeSession()
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly),
            qualityPreset: .p720f60,
            peerFactory: RecordingRemoteCoOpHostPeerFactory(),
            forwardInput: { _ in }
        )
        var small = OPNRemoteCoOpParticipant(displayName: "Sam", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        small.qualityPreset = .p720f30
        var large = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 2)
        large.qualityPreset = .p1440f60

        // One decoded buffer serves every guest's encoder. Pre-scaling to the smallest would cap the
        // largest with no way to recover; the largest costs the smallest nothing, because their own
        // encoder downscales again anyway.
        let ceiling = await controller.largestActiveQualityPreset(participants: [small, large])
        #expect(ceiling == .p1440f60)
    }

    @Test("guests who are not streaming do not raise the relay ceiling")
    func relayCeilingIgnoresInactiveGuests() async throws {
        let (_, signaling, coordinator) = makeSession()
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly),
            qualityPreset: .p720f60,
            peerFactory: RecordingRemoteCoOpHostPeerFactory(),
            forwardInput: { _ in }
        )
        var waiting = OPNRemoteCoOpParticipant(displayName: "Sam", role: .guest, connectionState: .waitingForApproval, inputEnabled: false)
        waiting.qualityPreset = .p2160f60
        var connected = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        connected.qualityPreset = .p1080f60

        // A guest still waiting for approval has no encoder, so scaling every frame up for them would
        // be paid on every frame for nobody.
        #expect(await controller.largestActiveQualityPreset(participants: [waiting, connected]) == .p1080f60)
        // With nobody streaming at all it falls back to the session default rather than to nothing.
        #expect(await controller.largestActiveQualityPreset(participants: [waiting]) == .p720f60)
    }
}

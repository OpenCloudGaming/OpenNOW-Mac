//
//  RemoteCoOpReviewFixTests.swift
//  OpenNOW
//
//  Regression cover for the review findings. Each of these was reachable and none had a test.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("Remote Co-Op review fixes", .serialized)
struct RemoteCoOpReviewFixTests {
    // MARK: - Reconnect keeps the host's input decision

    @Test("a guest benched by the host stays benched across a reconnect")
    func benchedGuestStaysBenchedAfterReconnect() async throws {
        let session = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true))
        let invite = try await session.startInvite(lifetimeSeconds: 120)
        let participantID = UUID()
        _ = try await session.registerGuest(displayName: "Mia", inviteToken: invite.token, participantID: participantID)
        _ = try await session.approveParticipant(participantID)
        _ = try await session.setInputEnabled(false, for: participantID)

        _ = await session.noteGuestDisconnected(participantID)
        let restored = try await session.registerGuest(displayName: "Mia", inviteToken: invite.token, participantID: participantID)

        // The slot and the approval survive a Wi-Fi roam; the host's decision to bench them does too.
        #expect(restored.connectionState == .connected)
        #expect(restored.playerIndex != nil)
        #expect(!restored.inputEnabled)
    }

    @Test("a playing guest keeps input across a reconnect")
    func playingGuestKeepsInputAfterReconnect() async throws {
        let session = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true))
        let invite = try await session.startInvite(lifetimeSeconds: 120)
        let participantID = UUID()
        _ = try await session.registerGuest(displayName: "Mia", inviteToken: invite.token, participantID: participantID)
        _ = try await session.approveParticipant(participantID)

        _ = await session.noteGuestDisconnected(participantID)
        let restored = try await session.registerGuest(displayName: "Mia", inviteToken: invite.token, participantID: participantID)

        #expect(restored.inputEnabled)
    }

    // MARK: - Retarget bookkeeping

    /// A peer that cannot apply a retarget yet - its video track is not attached - must not have the
    /// preset recorded as applied, or nothing ever retries and the guest is stuck for the session.
    private final class NotReadyPeer: OPNRemoteCoOpHostPeer, @unchecked Sendable {
        let participantID: UUID
        private let lock = NSLock()
        private var attempts: [OPNRemoteCoOpQualityPreset] = []
        var isReady = false

        init(participantID: UUID) { self.participantID = participantID }

        func start() async throws {}
        func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {}
        func close() async {}

        @discardableResult
        func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) async -> Bool {
            lock.withLock { attempts.append(preset) }
            return isReady
        }

        func attemptCount() -> Int { lock.withLock { attempts.count } }
    }

    private final class NotReadyPeerFactory: OPNRemoteCoOpHostPeerFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [UUID: NotReadyPeer] = [:]

        func makePeer(participantID: UUID,
                      networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                      qualityPreset: OPNRemoteCoOpQualityPreset,
                      latencyMode: OPNRemoteCoOpLatencyMode,
                      callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer {
            let peer = NotReadyPeer(participantID: participantID)
            lock.withLock { peers[participantID] = peer }
            return peer
        }

        func peer(for id: UUID) -> NotReadyPeer? { lock.withLock { peers[id] } }
    }

    @Test("a retarget the peer could not apply is retried, not recorded as done")
    func unappliedRetargetIsRetried() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true))
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        let factory = NotReadyPeerFactory()
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly),
            qualityPreset: .p720f60,
            peerFactory: factory,
            forwardInput: { _ in }
        )
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        let participantID = UUID()
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Mia"))
        let approved = try await coordinator.approveParticipant(participantID)
        try await controller.sync(participants: [approved])
        let peer = try #require(factory.peer(for: participantID))

        let upgraded = try await coordinator.setQualityPreset(.p1440f60, for: participantID)
        try await controller.sync(participants: [upgraded])
        #expect(peer.attemptCount() == 1)

        // Still not recorded, so the next sync tries again rather than leaving the guest behind.
        try await controller.sync(participants: [upgraded])
        #expect(peer.attemptCount() == 2)

        peer.isReady = true
        try await controller.sync(participants: [upgraded])
        #expect(peer.attemptCount() == 3)
        // Applied now, so it stops asking.
        try await controller.sync(participants: [upgraded])
        #expect(peer.attemptCount() == 3)
    }

    // MARK: - Framing

    @Test("a message this build cannot decode is skipped, not fatal")
    func undecodableFrameIsSkipped() throws {
        var codec = OPNRemoteCoOpNativeFrameCodec()
        let good = try OPNRemoteCoOpNativeFrameCodec.encode(OPNRemoteCoOpWireMessage(kind: .heartbeat))
        var stream = Data(#"{"kind":"somethingFromANewerBuild"}"#.utf8)
        stream.append(OPNRemoteCoOpNativeFrameCodec.frameDelimiter)
        stream.append(good)

        // A host on a newer release must not disconnect every native guest just by speaking.
        let messages = try codec.append(stream)
        #expect(messages.map(\.kind) == [.heartbeat])
        #expect(codec.skippedFrameCount == 1)
    }

    @Test("an oversized buffer is still fatal")
    func oversizedBufferStillThrows() {
        var codec = OPNRemoteCoOpNativeFrameCodec()
        // No delimiter, so nothing can be consumed and the buffer only grows.
        let flood = Data(repeating: 0x41, count: OPNRemoteCoOpNativeFrameCodec.maximumFrameBytes + 1)
        #expect(throws: OPNRemoteCoOpNativeFrameError.frameTooLarge) {
            _ = try codec.append(flood)
        }
    }

    // MARK: - Guest quality ceiling

    @Test("a guest following the session default is offered only what the default allows")
    func guestCeilingUsesSessionDefault() {
        var participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        // The ordinary case: no per-guest override, so the ceiling is the session's own preset.
        #expect(participant.qualityPreset == nil)
        #expect(participant.allowedQualityPreset(sessionDefault: .p720f60) == .p720f60)

        participant.qualityPreset = .p1440f60
        #expect(participant.allowedQualityPreset(sessionDefault: .p720f60) == .p1440f60)
    }

    @Test("the session default reaches the guest on the wire")
    func sessionPresetTravelsWithParticipantUpdates() throws {
        let participant = OPNRemoteCoOpParticipant(displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)
        let message = try #require(OPNRemoteCoOpWireMessage.message(for: .participantUpdated(participant), sessionQualityPreset: .p1080f60))
        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))
        #expect(decoded.sessionQualityPreset == .p1080f60)
        // Absent on a build that does not send it, which must decode rather than fail.
        let older = try OPNRemoteCoOpWireCodec.decode(#"{"kind":"participantUpdated","protocolVersion":1,"sentAtEpochMilliseconds":0}"#)
        #expect(older.sessionQualityPreset == nil)
    }

    /// A failed approval must leave the participant exactly as it was.
    ///
    /// `approveParticipant` set `connectionState = .connected` before resolving the player index,
    /// which throws when no pad slot is free. The media session decides eligibility on
    /// `connectionState` alone, so the half-approved guest was sent the game behind their own
    /// "waiting for approval" overlay - and invisibly, because the pad topology and the connected-slot
    /// count both filter on `inputEnabled`, which was still false.
    @Test func aFailedApprovalLeavesTheGuestUnapproved() async throws {
        let session = OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true)
        )
        let invite = try await session.startInvite(lifetimeSeconds: 600)

        // Registered while a slot was free, then a local controller takes it. `nextAvailablePlayerIndex`
        // unions the reserved local indices, so approval now has nothing left to hand out - which is
        // the reachable way this throws, and the pad arriving mid-session is a real sequence.
        let guest = try await session.registerGuest(displayName: "Guest", inviteToken: invite.token)
        await session.updateReservedLocalPlayerIndices([1])

        await #expect(throws: (any Error).self) {
            _ = try await session.approveParticipant(guest.id)
        }

        let snapshot = await session.snapshot()
        let stranded = try #require(snapshot.participants.first { $0.id == guest.id })
        #expect(stranded.connectionState != OPNRemoteCoOpParticipantConnectionState.connected,
                "a guest whose approval threw is eligible for the media session")
        #expect(stranded.playerIndex == nil)
        #expect(!stranded.inputEnabled)
    }

    /// The guest gates on its own phase, so a host that gets eligibility wrong cannot put the game
    /// behind the approval overlay.
    @Test func onlyAConnectedGuestMayRenderVideo() throws {
        #expect(RemoteCoOpGuestViewModel.Phase.connected.allowsVideoPlayback)
        #expect(!RemoteCoOpGuestViewModel.Phase.waitingForApproval.allowsVideoPlayback)
        #expect(!RemoteCoOpGuestViewModel.Phase.connecting.allowsVideoPlayback)
        #expect(!RemoteCoOpGuestViewModel.Phase.browsing.allowsVideoPlayback)
        #expect(!RemoteCoOpGuestViewModel.Phase.failed("nope").allowsVideoPlayback)
    }
}

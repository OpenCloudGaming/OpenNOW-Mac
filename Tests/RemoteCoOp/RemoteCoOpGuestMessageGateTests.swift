//  The authorisation rule both listeners now share.
//
//  Written against the decision rather than either transport, because the point of extracting it was
//  that the two copies could differ without anything noticing.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpGuestMessageGateTests {
    private let owner = UUID()
    private let stranger = UUID()

    private func decide(_ message: OPNRemoteCoOpWireMessage,
                        owner: UUID?,
                        held: Set<UUID> = []) -> OPNRemoteCoOpGuestMessageGate.Decision {
        OPNRemoteCoOpGuestMessageGate.decide(message: message, owner: owner) { held.contains($0) }
    }

    private func input(_ participantID: UUID, sequence: UInt64 = 1) -> OPNRemoteCoOpInputPacket {
        OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: sequence)
    }

    // MARK: - Kind allowlist

    /// Host-originated kinds have no producer on a guest socket. `networkConfiguration` is the one
    /// that mattered: accepting it let an unauthenticated peer replace the ICE servers of every peer
    /// connection built afterwards, forcing media through a relay of their choosing.
    @Test func hostOriginatedKindsAreRefused() throws {
        let hostKinds: [OPNRemoteCoOpWireMessageKind] = [
            .hostHello, .inviteEnded, .participantUpdated, .participantRemoved,
            .guestRejected, .inputRejected, .heartbeat, .networkConfiguration, .error
        ]
        for kind in hostKinds {
            let decision = decide(OPNRemoteCoOpWireMessage(kind: kind, participantID: owner), owner: owner)
            #expect(decision == .ignore, "\(kind) reached the host")
        }
    }

    @Test func guestOriginatedKindsAreDelivered() throws {
        let guestKinds: [OPNRemoteCoOpWireMessageKind] = [.guestInput, .guestQualityRequested, .guestDisconnected, .peerSignal]
        for kind in guestKinds {
            #expect(decide(OPNRemoteCoOpWireMessage(kind: kind, participantID: owner), owner: owner) == .deliver,
                    "\(kind) was refused")
        }
    }

    // MARK: - Claiming a participant

    @Test func aJoinWithATokenClaimsTheParticipant() throws {
        let join = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: owner, inviteToken: "t.s")
        #expect(decide(join, owner: nil) == .claimThenDeliver(participantID: owner))
    }

    /// A join carrying no credential must not take a participant. Otherwise a peer that knows only a
    /// UUID seizes that guest's routing and locks the real owner out, having presented nothing.
    @Test func aJoinWithoutATokenClaimsNothing() throws {
        let noToken = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: owner)
        #expect(decide(noToken, owner: nil) == .ignore)
        let emptyToken = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: owner, inviteToken: "")
        #expect(decide(emptyToken, owner: nil) == .ignore)
    }

    /// Refused rather than ignored: a claim on a participant someone else holds cannot be a race, so
    /// the socket is closed rather than left to try again.
    @Test func aParticipantHeldByAnotherLiveConnectionIsNotUpForGrabs() throws {
        let join = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: stranger, inviteToken: "t.s")
        guard case .dropConnection = decide(join, owner: nil, held: [stranger]) else {
            Issue.record("a held participant was handed to a second socket")
            return
        }
    }

    /// The same socket re-sending its own join is not an attack; a guest that reconnects and repeats
    /// the handshake must not be dropped.
    @Test func aSocketMayReclaimTheParticipantItAlreadyHolds() throws {
        let join = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: owner, inviteToken: "t.s")
        #expect(decide(join, owner: owner, held: [owner]) == .claimThenDeliver(participantID: owner))
    }

    /// Re-claiming its own participant is fine; moving to a *different* one is not.
    ///
    /// The claim only proves the token is non-empty - the signature is checked later by
    /// `registerGuest`, which restores a recently disconnected participant with their approval and
    /// player slot intact. So without this a second invite holder could claim an approved guest's
    /// identity and inherit input rights the host never granted, and the transports would route that
    /// participant's signaling, including their SDP, to the wrong connection.
    @Test func aConnectionMayNotClaimASecondParticipant() throws {
        let join = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: stranger, inviteToken: "t.s")
        #expect(decide(join, owner: owner) == .dropConnection(reason: "claimed a second participant on one connection"))
        // Refused even when nobody else holds it - being free is not the point; already owning one is.
        #expect(decide(join, owner: owner, held: []) == .dropConnection(reason: "claimed a second participant on one connection"))
    }

    // MARK: - Ownership

    @Test func anUnjoinedSocketMayNotActAsAnyone() throws {
        let input = OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: stranger, input: input(stranger))
        #expect(decide(input, owner: nil) == .ignore)
        // Even with no ID at all: owning nothing means acting as no one.
        #expect(decide(OPNRemoteCoOpWireMessage(kind: .peerSignal), owner: nil) == .ignore)
    }

    @Test func aJoinedSocketMayNotNameAnotherParticipant() throws {
        let message = OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: stranger)
        #expect(decide(message, owner: owner) == .ignore)
    }

    @Test func aJoinedSocketMayNotSendAnotherParticipantsInput() throws {
        let message = OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: owner, input: input(stranger))
        #expect(decide(message, owner: owner) == .ignore)
    }

    /// The check most easily forgotten, and the one that decides what is routed.
    ///
    /// `signalingEvent()` resolves `input ?? inputs?.last`, and the browser page populates `inputs`,
    /// so a message that omits the singular field is routed from the array. Checking only `input`
    /// would authorise a packet nobody looked at.
    @Test func aJoinedSocketMayNotSmuggleAnotherParticipantThroughTheInputsArray() throws {
        let smuggled = OPNRemoteCoOpWireMessage(
            kind: .guestInput,
            participantID: owner,
            inputs: [input(owner), input(stranger, sequence: 2)]
        )
        #expect(decide(smuggled, owner: owner) == .ignore,
                "another participant's packet was authorised through the inputs array")

        // Positive control: the identical shape carrying only the owner's packets is delivered, so the
        // rejection above is the ownership rule and not the array itself being refused.
        let legitimate = OPNRemoteCoOpWireMessage(
            kind: .guestInput,
            participantID: owner,
            inputs: [input(owner), input(owner, sequence: 2)]
        )
        #expect(decide(legitimate, owner: owner) == .deliver)
    }

    /// Every field that can carry a participant ID is checked, so adding one to the wire without
    /// adding it here is a visible omission rather than a silent hole.
    @Test func everyIdentityBearingFieldIsChecked() throws {
        let cases: [(String, OPNRemoteCoOpWireMessage)] = [
            ("participantID", OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: stranger)),
            ("input", OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: owner, input: input(stranger))),
            ("inputs", OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: owner, inputs: [input(stranger)])),
        ]
        for (field, message) in cases {
            #expect(decide(message, owner: owner) == .ignore, "\(field) was not checked for ownership")
        }
    }
}

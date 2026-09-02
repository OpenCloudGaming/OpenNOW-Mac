//
//  RemoteCoOpGuestMessageGate.swift
//  OpenNOW
//
//  The one place a guest-originated message is authorised.
//
//  This policy lived twice, once per listener, and has already drifted once: the native listener
//  shipped without the kind allowlist and without the participant-claim guard, and both had to be
//  hand-copied across in a later commit. The two are equivalent today - that equivalence is the thing
//  no one can check at a glance, and nothing enforces it.
//
//  A pure decision keeps the transports honest. They differ in how they track connections - one holds
//  an actor's state, the other an NSLock - but the rule about who may say what does not differ, and a
//  third transport must not be able to introduce a third variant of it.
//

import Foundation

public enum OPNRemoteCoOpGuestMessageGate {
    public enum Decision: Equatable {
        /// Ignore the message. Not an attack in itself - an un-joined socket sending input looks the
        /// same as a race during teardown - so it is silent.
        case ignore
        /// Refuse the socket and close it. Reserved for a claim on a participant someone else holds,
        /// which cannot be a race: the claimant knew a UUID they were not given.
        case dropConnection(reason: String)
        /// Bind this socket to the participant, then deliver. The binding must happen before anything
        /// is routed, so a later message naming a different participant cannot read someone else's
        /// signaling.
        case claimThenDeliver(participantID: UUID)
        case deliver
    }

    /// `isHeldByAnotherConnection` is the transport's own bookkeeping: whether a *live* connection
    /// other than this one already owns that participant. A dead one does not count, or a guest could
    /// never reconnect.
    public static func decide(message: OPNRemoteCoOpWireMessage,
                              owner: UUID?,
                              isHeldByAnotherConnection: (UUID) -> Bool) -> Decision {
        // Allowlist first, before any binding.
        //
        // `networkConfiguration` and `error` used to arrive on the host's outbound socket from the
        // trusted broker. With the broker gone the only socket left is guest-facing, and
        // `signalingEvent()` still decodes both - so an unauthenticated peer could send a
        // `networkConfiguration` and replace the ICE servers and transport policy of every peer
        // connection built afterwards, forcing guest media through a relay of their choosing.
        switch message.kind {
        case .guestJoinRequested, .guestInput, .guestQualityRequested, .guestDisconnected, .peerSignal:
            break
        case .hostHello, .inviteEnded, .participantUpdated, .participantRemoved,
             .guestRejected, .inputRejected, .heartbeat, .networkConfiguration, .error:
            return .ignore
        }

        // A join without a token cannot become a participant, so it must not claim one either: a peer
        // that sends nothing but a participant ID would otherwise take over that guest's routing and
        // lock the real owner out, having presented no credential at all. The token's *signature* is
        // checked later, by the host session - this only refuses the empty case.
        if message.kind == .guestJoinRequested,
           let participantID = message.participantID,
           let token = message.inviteToken,
           !token.isEmpty {
            // A connection bound to one participant may not become another.
            //
            // Re-claiming the *same* participant is legitimate (a retried join), but moving to a
            // different one is not: the claim only proves the token is non-empty - its signature is
            // checked later, by `registerGuest` - and `registerGuest` restores a recently disconnected
            // participant with their approval and player slot intact. So a second invite holder could
            // claim an approved guest's identity and inherit input rights the host never granted them,
            // which is the exact bypass host approval exists to prevent. It also left the transports
            // routing that participant's signaling, including their SDP, to the wrong connection.
            if let owner, participantID != owner {
                return .dropConnection(reason: "claimed a second participant on one connection")
            }
            if participantID != owner, isHeldByAnotherConnection(participantID) {
                return .dropConnection(reason: "claimed a participant that is already connected")
            }
            return .claimThenDeliver(participantID: participantID)
        }

        // Everything after the join must come from the socket that owns the participant. An un-joined
        // socket owns nothing and so may not act as anyone; it used to pass this by omitting the
        // field, leaving a victim's UUID as the only secret.
        guard let owner else { return .ignore }
        guard ownsEveryClaim(in: message, owner: owner) else { return .ignore }
        return .deliver
    }

    /// Every place a participant ID can appear on a guest message, because every one of them is read
    /// somewhere downstream.
    ///
    /// `inputs` is easy to forget and the most consequential: `signalingEvent()` resolves
    /// `input ?? inputs?.last`, and the browser is the client that populates it, so a message omitting
    /// the singular field is routed from the array. Checking only `input` would authorise the wrong
    /// packet.
    private static func ownsEveryClaim(in message: OPNRemoteCoOpWireMessage, owner: UUID) -> Bool {
        if let claimed = message.participantID, claimed != owner { return false }
        if let claimed = message.input?.participantID, claimed != owner { return false }
        if message.inputs?.contains(where: { $0.participantID != owner }) == true { return false }
        return true
    }
}

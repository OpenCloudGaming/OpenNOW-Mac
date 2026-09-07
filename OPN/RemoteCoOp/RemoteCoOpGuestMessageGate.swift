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
//  The gate is synchronous because the socket listeners run inside their own locks. Shared state is
//  held by the lock-protected `OPNRemoteCoOpParticipantOwnership` registry, not by an actor.
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

    /// `connection` identifies the inbound transport connection; `registry` is the shared
    /// participant ownership table. A connection is bound to at most one participant, and a
    /// participant can be owned by at most one connection at a time. Reconnecting on a different
    /// transport is only allowed after the previous connection has been released.
    public static func decide(message: OPNRemoteCoOpWireMessage,
                              connection: OPNRemoteCoOpConnectionHandle,
                              registry: OPNRemoteCoOpParticipantOwnership) -> Decision {
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
            if let owned = registry.participantOwnedBy(connection), owned != participantID {
                return .dropConnection(reason: "claimed a second participant on one connection")
            }
            // Re-claiming the *same* participant is legitimate (a retried join).
            if registry.participantOwnedBy(connection) == participantID {
                return .deliver
            }
            // A live participant owned by a different connection cannot be claimed here; the
            // caller must drop the claimant. This closes the cross-transport impersonation window
            // where a second connection reuses a participant ID that is still bound elsewhere.
            if registry.owner(of: participantID) != nil {
                return .dropConnection(reason: "claimed a participant that is already connected")
            }
            return .claimThenDeliver(participantID: participantID)
        }

        // Everything after the join must come from the connection that owns the participant. An
        // un-joined socket owns nothing and so may not act as anyone; it used to pass this by
        // omitting the field, leaving a victim's UUID as the only secret.
        guard let owner = registry.participantOwnedBy(connection) else { return .ignore }
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
